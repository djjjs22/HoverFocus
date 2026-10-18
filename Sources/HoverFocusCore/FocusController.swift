//  FocusController — FocusActing 的真实实现
//
//  职责：把 WindowRef 变成「前台 + 键盘焦点」，并**实测**这次操作到底有没有改变
//  窗口叠放顺序（FocusOutcome.didRaise）。这个字段是给用户的诚实交代：
//  focusOnly 模式下如果实际把窗口顶上去了，FocusDriver 会据此抛 warning。
//
//  两条路径：
//   · raise = true  → NSRunningApplication.activate(...)（公开 API，一定会置顶）
//   · raise = false → 优先私有 SkyLight `_SLPSSetFrontProcessWithOptions(psn, wid, 0x200)`，
//                     通过 dlopen/dlsym 动态加载；符号缺失或调用返回非 0 时 fail-soft
//                     降级到 AX kAXFrontmost → NSRunningApplication.activate()。
//                     降级路径会置顶窗口，此时 didRaise 会如实报 true。
//
//  ⚠️ 动作路径**绝对不允许阻塞**（这条是拿真机实测换来的）：
//     perform 跑在 CGEventTap 的回调链上（低延迟模式下），在这里 sleep 会卡住**全系统**的
//     鼠标事件投递。历史版本用 `settle()` 睡 4×5ms=20ms 等 z 序落定，实测主线程中位 33ms、
//     最多 6.7 次动作/秒 ≈ 22% 主线程占用；而且**等也等不到** —— 窗口服务器把「置顶」
//     反映到 z 序上要 ~150ms（实测 4/4 轮：立刻读=旧值，150ms 后=新值），
//     20ms 的观测窗口比效果延迟还短，导致 raise 路径的 didRaise 恒为 false（假阴性）。
//     现在的做法：动作路径只读一次 z（≈0.22ms）当**临时值**，真正的结论交给
//     +0.18s 的**非阻塞延迟补测**（scheduleRaiseResolution → onRaiseResolved）。
//
//  didRaise 是**测出来的**，不是猜的：
//     zOrderIndex 是「CGWindowList 前到后」的下标，0 = 最前，所以 after < before 才算置顶。
//     动作路径上前后各读一次；任一次拿不到（窗口不在当前 Space / CGWindowList 查不到）→
//     无法证明「没置顶」，保守报 didRaise = true，让上层给用户提示，绝不假装成功。
//     延迟补测只在「前后两次都读到了」时才出结论（读不到就是窗口没了，不能当成置顶）。
//
//  已知限制（未实测，本机没有辅助功能权限，AX 调用一律 -25211）：
//   · 私有 SkyLight 只能把「进程」切成前台，不保证把键盘焦点落到指定窗口；
//     要真正把 key window 换过去还需要 _SLPSPostEventRecordTo 那一套伪造事件记录，
//     本机该符号不存在（实测 MISSING），且乱发二进制事件记录有搞崩目标 App 的风险，
//     所以这里只按契约实现 _SLPSSetFrontProcessWithOptions，didActivate 如实反映结果。
//   · didActivate 依赖 NSWorkspace（需要主 RunLoop 刷新）+ WindowProbe.focusedWindow() 的
//     50ms 缓存，可能滞后（只会假阴性）→ 因此它**只做诊断字段，不驱动 error / 告警**。

import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Carbon
import Darwin

/// SkyLight 私有框架的弱链接封装。任何一步失败都返回 nil，绝不崩。
enum SkyLightBridge {
    /// `OSStatus _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode)`
    /// 用 Carbon 的 ProcessSerialNumber（C 结构体，可以直接放进 @convention(c) 签名，
    /// 布局风险归零）。实测：GetProcessForPID(getpid()) 返回 0，psn 正常。
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    /// `OSErr GetProcessForPID(pid_t pid, ProcessSerialNumber *psn)`
    /// 注意：Swift 把 GetProcessForPID 标成 unavailable（10.9 起 deprecated），只能 dlsym。
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// kCPSUserGenerated：用户触发的切前台。实测 0x200 / 0x100 / 0x0 都能「切前台不置顶」，
    /// 0x200 是 yabai 用的值，作为默认。
    static let userGeneratedMode: UInt32 = 0x200

