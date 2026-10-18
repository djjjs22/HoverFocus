//  HoverFocus — 菜单栏 App 主体
//
//  职责：
//    - NSStatusItem 三态图标（开 / 关 / 权限缺失）
//    - 菜单：总开关、模式、排除当前 App、打开设置、权限引导、开机自启、诊断、退出
//    - 权限轮询：授权后**不用重启**就能开始工作
//    - FocusDriver 生命周期（权限不足不启动；权限到位自动启动）
//
//  线程约定：契约要求这些类型都只在主线程用，所以本类所有状态都在主线程读写。
//  唯一的外部回调来源是 FocusDriverDelegate 与 SettingsStore 观察者，两者都在主线程触发；
//  设置窗口那边额外做了「非主线程就 dispatch 回来」的保险。

import AppKit
import Foundation
import Carbon.HIToolbox   // 全局快捷键：kVK_ANSI_H / controlKey / optionKey

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, FocusDriverDelegate {

    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var env: AppEnvironment?
    private var settingsWindowController: SettingsWindowController?
    /// 首次启动 3 步引导。懒创建，菜单里可以重新打开。
    private var firstRunWindowController: FirstRunWindowController?

    /// 全局快捷键 ⌃⌥H（暂停 / 恢复悬停切换）。零权限，Carbon 注册。
    private var globalHotkey: GlobalHotkey?
    /// 注册失败（例如快捷键被别的 App 占用）→ 菜单里如实说明，绝不静默
    private var hotkeyRegistrationFailed = false

    private var permissionTimer: Timer?
    private var axTrusted = false
    private var driverError: String?
    /// 上一次已经记过日志的启动失败原因（同样的原因不重复刷日志）
    private var lastLoggedDriverError: String?
    private var lastDriverAttemptAt: Date?

    private var cachedLoginStatus: LaunchAtLoginStatus?
    private var cachedLoginStatusAt: Date?

    /// 权限轮询间隔（秒）。契约验收标准第 4 条：授权后不用重启。
    private let permissionPollInterval: TimeInterval = 1.0
    /// 驱动启动失败后的重试间隔（避免每秒刷日志）
    private let driverRetryInterval: TimeInterval = 5.0
    /// 连续读到同一个 axTrusted 值多少次才认定权限真的迁移了（见 pollPermissions 注释）
    private let permissionStableTicks = 3
    private var observedTrusted: Bool?
    private var observedTrustedTicks = 0

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── 第一件事：关掉 AppKit 的自动终止 ──────────────────────────
        // 这个 App 只靠 NSStatusItem 存活、一个窗口都没有，AppKit 会判定它「空闲可回收」，
        // 打上 _kLSApplicationWouldBeTerminatedByTALKey=1 之后随时可能被系统杀掉。
        // 实测表现：启动 3~4 秒后进程静默消失、菜单栏图标不见了（间歇性，不能赌）。
        // Info.plist 里已经写了 NSSupportsAutomaticTermination=false，
        // 这里再加一道运行时保险 —— plist 有可能被系统缓存的旧副本覆盖。
        ProcessInfo.processInfo.disableAutomaticTermination("HoverFocus 是常驻菜单栏工具，必须一直活着")
        ProcessInfo.processInfo.disableSuddenTermination()

        Log.info("启动 \(AppInfo.versionLine)；bundle=\(AppInfo.appBundlePath)；pid=\(getpid())")

        FrontmostAppTracker.shared.start()

        env = AppEnvironment.make()

        axTrusted = Permissions.isAccessibilityTrusted
        // 启动时的读数直接视为「已稳定」，这样后续任何变化都要重新攒满稳定窗口
        observedTrusted = axTrusted
        observedTrustedTicks = permissionStableTicks
        if axTrusted {
            Log.info("辅助功能权限：已授予（命中测试可用精确模式）")
        } else {
            Log.info("辅助功能权限：未授予 —— 不影响使用：轮询事件源 + 降级命中测试零权限可用，"
                     + "只是窗口重叠/圆角处精度较低。授予后无需重启即可升级为精确模式。")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        menu.delegate = self
        statusItem = item
        refreshStatusItem()

        env?.settings.addObserver { [weak self] _ in
            DispatchQueue.main.async { self?.settingsDidChange() }
        }

        // 无条件尝试启动：FocusDriver.start() 只在「事件源声明需要权限且未授权」时抛错。
        // 默认的轮询事件源零权限可用，所以这里**绝不能**再用 axTrusted 当门禁 ——
        // 那会让「零权限可用」这个产品前提直接失效。
        startDriver()

        installPermissionPolling()

        // 全局快捷键 ⌃⌥H。放在 status item 之后：注册失败要在菜单里如实显示。
        installGlobalHotkey()

        // 首次启动引导放最后：菜单栏图标已经就绪，引导里说的「点菜单栏图标」当场就成立。
        // 用 DispatchQueue 推迟到本次 runloop 之后，避免和 status item 的首次布局抢时序。
        if !FirstRunWindowController.hasShown {
            DispatchQueue.main.async { [weak self] in
                self?.showFirstRunGuide(autoTriggered: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("退出：停止鼠标监听")
        env?.driver.stop()
        permissionTimer?.invalidate()
        permissionTimer = nil
        // 还原自动终止设置（正常退出时其实无所谓，但别留一个被改过的全局状态）
        ProcessInfo.processInfo.enableAutomaticTermination("HoverFocus 正在退出")
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    // MARK: - 驱动生命周期

    private func startDriver() {
        guard let env else { return }

        lastDriverAttemptAt = Date()
        env.driver.delegate = self
        do {
            try env.driver.start()
            driverError = nil
            lastLoggedDriverError = nil
            Log.info("鼠标监听已启动（事件源=\(env.monitorMode.shortName)，"
                     + "tick=\(String(format: "%.3f", env.driver.tickInterval))s）")
        } catch {
            // 不许静默失败：原因要进日志、进菜单、进诊断面板。
            // 但同一个原因只记一次日志，避免每 5 秒重试刷屏。
            driverError = "\(error)"
            if lastLoggedDriverError != driverError {
                Log.error("鼠标监听启动失败：\(error)")
                lastLoggedDriverError = driverError
            }
        }
        refreshStatusItem()
    }

    private func stopDriver() {
        env?.driver.stop()
        Log.info("鼠标监听已停止")
        refreshStatusItem()
    }

    private func installPermissionPolling() {
        let timer = Timer(timeInterval: permissionPollInterval, repeats: true) { [weak self] _ in
            self?.pollPermissions()
        }
        // .common 模式：菜单弹出时（菜单跟踪会切 run loop mode）也要继续轮询，
        // 否则「刚授权完就打开菜单」会看到过期状态。
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func pollPermissions() {
        let trusted = Permissions.isAccessibilityTrusted

        // ── 稳定窗口 ────────────────────────────────────────────────────────
        // AXIsProcessTrusted 的取值依赖「哪个二进制 / 哪种启动方式」：实测同一台机器、
        // 几乎同一时刻，shell 直接 exec 与经 `open` 启动的两份副本结论相反
        // （TCC 按责任进程归属判定）。所以它不是一个能拿来做瞬时门禁的布尔值 ——
        // 连续 3 次（约 3 秒）读到同一值才认定「状态真的迁移了」，抖一次不动作。
        if observedTrusted == trusted {
            observedTrustedTicks += 1
        } else {
            observedTrusted = trusted
            observedTrustedTicks = 1
        }

        if observedTrustedTicks >= permissionStableTicks, trusted != axTrusted {
            axTrusted = trusted
            refreshHitTestMode()

            // 要不要权限由**事件源自己声明**，App 层不替它决定。
            // 轮询事件源零权限可用 —— 权限掉了也绝不能停它，否则会出现
            // 「图标显示已开启、其实已经没在干活」这种最坏的静默失败。
            if trusted {
                driverError = nil
                lastLoggedDriverError = nil
                Log.info("辅助功能权限已授予（连续 \(permissionStableTicks) 次确认）；命中测试将升级为精确模式")
                if let env, !env.driver.isRunning {
                    startDriver()
                } else {
                    refreshStatusItem()
                }
            } else if let env, env.monitorRequiresAccessibility {
                stopDriver()
                Log.info("辅助功能权限已撤销（连续 \(permissionStableTicks) 次确认）；"
                         + "当前事件源「\(env.monitorMode.shortName)」声明需要权限，已停止鼠标监听")
            } else {
                // 轮询模式：权限掉了不影响工作，只影响命中精度。如实说明，且**不改驱动状态**。
                Log.info("辅助功能权限已撤销（连续 \(permissionStableTicks) 次确认）；"
                         + "本次不改变驱动状态（轮询模式不需要权限），只影响命中精度")
                refreshStatusItem()
            }
        }

        // 监听没在跑 → 重试（事件源可能被系统干掉、或上次启动失败）。
        // 这里**不判 axTrusted**：要不要权限由事件源自己声明，App 层不该替它决定。
        guard let env, !env.driver.isRunning else { return }
        if let last = lastDriverAttemptAt, Date().timeIntervalSince(last) < driverRetryInterval { return }
        startDriver()
    }

    /// 权限状态变了：命中测试模式要跟着切（精确 ↔ 降级），否则降级模式会一直粘着
    private func refreshHitTestMode() {
        (env?.probe as? WindowProbe)?.refreshHitTestMode()
    }

    private func settingsDidChange() {
        refreshStatusItem()
        guard let env else { return }
        // 打开总开关时清掉 pending / 冷却，避免「刚打开就立刻抢一次焦点」
        if env.settings.settings.enabled {
            env.driver.engine.reset()
            if !env.driver.isRunning { startDriver() }
        }
    }

    // MARK: - 权限快照

    /// 权限不是一个布尔值。实测结论：未授权时 CGEvent.tapCreate 会成功返回 tap，
    /// 但系统立刻把它禁用、收到 0 个事件 —— 所以「tap 建好了」不等于「能收到事件」。
    /// 这里把三个信号一起取，才能给用户准确的三态（见 StatusIcon.state）。
    private struct PermissionSnapshot {
        var axTrusted: Bool
        var listenEventAccess: Bool
        var postEventAccess: Bool
        var tapEnabled: Bool

        /// 已给辅助功能但收不到鼠标事件 → 需要用户再去「输入监控」勾一次
        var inputMonitoringMissing: Bool {
            guard axTrusted else { return false }
            if !listenEventAccess { return true }
            // tap 存在但被系统禁用，同样属于这一类
            return false
        }
    }

    private func permissionSnapshot() -> PermissionSnapshot {
        let diag = env?.monitorDiagnosis() ?? [:]
        let tap = (env?.monitor as? MouseMonitor)?.isTapEnabled ?? false
        return PermissionSnapshot(
            // 用去抖后的 axTrusted，和驱动逻辑保持同一个值：
            // 否则低延迟模式下图标会跟着抖动闪烁（UI 说坏了但其实还在工作）
            axTrusted: axTrusted,
            listenEventAccess: (diag["listenEventAccess"] as? Bool) ?? CGPreflightListenEventAccess(),
            postEventAccess: (diag["postEventAccess"] as? Bool) ?? CGPreflightPostEventAccess(),
            tapEnabled: tap)
    }

    /// 当前图标状态（所有显示路径都走这里，保证菜单/图标/tooltip 一致）
    ///
    /// 关键点：**只有选了需要权限的事件源时，权限问题才算问题**。
    /// 默认的轮询模式零权限可用，这时候不该拿「缺权限」去吓用户。
    private func currentState() -> IconState {
        guard let env else { return .error }
        let settings = env.settings.settings
        let snap = permissionSnapshot()

        if env.monitorRequiresAccessibility {
            if !snap.axTrusted { return .permissionMissing }
            if snap.inputMonitoringMissing { return .inputMonitoringMissing }
        }
        if !settings.enabled { return .off }
        if driverError != nil { return .error }
        return settings.mode == .focusAndRaise ? .onRaise : .on
    }

    /// 命中测试模式：精确（AX）还是降级（窗口列表）。
    /// 降级模式**不需要任何权限**也能用（分屏场景够用，窗口重叠时会判错），
    /// 所以必须如实告诉用户当前精度，别让他以为这就是最终效果。
    private func hitTestModeText() -> String? {
        guard let probe = env?.probe as? WindowProbe else { return nil }
        switch probe.hitTestMode {
        case .accessibility:
            return "精确模式（AX 命中测试）"
        case .windowListFallback:
            return "⚠️ 降级模式（窗口列表）：未授予辅助功能权限，窗口重叠/圆角处可能判错"
        }
    }

    // MARK: - 菜单栏图标

    private func refreshStatusItem() {
        guard let button = statusItem?.button, let env else { return }
        let settings = env.settings.settings
        let state = currentState()
        let tooltip = StatusIcon.tooltip(state: state, settings: settings, axTrusted: axTrusted,
                                         driverRunning: env.driver.isRunning, driverError: driverError,
                                         hotkeyAvailable: !hotkeyRegistrationFailed)
        StatusIcon.apply(to: button, state: state, tooltip: tooltip)
    }

    private func currentIconState() -> IconState { currentState() }

    /// 菜单第一行下面那句人话。菜单里放不下长句，这里单独收短。
    private func shortSummary() -> String {
        guard let env else { return "内部状态异常" }
        let settings = env.settings.settings
        let state = currentState()

        switch state {
        case .permissionMissing:
            return "⚠️ 已选低延迟模式（CGEventTap）但未授予权限 —— 收不到鼠标事件"
        case .inputMonitoringMissing:
            return "⚠️ 已给辅助功能，但收不到鼠标事件（缺「输入监控」）"
        case .error:
            return "⚠️ 鼠标监听未运行：\(driverError ?? "未知原因")"
        case .off:
            return "已关闭：悬停不会切换焦点"
        case .on, .onRaise:
            let ms = Int((settings.dwellDelay * 1000).rounded())
            let cd = Int((settings.cooldown * 1000).rounded())
            return "悬停 \(ms)ms 后切换键盘焦点；冷却 \(cd)ms；\(settings.mode.displayName)"
        }
    }

    /// 监听方式 + 命中精度一行说明。默认（轮询 + 降级）是正常状态，不是异常。
    private func monitorLine() -> String {
        guard let env else { return "" }
        var text = "监听：\(env.monitorMode.shortName)"
        text += env.monitorMode.requiresAccessibility ? "（需要权限）" : "（零权限）"
        switch (env.probe as? WindowProbe)?.hitTestMode {
        case .accessibility:
            text += " · 命中精度：精确（AX）"
        case .windowListFallback:
            text += " · 命中精度：降级（窗口列表）"
        case .none:
            break
        }
        return text
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let env else {
            let broken = NSMenuItem(title: "HoverFocus 内部状态异常（AppEnvironment 未装配）",
                                    action: nil, keyEquivalent: "")
            broken.isEnabled = false
            menu.addItem(broken)
            return
        }

        let settings = env.settings.settings
        let state = currentState()
        let snapshot = permissionSnapshot()

        // ── 状态 ───────────────────────────────────────────────
        let titleItem = NSMenuItem(title: "\(AppInfo.versionLine) — \(state.displayName)",
                                   action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let summaryItem = NSMenuItem(title: shortSummary(), action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)

        // 监听方式 + 命中精度：默认（轮询 + 降级）是**正常状态**，不是异常
        let monitorItem = NSMenuItem(title: monitorLine(), action: nil, keyEquivalent: "")
        monitorItem.isEnabled = false
        menu.addItem(monitorItem)

        menu.addItem(.separator())

        // ── 总开关 ─────────────────────────────────────────────
        // 注意：**不能**因为「没授权」就禁用总开关 —— 默认的轮询模式零权限可用，
        // 未授权是完全正常的状态，禁用开关会让用户以为软件坏了。
        // 注册失败时标题里不写 ⌃⌥H，否则标题和下面那条警告自相矛盾
        let enabledTitle = hotkeyRegistrationFailed ? "启用悬停切换焦点" : "启用悬停切换焦点（⌃⌥H）"
        let enabledItem = NSMenuItem(title: enabledTitle,
                                     action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = settings.enabled ? .on : .off
        menu.addItem(enabledItem)

        // 快捷键注册失败必须如实说：用户按了没反应却没有任何解释，是最糟的体验。
        if hotkeyRegistrationFailed {
            let warn = NSMenuItem(title: "⚠️ 全局快捷键 ⌃⌥H 注册失败（可能被其他 App 占用）",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        // ── 模式 ───────────────────────────────────────────────
        let modeParent = NSMenuItem(title: "模式：\(settings.mode.displayName)", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in ActivationMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == settings.mode) ? .on : .off
            modeMenu.addItem(item)
        }
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        // ── 监听方式（事件源） ─────────────────────────────────
        let monitorParent = NSMenuItem(title: "监听方式：\(env.monitorMode.shortName)",
                                       action: nil, keyEquivalent: "")
        let monitorMenu = NSMenu()
        for mode in MonitorMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMonitorMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == env.monitorMode) ? .on : .off
            monitorMenu.addItem(item)
        }
        monitorMenu.addItem(.separator())
        let monitorHint = NSMenuItem(
            title: env.monitorMode == .polling
                ? "轮询：零权限即可用，最坏延迟一个周期（16ms）"
                : "低延迟：需要辅助功能权限，未授权时收不到鼠标事件",
            action: nil, keyEquivalent: "")
        monitorHint.isEnabled = false
        monitorMenu.addItem(monitorHint)
        monitorParent.submenu = monitorMenu
        menu.addItem(monitorParent)

        menu.addItem(.separator())

        // ── 排除当前 App ───────────────────────────────────────
        FrontmostAppTracker.shared.refresh()
        let tracker = FrontmostAppTracker.shared
        let excludeItem = NSMenuItem(title: "", action: #selector(toggleExcludeCurrentApp), keyEquivalent: "")
        excludeItem.target = self
        if let display = tracker.displayName {
            let excluded = SettingsEditing.isExcluded(settings, bundleID: tracker.bundleID, name: tracker.name)
            excludeItem.title = excluded
                ? "取消排除「\(display)」"
                : "排除「\(display)」（悬停不抢它的焦点）"
            excludeItem.isEnabled = true
        } else {
            excludeItem.title = "排除当前 App（未检测到前台 App）"
            excludeItem.isEnabled = false
        }
        menu.addItem(excludeItem)

        menu.addItem(.separator())

        // ── 设置 ───────────────────────────────────────────────
        let settingsItem = NSMenuItem(title: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // ── 精度 / 权限（注意：权限是可选的精度增强，不是使用前提）──
        if env.monitorMode.requiresAccessibility && !snapshot.axTrusted {
            // 选了需要权限的低延迟模式却没给权限 —— 这个确实该报警，而且要给一键回退
            let warn = NSMenuItem(title: "⚠️ 已选低延迟模式（CGEventTap），但缺少辅助功能权限",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)

            let why = NSMenuItem(title: "未授权时 CGEventTap 收不到任何鼠标事件，功能不会生效",
                                 action: nil, keyEquivalent: "")
            why.isEnabled = false
            menu.addItem(why)

            let request = NSMenuItem(title: "请求辅助功能权限…",
                                     action: #selector(requestAccessibilityPermission), keyEquivalent: "")
            request.target = self
            menu.addItem(request)

            let openPane = NSMenuItem(title: "打开系统设置 › 隐私与安全性 › 辅助功能…",
                                      action: #selector(openAccessibilitySettings), keyEquivalent: "")
            openPane.target = self
            menu.addItem(openPane)

            // 一键退回零权限模式：用户不该为了「能跑起来」去翻设置
            let fallback = NSMenuItem(title: "改回零权限的轮询模式（马上可用）",
                                      action: #selector(fallbackToPolling), keyEquivalent: "")
            fallback.target = self
            menu.addItem(fallback)

            menu.addItem(.separator())
        } else if env.monitorMode.requiresAccessibility && snapshot.inputMonitoringMissing {
            // 辅助功能给了、输入监控没给 —— 这时图标看着「正常」但怎么悬停都没反应，
            // 是最容易让人以为「软件坏了」的一种状态，必须明说。
            let warn = NSMenuItem(title: "⚠️ 已授予辅助功能，但收不到鼠标事件",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)

            let why = NSMenuItem(title: "需要再去「系统设置 → 隐私与安全性 → 输入监控」里勾选 HoverFocus",
                                 action: nil, keyEquivalent: "")
            why.isEnabled = false
            menu.addItem(why)

            let openInput = NSMenuItem(title: "打开「输入监控」设置…",
                                       action: #selector(openInputMonitoringSettings), keyEquivalent: "")
            openInput.target = self
            menu.addItem(openInput)

            let fallback = NSMenuItem(title: "改回零权限的轮询模式（马上可用）",
                                      action: #selector(fallbackToPolling), keyEquivalent: "")
            fallback.target = self
            menu.addItem(fallback)

            menu.addItem(.separator())
        } else if !snapshot.axTrusted {
            // 轮询 + 未授权：**这是默认状态，完全正常**。这里只做「可选升级」的提示，
            // 不用警告语气，也不能挡住任何功能。
            if let modeText = hitTestModeText() {
                let info = NSMenuItem(title: "命中精度：\(modeText)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }

            let upgrade = NSMenuItem(title: "授予辅助功能权限以提高命中精度（可选）…",
                                     action: #selector(requestAccessibilityPermission), keyEquivalent: "")
            upgrade.target = self
            menu.addItem(upgrade)

            menu.addItem(.separator())
        } else {
            // 轮询 + 已授权 → 精确模式
            if let modeText = hitTestModeText() {
                let info = NSMenuItem(title: "命中精度：\(modeText)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }
            menu.addItem(.separator())
        }

        // ── 开机自启 ───────────────────────────────────────────
        let login = loginStatus()
        let loginParent = NSMenuItem(title: "开机自启：\(loginTitle(login))", action: nil, keyEquivalent: "")
        let loginMenu = NSMenu()

        let loginToggle = NSMenuItem(title: "开机自动启动",
                                     action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginToggle.target = self
        loginToggle.state = login.isOn ? .on : .off
        loginMenu.addItem(loginToggle)

        let loginDetail = NSMenuItem(title: login.detail, action: nil, keyEquivalent: "")
        loginDetail.isEnabled = false
        loginMenu.addItem(loginDetail)

        if let err = login.error {
            let errItem = NSMenuItem(title: "错误：\(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            loginMenu.addItem(errItem)
        }
        if let path = login.agentPath {
            let pathItem = NSMenuItem(title: "plist：\(path)", action: nil, keyEquivalent: "")
            pathItem.isEnabled = false
            loginMenu.addItem(pathItem)
        }

        loginMenu.addItem(.separator())
        let recheck = NSMenuItem(title: "重新检测状态", action: #selector(refreshLoginStatus), keyEquivalent: "")
        recheck.target = self
        loginMenu.addItem(recheck)

        loginParent.submenu = loginMenu
        menu.addItem(loginParent)

        // ── 诊断 ───────────────────────────────────────────────
        let diagParent = NSMenuItem(title: "诊断信息", action: nil, keyEquivalent: "")
        let diagMenu = NSMenu()
        var lines = DiagnosticsLog.shared.summaryLines(
            stats: env.driver.engineStats,
            settings: settings,
            axTrusted: snapshot.axTrusted,
            driverRunning: env.driver.isRunning,
            driverError: driverError)
        lines.append(contentsOf: diagnosticsExtras())
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            diagMenu.addItem(item)
        }
        diagMenu.addItem(.separator())
        let copyItem = NSMenuItem(title: "复制完整诊断信息到剪贴板",
                                  action: #selector(copyDiagnostics), keyEquivalent: "")
        copyItem.target = self
        diagMenu.addItem(copyItem)
        diagParent.submenu = diagMenu
        menu.addItem(diagParent)

        // ── 重新显示欢迎引导（靠近诊断/关于）─────────────────────
        let guideItem = NSMenuItem(title: "重新显示欢迎引导",
                                   action: #selector(reopenFirstRunGuide), keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        menu.addItem(.separator())

        // ── 退出 ───────────────────────────────────────────────
        let quit = NSMenuItem(title: "退出 HoverFocus",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// 只有 AppDelegate 知道的诊断信号（命中测试精度、私有 SkyLight 是否可用等）。
    /// 这些直接影响「只切焦点不置顶」能不能真的做到，必须能在诊断里看到。
    private func diagnosticsExtras() -> [String] {
        var out: [String] = []
        if let env {
            out.append("事件源：\(env.monitorMode.shortName)（\(env.monitorMode.displayName)）")
            out.append("事件源声明需要权限：\(env.monitorRequiresAccessibility)")
        }
        if let modeText = hitTestModeText() {
            out.append("命中测试：\(modeText)")
        }
        out.append("SkyLight 私有符号可用：\(SkyLightBridge.isAvailable)"
                   + (SkyLightBridge.isAvailable ? "" : "（不可用时「不置顶」会退化成置顶）"))
        if let env {
            out.append("tick 定时器有效：\(env.driver.isTicking)")
            for (k, v) in env.monitorDiagnosis().sorted(by: { $0.key < $1.key }) {
                out.append("  \(k) = \(v)")
            }
        }
        return out
    }

    private func loginTitle(_ status: LaunchAtLoginStatus) -> String {
        switch status.state {
        case .enabled:         return status.mechanism.displayName
        case .pendingApproval: return "待你在系统设置里批准"
        case .failed:          return "启用失败 ⚠️"
        case .disabled:        return "未启用"
        }
    }

    private func loginStatus(forceRefresh: Bool = false) -> LaunchAtLoginStatus {
        if !forceRefresh,
           let cached = cachedLoginStatus,
           let at = cachedLoginStatusAt,
           Date().timeIntervalSince(at) < 2.0 {
            return cached
        }
        let status = LaunchAtLogin.status()
        cachedLoginStatus = status
        cachedLoginStatusAt = Date()
        return status
    }

    // MARK: - 自检钩子（--selftest-ui 用）
    //
    //  设置窗口和菜单是「看不见就验证不了」的部分：本机 screencapture 被拒、也没法自动点击。
    //  所以留一个入口，让自检能把这两条构造路径**真的跑一遍** ——
    //  构造时崩了就是崩了，总比交付一个点开就闪退的菜单强。

    func selftestPrepare(env: AppEnvironment) {
        self.env = env
        self.axTrusted = Permissions.isAccessibilityTrusted
        FrontmostAppTracker.shared.start()
    }

    /// 构造完整菜单（不建 status item、不启动 driver）
    func selftestBuildMenu() -> NSMenu? {
        guard env != nil else { return nil }
        let built = NSMenu()
        populate(built)
        return built
    }

    /// 构造设置窗口（不显示）
    func selftestBuildSettingsWindow() -> SettingsWindowController? {
        guard let env else { return nil }
        return SettingsWindowController(store: env.settings,
                                        monitorMode: env.monitorMode,
                                        onMonitorModeChange: { _ in })
    }

    // MARK: - 全局快捷键

    /// 注册 ⌃⌥H 暂停/恢复。Carbon 实现，**零权限**（NSEvent 全局监听需要辅助功能权限，
    /// 用它做「暂停开关」等于为了关功能还得先授权）。
    private func installGlobalHotkey() {
        let hotkey = GlobalHotkey()
        let ok = hotkey.register(keyCode: UInt32(kVK_ANSI_H),
                                 modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggleEnabledFromHotkey()
        }
        globalHotkey = ok ? hotkey : nil
        hotkeyRegistrationFailed = !ok
        if ok {
            Log.info("全局快捷键已注册：⌃⌥H（暂停 / 恢复悬停切换）")
        } else {
            // 最常见原因是已被别的 App 占用。必须让用户知道 ——
            // 「按了没反应且没有任何解释」是最糟的体验。菜单里会显示这条。
            Log.error("全局快捷键 ⌃⌥H 注册失败（可能已被其他程序占用）；功能仍可用菜单开关")
        }
    }

    /// 快捷键触发的切换。**复用同一个 enabled 开关**，不引入第二套「暂停」状态 ——
    /// 少一个状态就少一类「以为开着其实关着」的困惑，图标/引擎/持久化全部自动跟随。
    private func toggleEnabledFromHotkey() {
        toggleEnabled()
        guard let env else { return }
        Log.info("全局快捷键 ⌃⌥H → \(env.settings.settings.enabled ? "恢复悬停切换" : "暂停悬停切换")")
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled() {
        guard let env else { return }
        let target = !env.settings.settings.enabled
        SettingsEditing.setEnabled(env.settings, target)
        Log.info("总开关 → \(target ? "开" : "关")")
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let env, let raw = sender.representedObject as? String,
              let mode = ActivationMode(rawValue: raw) else { return }
        SettingsEditing.setMode(env.settings, mode)
    }

    @objc private func selectMonitorMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MonitorMode(rawValue: raw) else { return }
        applyMonitorMode(mode)
    }

    /// 低延迟模式起不来时的一键回退。用户不该为了「能用」去翻设置。
    @objc private func fallbackToPolling() {
        applyMonitorMode(.polling)
        DispatchQueue.main.async { [weak self] in
            self?.presentAlert(title: "已改回轮询模式",
                               message: "轮询模式不需要任何权限，现在应该已经可以用了。"
                                      + "想用低延迟模式的话，先授予辅助功能权限再切回去。")
        }
    }

    /// 切换事件源：必须停旧 driver、重建、再按原状态决定是否启动。
    private func applyMonitorMode(_ mode: MonitorMode) {
        guard let env else { return }
        guard mode != env.monitorMode else { return }

        let wasRunning = env.driver.isRunning
        env.driver.delegate = nil
        env.driver.stop()

        env.switchMonitor(to: mode)      // 重建 driver（monitor 是 let）
        driverError = nil
        lastLoggedDriverError = nil

        if wasRunning || env.settings.settings.enabled {
            startDriver()
        }
        settingsWindowController?.updateMonitorMode(mode)
        refreshStatusItem()
    }

    @objc private func toggleExcludeCurrentApp() {
        guard let env else { return }
        FrontmostAppTracker.shared.refresh()
        let tracker = FrontmostAppTracker.shared
        guard tracker.bundleID != nil || tracker.name != nil else { NSSound.beep(); return }

        let nowExcluded = SettingsEditing.toggleExclusion(env.settings, bundleID: tracker.bundleID, name: tracker.name)
        Log.info("排除名单 \(nowExcluded ? "加入" : "移除")：\(tracker.displayName ?? "未知")")
    }

    @objc private func openSettings() {
        if settingsWindowController == nil, let env {
            settingsWindowController = SettingsWindowController(
                store: env.settings,
                monitorMode: env.monitorMode,
                onMonitorModeChange: { [weak self] mode in self?.applyMonitorMode(mode) })
        }
        // 命中精度是只读说明，文案由这边提供（只有这里知道 WindowProbe 的实时模式）
        settingsWindowController?.updateHitTestMode(hitTestModeText())
        settingsWindowController?.show()
    }

    /// 菜单动作：重新打开欢迎引导。
    /// ⚠️ 必须是**无参**的 @objc 方法 —— 菜单的 target/action 会把 NSMenuItem 当参数传进来，
    /// 如果这里带一个 Bool 参数，AppKit 传进来的会是 NSMenuItem，运行时直接类型不匹配崩掉。
    @objc private func reopenFirstRunGuide() {
        showFirstRunGuide(autoTriggered: false)
    }

    /// 首次启动引导。`autoTriggered` 只用于日志区分「自动弹」和「用户从菜单打开」。
    private func showFirstRunGuide(autoTriggered: Bool) {
        if firstRunWindowController == nil {
            firstRunWindowController = FirstRunWindowController(
                hotkeyAvailable: !hotkeyRegistrationFailed)
        }
        Log.info(autoTriggered ? "首次启动：显示欢迎引导" : "用户从菜单重新打开欢迎引导")
        firstRunWindowController?.show()
    }

    @objc private func requestAccessibilityPermission() {
        // 契约验收标准第 4 条：一键调 requestAccessibility(prompt: true) 和 openAccessibilitySettings()
        let already = Permissions.requestAccessibility(prompt: true)
        Log.info("已请求辅助功能权限（当前 trusted=\(already)）")
        // 系统弹窗刚出现时立刻抢焦点切系统设置会很突兀，稍等一下再打开面板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Permissions.openAccessibilitySettings()
        }
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    /// 「输入监控」面板。辅助功能给了但 tap 收不到事件时，用户要来这里再勾一次。
    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        let current = loginStatus(forceRefresh: true)
        let target = !current.isOn
        let result = LaunchAtLogin.setEnabled(target)
        cachedLoginStatus = result
        cachedLoginStatusAt = Date()

        // 不许静默失败：结果必须弹给用户看，说清用的是哪种方式
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if result.didFail {
                self.presentAlert(title: target ? "开机自启启用失败" : "关闭开机自启失败",
                                  message: result.error ?? result.detail, style: .critical)
            } else if result.needsApproval {
                self.presentAlert(title: "还需要你在系统设置里批准",
                                  message: result.detail, style: .warning)
            } else if target {
                self.presentAlert(title: "开机自启已启用",
                                  message: "当前方式：\(result.mechanism.displayName)\n\(result.detail)")
            } else {
                self.presentAlert(title: "开机自启已关闭", message: result.detail)
            }
        }
    }

    @objc private func refreshLoginStatus() {
        _ = loginStatus(forceRefresh: true)
        Log.info("已重新检测开机自启状态")
    }

    @objc private func copyDiagnostics() {
        guard let env else { return }
        let report = DiagnosticsLog.shared.fullReport(
            stats: env.driver.engineStats,
            settings: env.settings.settings,
            axTrusted: axTrusted,
            driverRunning: env.driver.isRunning,
            driverError: driverError,
            monitor: env.monitor,
            extra: diagnosticsExtras())

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        Log.info("诊断信息已复制到剪贴板（\(report.count) 字符）")
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - FocusDriverDelegate

    func focusDriver(_ driver: FocusDriver, didDecide decision: FocusDecision, outcome: FocusOutcome?) {
        DiagnosticsLog.shared.record(decision: decision, outcome: outcome)
    }

    func focusDriver(_ driver: FocusDriver, didSurfaceWarning message: String) {
        DiagnosticsLog.shared.recordWarning(message)
    }
}
