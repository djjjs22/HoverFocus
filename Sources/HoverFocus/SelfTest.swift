//  HoverFocus — 自检模式
//
//  ⚠️ 这个模式是**本机唯一不依赖用户肉眼的验证手段**，的端到端验证依赖它。
//  原因：本机 screencapture 被系统拒绝（无屏幕录制权限），而且 macOS 26+ 的菜单栏图标
//  由 MenuBarAgent 合成、不是独立窗口，CGWindowListCopyWindowInfo 里根本查不到。
//  所以「图标到底出没出来」只能靠进程内自查 NSStatusItem.button?.window 的 frame / isVisible。
//
//  契约第 6 条：
//    不进入常驻菜单栏模式 → 创建 status item → 等 1s → 打印**单行 JSON** → exit 0
//    字段至少包含：statusItemCreated / buttonWindowVisible / buttonWindowFrame /
//                  axTrusted / version / driverStarted / error
//
//  安全设计（重要）：HoverFocus 会抢键盘焦点，自检绝不能在用户干活时抢走焦点。
//  所以 driver 只在「有辅助功能权限」时启动，启动成功立刻 stop()（毫秒级窗口），
//  并且启动/停止的结果如实写进 JSON 的 driverStarted / driverError / notes。
//  不做「让 driver 跑满 1 秒」那种更真实的做法 —— 那会在验证期间真的抢焦点。

import AppKit
import Foundation

enum SelfTest {

    /// 用真正的 NSApp.run() 走一遍和常驻模式一样的生命周期。
    /// 早先用 RunLoop.main.run(until:) 试过：那样状态栏项不一定会被 MenuBarAgent 接管，
    /// button.window 的 isVisible 会假阴性 —— 自检本身不能有假阴性。
    static func run() -> Never {
        let ctx = Context()
        ctx.uiSmokeRequested = CommandLine.arguments.contains("--selftest-ui")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 1) 装配（不启动鼠标监听）
        let env = AppEnvironment.make()
        ctx.env = env

        // 2) 建 status item —— 自检的核心目标
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        ctx.statusItem = item
        ctx.statusItemCreated = (item.button != nil)

        // 挂一个真菜单：菜单栏项有了菜单才和常驻模式形态一致
        let menu = NSMenu()
        menu.addItem(withTitle: "HoverFocus 自检模式", action: nil, keyEquivalent: "")
        item.menu = menu

        let axTrusted = Permissions.isAccessibilityTrusted
        let settings = env.settings.settings
        let state = StatusIcon.state(settings: settings,
                                     axTrusted: axTrusted,
                                     requiresAccessibility: env.monitorRequiresAccessibility,
                                     driverError: nil)
        ctx.iconState = state
        ctx.symbolName = StatusIcon.symbolName(for: state)

        if let button = item.button {
            let tip = StatusIcon.tooltip(state: state, settings: settings, axTrusted: axTrusted,
                                         driverRunning: false, driverError: nil)
            StatusIcon.apply(to: button, state: state, tooltip: tip)
        } else {
            ctx.notes.append("NSStatusItem.button 为 nil：状态栏项没建起来")
        }