    private static let skyLightHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)

    static let setFrontProcess: SetFrontProcessFn? = {
        guard let handle = skyLightHandle,
              let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(symbol, to: SetFrontProcessFn.self)
    }()

    /// GetProcessForPID 住在 CarbonCore 里。**必须逐个候选路径 dlsym 验证符号**：
    /// 只看 dlopen 成功就返回 handle 的话，哪天系统把符号挪走，就会静默变成
    /// processForPID == nil → isAvailable == false → 默认的「不置顶」悄悄退化成置顶。
    static let processForPID: GetProcessForPIDFn? = {
        let candidates = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/Carbon.framework/Carbon"
        ]
        for path in candidates {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
                  let symbol = dlsym(handle, "GetProcessForPID") else { continue }
            return unsafeBitCast(symbol, to: GetProcessForPIDFn.self)
        }
        return nil
    }()

    /// 私有不置顶路径是否可用（诊断面板可以显示这个）。
    static var isAvailable: Bool { setFrontProcess != nil && processForPID != nil }
}

final class FocusController: FocusActing {
    init(probe: WindowProbing) {
        self.probe = probe
    }

    let probe: WindowProbing

    // MARK: - 延迟补测（非阻塞，用来给出**真实**的 didRaise）

    /// 延迟补测结果。动作路径返回的 didRaise 是「立刻读到什么」的临时值；
    /// 这个回调给出 +0.18s 后的真实值。
    struct RaiseResolution {
        var windowID: CGWindowID
        var strategy: FocusStrategy
        /// 本次动作是否**期望**置顶（raise=true，或降级到了会置顶的策略）。
        /// 若为 false 却 didRaise=true → focusOnly 模式实际把窗口顶上去了，必须告警。
        var expectsRaise: Bool
        /// 延迟补测实测到的 didRaise（只在前后两次 z 序都读到时才会回调）
        var didRaise: Bool
    }

    /// 延迟补测回调（主线程）。FocusDriver 在 start() 里接上，用于抛「不置顶模式实际置顶」告警。
    var onRaiseResolved: ((RaiseResolution) -> Void)?

    /// 补测延迟：实测 activate() 返回后 ~150ms 才能在 z 序上看到置顶，留余量取 0.18s。
    static let raiseResolutionDelay: TimeInterval = 0.18

    // MARK: - FocusActing

    func focus(window: WindowRef, raise: Bool) -> FocusOutcome {
        // 动作路径只读、不 sleep。zOrderIndex ≈0.22ms（实测，内部会强制刷新窗口列表）。
        let zBefore = probe.zOrderIndex(of: window.windowID)

        if raise {
            let requested = activatePublicly(pid: window.pid)
            return finish(window: window, strategy: .publicActivate, expectsRaise: true,
                          zBefore: zBefore,
                          error: requested ? nil : "NSRunningApplication.activate 未受理（pid=\(window.pid)）")
        }

        // ── raise == false：优先私有 SkyLight（只切前台、不置顶）────────────
        if SkyLightBridge.isAvailable, let slErr = setFrontViaSkyLight(window: window), slErr == 0 {
            // 调用成功但焦点没转移时**不降级**：用户明确选了「不置顶」，
            // 宁可如实报 didActivate=false，也不偷偷把窗口顶上去。
            return finish(window: window, strategy: .skyLightNoRaise, expectsRaise: false,
                          zBefore: zBefore, error: nil)
        }
        // 符号缺失 / PSN 取不到 / 调用返回非 0 → 落到下面的降级路径

        // ── 降级 1：AX kAXFrontmost（会置顶）────────────────────────────────
        if activateViaAX(pid: window.pid), isAppActive(pid: window.pid) {
            return finish(window: window, strategy: .axFrontmost, expectsRaise: true,
                          zBefore: zBefore, error: nil)
        }

        // ── 降级 2：NSRunningApplication.activate（一定置顶）────────────────
        let requested = activatePublicly(pid: window.pid)
        return finish(window: window, strategy: .publicActivate, expectsRaise: true,
                      zBefore: zBefore,
                      error: requested ? nil : "NSRunningApplication.activate 未受理（pid=\(window.pid)）")
    }

    // MARK: - 收尾（一次 z 读 + 一次延迟补测）