        // 3) 等 1s（契约要求），期间状态栏完成布局
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            finish(ctx, reason: "timer")
        }
        RunLoop.main.add(timer, forMode: .common)

        // 兜底：万一 timer 没被调度（自检不能挂住 的脚本），5s 后照样出 JSON
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            finish(ctx, reason: "fallback-timeout")
        }

        app.run()

        // app.run() 正常不会返回；真返回了也保证有输出
        finish(ctx, reason: "run-returned")
    }

    // MARK: - UI 冒烟测试

    /// 构造完整菜单 + 设置窗口，把结果记进 ctx。
    /// 注意：**不显示**设置窗口（不抢焦点、不弹窗），只验证构造路径不崩。
    private static func runUISmoke(_ ctx: Context, env: AppEnvironment) {
        let delegate = AppDelegate()
        delegate.selftestPrepare(env: env)

        if let builtMenu = delegate.selftestBuildMenu() {
            ctx.menuBuilt = true
            ctx.menuItemCount = builtMenu.items.count
            ctx.menuTopLevelTitles = builtMenu.items.map { item in
                item.submenu != nil ? "\(item.title) ▸" : item.title
            }
        } else {
            ctx.uiErrors.append("菜单构造返回 nil")
        }

        if let window = delegate.selftestBuildSettingsWindow() {
            ctx.settingsWindowBuilt = (window.window != nil)
            if let content = window.window?.contentView {
                ctx.settingsWindowControls = countControls(in: content)
            }
            window.close()
        } else {
            ctx.uiErrors.append("设置窗口构造返回 nil")
        }
    }

    /// 递归数控件个数：用来证明设置窗口里的控件**真的建出来了**
    /// （构造成功但控件是空的，也算失败）
    private static func countControls(in view: NSView) -> Int {
        var total = 0
        for sub in view.subviews {
            if sub is NSControl { total += 1 }
            total += countControls(in: sub)
        }
        return total
    }

    // MARK: - 上下文

    private final class Context {
        var statusItem: NSStatusItem?
        var env: AppEnvironment?
        var statusItemCreated = false
        var driverStarted = false
        var driverError: String?
        var iconState: IconState = .permissionMissing
        var symbolName = ""
        var notes: [String] = []
        var finished = false
        let beganAt = Date()

        // --selftest-ui 才会填
        var uiSmokeRequested = false
        var menuBuilt = false
        var menuItemCount = 0
        var menuTopLevelTitles: [String] = []
        var settingsWindowBuilt = false
        var settingsWindowControls = 0
        var uiErrors: [String] = []
    }

    // MARK: - 收尾：采集 + 打印单行 JSON + exit 0

    private static func finish(_ ctx: Context, reason: String) -> Never {
        // 已经出过 JSON 了（例如兜底定时器先到）就直接退出，绝不打印两行
        guard !ctx.finished else { exit(0) }
        ctx.finished = true

        var selftestError: String? = nil

        // 驱动：**无条件**尝试启动，用抛错表达失败。
        // 这是「零权限真的能用」的关键证据：默认轮询事件源在未授权时也应该启动成功，
        // 所以未授权 + driverStarted=false 就说明 App 层又混进了权限门禁。
        // 启动成功后立刻 stop()（见文件头安全说明：自检不抢用户焦点）。
        if let env = ctx.env {
            do {
                try env.driver.start()
                ctx.driverStarted = true
                ctx.notes.append("driver 已启动并立即停止（自检不抢用户焦点）")
                env.driver.stop()
            } catch {
                ctx.driverError = "\(error)"
                ctx.notes.append("driver 启动失败：\(error)")
            }
        } else {
            selftestError = "AppEnvironment 装配失败"
        }

        // UI 冒烟测试（--selftest-ui）：本机看不到屏幕，菜单和设置窗口是唯一没法肉眼验的部分，
        // 所以至少把它们的构造路径跑一遍。崩了就是崩了，必须暴露出来。
        if ctx.uiSmokeRequested, let env = ctx.env {
            runUISmoke(ctx, env: env)
        }

        let item = ctx.statusItem
        let button = item?.button
        let window = button?.window
        let visible = window?.isVisible ?? false
        let frame = window?.frame ?? .zero
        let frameString = String(format: "%.1f,%.1f,%.1f,%.1f",
                                 frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)

        if !ctx.statusItemCreated {
            selftestError = selftestError ?? "NSStatusItem 创建失败（button 为 nil）"
        } else if window == nil {
            ctx.notes.append("button.window 为 nil：菜单栏项没有承载窗口")
        }

        var payload: [String: Any] = [:]

        // ── 契约要求的字段（一个都不能少）──
        payload["statusItemCreated"] = ctx.statusItemCreated
        payload["buttonWindowVisible"] = visible
        payload["buttonWindowFrame"] = frameString
        payload["axTrusted"] = Permissions.isAccessibilityTrusted
        payload["version"] = AppInfo.version
        payload["driverStarted"] = ctx.driverStarted
        payload["error"] = selftestError ?? NSNull()

        // ── 附加字段（契约说「至少包含」，多给的用于排障）──
        payload["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        payload["bundleID"] = AppInfo.bundleID
        payload["bundlePath"] = AppInfo.appBundlePath
        payload["executablePath"] = AppInfo.executablePath
        payload["isRunningFromBundle"] = AppInfo.isRunningFromBundle
        payload["hasButton"] = (button != nil)
        payload["buttonTitle"] = button?.title ?? ""
        payload["iconState"] = ctx.iconState.rawValue
        payload["iconSymbol"] = ctx.symbolName
        payload["menuItemCount"] = item?.menu?.items.count ?? 0
        payload["statusBarThickness"] = Double(NSStatusBar.system.thickness)
        payload["screenCount"] = NSScreen.screens.count
        payload["mainScreenFrame"] = NSScreen.screens.first.map {
            String(format: "%.1f,%.1f,%.1f,%.1f", $0.frame.origin.x, $0.frame.origin.y,
                   $0.frame.size.width, $0.frame.size.height)
        } ?? ""
        payload["driverRunning"] = ctx.env?.driver.isRunning ?? false
        payload["driverError"] = ctx.driverError ?? NSNull()
        payload["monitorMode"] = ctx.env?.monitorMode.rawValue ?? "unknown"
        payload["monitorRequiresAccessibility"] = ctx.env?.monitorRequiresAccessibility ?? false
        payload["hitTestMode"] = (ctx.env?.probe as? WindowProbe)?.hitTestMode.rawValue ?? "unknown"
        payload["skyLightAvailable"] = SkyLightBridge.isAvailable
        if ctx.uiSmokeRequested {
            payload["uiSmoke"] = [
                "menuBuilt": ctx.menuBuilt,
                "menuItemCount": ctx.menuItemCount,
                "menuTopLevelTitles": ctx.menuTopLevelTitles,
                "settingsWindowBuilt": ctx.settingsWindowBuilt,
                "settingsWindowControls": ctx.settingsWindowControls,
                "errors": ctx.uiErrors,
            ]
        }
        payload["settings"] = [
            "enabled": ctx.env?.settings.settings.enabled ?? false,
            "mode": ctx.env?.settings.settings.mode.rawValue ?? "unknown",
            "dwellDelay": ctx.env?.settings.settings.dwellDelay ?? 0,
            "cooldown": ctx.env?.settings.settings.cooldown ?? 0,
        ]
        payload["notes"] = ctx.notes
        payload["finishReason"] = reason
        payload["elapsedMs"] = Int(Date().timeIntervalSince(ctx.beganAt) * 1000)

        // 单行 JSON：用 JSONSerialization 保证转义正确，sortedKeys 保证可复现
        let json: String
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            json = String(data: data, encoding: .utf8) ?? "{\"error\":\"JSON 编码失败\"}"
        } catch {
            json = "{\"error\":\"JSON 序列化失败：\(error)\"}"
        }

        // 契约要求：单行 JSON 到 stdout，然后 exit 0
        FileHandle.standardOutput.write(Data((json + "\n").utf8))
        FileHandle.standardOutput.synchronizeFile()

        exit(0)
    }
}