    /// 统一收尾：读一次 z 当临时值、排一次延迟补测、算 didActivate。
    ///
    /// `error` 只表达**调用层面**的失败（API 未受理 / 符号缺失）。didActivate 受测量滞后影响
    /// 可能是假阴性，所以绝不用它当 error 依据，否则会给用户报假警。
    private func finish(window: WindowRef,
                        strategy: FocusStrategy,
                        expectsRaise: Bool,
                        zBefore: Int?,
                        error: String?) -> FocusOutcome {
        let zNow = probe.zOrderIndex(of: window.windowID)
        scheduleRaiseResolution(windowID: window.windowID, strategy: strategy,
                                expectsRaise: expectsRaise, zBefore: zBefore)

        var activated = isAppActive(pid: window.pid)
        // z 序 0 = 最前 → 它的窗口在最前，那它一定是前台 App（这条判据同步、可靠）。
        if !activated, let index = zNow, index == 0 { activated = true }

        return FocusOutcome(window: window,
                            strategy: strategy,
                            didRaise: didRaise(zBefore: zBefore, zAfter: zNow),
                            didActivate: activated,
                            error: error)
    }

    private func scheduleRaiseResolution(windowID: CGWindowID,
                                         strategy: FocusStrategy,
                                         expectsRaise: Bool,
                                         zBefore: Int?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.raiseResolutionDelay) { [weak self] in
            guard let self else { return }
            // 只在「动作前后两次 z 序都读到了」时才下结论：读不到通常是窗口已经没了，
            // 那种情况不能当成「被置顶了」（否则会给用户报假警）。
            guard let before = zBefore,
                  let after = self.probe.zOrderIndex(of: windowID) else { return }
            self.onRaiseResolved?(RaiseResolution(windowID: windowID,
                                                  strategy: strategy,
                                                  expectsRaise: expectsRaise,
                                                  didRaise: after < before))
        }
    }

    // MARK: - 各条激活路径

    private func activatePublicly(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if #available(macOS 14.0, *) {
            // macOS 14+ 的正式 API。from: 传「发起激活的 App」= 我们自己。
            if app.activate(from: NSRunningApplication.current, options: []) { return true }
        }
        // 兜底：macOS 13 只有这个 API。14+ 上 ignoringOtherApps 这个选项已无效果
        // （所以有一处 deprecation 警告，是刻意的：比「激活不了」好）。
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    private func activateViaAX(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        // 必须设超时：AXUIElementSetAttributeValue 是同步 Mach IPC，目标 App 无响应
        // （转菊花 / Electron 卡住）时会按 AX 默认超时阻塞主线程好几秒。这条路径就在
        // CGEventTap 的回调链上，阻塞太久会被系统把 tap 判成超时禁用（表现为「用一会儿就失灵」）。
        // 0.25 与 WindowProbe 的 axTimeout 保持一致。
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let result = AXUIElementSetAttributeValue(appElement,
                                                 kAXFrontmostAttribute as CFString,
                                                 kCFBooleanTrue)
        return result == .success
    }

    /// 私有 SkyLight 切前台。返回 nil 表示「符号/PSN 不可用」，返回非 0 表示调用失败。
    private func setFrontViaSkyLight(window: WindowRef) -> Int32? {
        guard let setFront = SkyLightBridge.setFrontProcess,
              let getPSN = SkyLightBridge.processForPID else { return nil }
        var psn = ProcessSerialNumber()
        guard getPSN(window.pid, &psn) == 0 else { return nil }
        return setFront(&psn, UInt32(window.windowID), SkyLightBridge.userGeneratedMode)
    }

    // MARK: - 实测小工具

    /// 目标 App 是否真的成了前台。三个来源，任一成立即算（都不会误报 true）：
    ///   1. NSWorkspace.frontmostApplication —— 直接、权威，但需要主 RunLoop 刷新（可能滞后）；
    ///   2. probe.focusedWindow() —— AX 焦点窗口 / 降级模式下的前台 App 顶窗（50ms 缓存）；
    ///   3. NSRunningApplication.isActive —— LaunchServices 的快照。
    /// 三者都可能滞后 → 只可能假阴性，不会假阳性；因此不做告警依据。
    private func isAppActive(pid: pid_t) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        if let focused = probe.focusedWindow(), focused.pid == pid { return true }
        return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
    }

    /// 只信实测：after < before 才算置顶（zOrderIndex 越小越靠前）。
    /// 任一次读不到 → 无法证明「没置顶」→ 保守报 true，让上层提示用户。
    private func didRaise(zBefore: Int?, zAfter: Int?) -> Bool {
        guard let before = zBefore, let after = zAfter else { return true }
        return after < before
    }
}
