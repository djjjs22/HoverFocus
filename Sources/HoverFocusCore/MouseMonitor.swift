//  MouseMonitor — 鼠标事件源
//
//  为什么用 CGEventTap 而不是 NSEvent.addGlobalMonitorForEvents（AutoFocus 用的是后者）：
//  1. tap 能直接拿到 CGEvent 的原始坐标与 flags，不用过 NSEvent 转换层；
//  2. tap 能在同一个回调里看到 down/up/drag/flagsChanged，拖拽与修饰键守卫判定更准；
//  3. tap 被系统禁用（超时/用户输入）时有明确事件，可以重新 enable —— 这类工具
//     「用一会儿就失灵」的根因几乎都是没处理 tapDisabledByTimeout。
//
//  线程：tap 的 source 挂在主 RunLoop 上，所以回调本来就在主线程，不需要再 dispatch。
//
//  节流策略：
//  - 位移类事件（moved/dragged）按 minEmitInterval 限流（≈60Hz），
//    并用**尾沿补发**保证鼠标停下来的最终位置一定被送达一次
//    （否则「快速划过再停住」的最后一帧可能被丢掉，焦点判定就会停在旧窗口上）。
//  - 状态类事件（down/up/flagsChanged）不限流，立即送达 —— 它们稀疏且决定守卫是否生效。

import Foundation
import CoreGraphics
import AppKit

final class MouseMonitor: MouseEventSource {
    var onSample: ((MouseSample) -> Void)?
    private(set) var isRunning = false

    /// CGEventTap 需要授权（未授权时系统会立刻禁用 tap，收到 0 个事件）。
    /// 所以 FocusDriver 只对这个源做权限门槛检查。
    let requiresAccessibilityPermission = true

    /// 被系统因超时/用户输入禁用过多少次。> 0 说明回调太慢或用户强制禁用了 tap，UI 应当告警。
    private(set) var tapDisableCount = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastEmitAt: TimeInterval = 0
    private var pendingSample: MouseSample?
    private var pendingFlushScheduled = false

    /// moved/dragged 的最小间隔，约 60Hz。对 focus-follows-mouse 足够，且能把 CPU 压住。
    private let minEmitInterval: TimeInterval = 1.0 / 60.0
    /// tap 回调超过这个耗时就算异常（它跑在会话事件流最前端，会拖慢全系统鼠标）
    private static let slowCallbackThreshold: TimeInterval = 0.002
    /// 累计慢回调次数（诊断用）
    private(set) var slowCallbackCount = 0

    init() {}

    deinit { stop() }

    // MARK: - 生命周期

    func start() throws {
        guard !isRunning else { throw MouseMonitorError.alreadyRunning }

        // 注意：即使没有辅助功能权限，CGEvent.tapCreate 也可能返回非 nil 的 tap
        // （实测如此），但事件永远不来。所以必须显式前置检查，否则会「静默不工作」。
        guard Permissions.isAccessibilityTrusted else { throw MouseMonitorError.permissionDenied }

        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw MouseMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        // 实测（macOS 27.2，未授权）：tapCreate 会成功返回一个 tap，但系统**立刻把它禁用**，
        // tapIsEnabled 为 false，且之后一个事件都收不到（连合成投递也收不到）。
        // 如果不检查这一步，工具就会「看起来在运行但什么都不做」—— 正是 AutoFocus 那类
        // 静默失灵。这里直接失败，把原因交给 UI 显示。
        guard CGEvent.tapIsEnabled(tap: newTap) else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(newTap)
            throw MouseMonitorError.permissionDenied
        }

        self.tap = newTap
        self.runLoopSource = source
        self.isRunning = true
    }

    /// tap 当前是否处于启用状态。未授权时实测为 false。
    var isTapEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        pendingSample = nil
        pendingFlushScheduled = false
        isRunning = false
    }

    // MARK: - 事件处理（主线程）

    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) {
        // tap 被系统禁用必须重新打开，否则之后再也收不到任何事件。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapDisableCount += 1
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            NSLog("[HoverFocus] CGEventTap 被禁用（type=\(type.rawValue)），已重新启用；累计 \(tapDisableCount) 次")
            return
        }

        // 看门狗：这个回调跑在会话事件流的最前端，**慢一点就是全系统鼠标卡顿**。
        // 曾经因为没有这个度量，一个「回调里同步跑 AX 命中测试」的问题藏了很久，
        // 表现出来是「自绘标题栏的窗口拖不动」—— 极难联想到事件 tap。
        let entered = ProcessInfo.processInfo.systemUptime
        defer {
            let cost = ProcessInfo.processInfo.systemUptime - entered
            if cost > Self.slowCallbackThreshold {
                slowCallbackCount += 1
                // 只偶尔打一行，避免刷屏把问题本身变成新的卡顿源
                if slowCallbackCount == 1 || slowCallbackCount % 100 == 0 {
                    NSLog("[HoverFocus] ⚠️ tap 回调耗时 \(String(format: "%.2f", cost * 1000))ms"
                          + "（阈值 \(String(format: "%.1f", Self.slowCallbackThreshold * 1000))ms）；"
                          + "累计 \(slowCallbackCount) 次 —— 会拖慢全系统鼠标事件")
                }
            }
        }

        let sample = MouseSample(
            point: event.location,
            timestamp: ProcessInfo.processInfo.systemUptime,
            isDragging: Self.isDragging(type: type),
            modifiers: event.flags
        )
        emit(sample, throttled: Self.isMovementEvent(type))
    }

    /// 限流发送；被丢掉时记成 pending，在窗口结束时补发，保证最终位置一定被送达。
    ///
    /// ⚠️ **这里绝对不能在 tap 回调里同步跑引擎。**
    ///
    /// tap 装在 `.cgSessionEventTap` 的 `.headInsertEventTap` 位置 —— 它是会话事件流的最前端，
    /// **回调不返回，事件就不会继续投递给目标 App**。而引擎会做 AX 命中测试
    /// （实测未命中缓存 p50 1ms / p90 5ms / max 96ms）。于是每一次命中测试都等于把
    /// 整个系统的鼠标事件流卡住那么久。
    ///
    /// 真实现象（2026-10-20 实测）：**自绘标题栏的 App 窗口拖不动**。
    /// 这类 App（Edge / 微信 / Electron 系）用的是 macOS 的 drag-trait 手势，
    /// 对 mousedown 与 drag 之间的时序很敏感；事件流被卡一下，手势就激活失败，
    /// WindowServer 报 `no client initiated window drag trait gesture to activate for mouse`，
    /// 表现就是「能拖边缘改大小，但拖不动窗口」，而且**轻按快拖必失败、用力按反而能成功**。
    ///
    /// 所以：所有投递一律走异步，回调本身只做「记一个样本 + 排一次投递」，
    /// 保证 O(1) 返回。代价是判定晚一个 runloop 跳（<1ms），相对 120ms 的 dwell 可忽略。
    private func emit(_ sample: MouseSample, throttled: Bool) {
        guard onSample != nil else { return }

        // 非移动事件（按下 / 松开 / 修饰键）也必须异步投递 —— 它们同样在事件流的关键路径上
        if !throttled {
            lastEmitAt = sample.timestamp
            pendingSample = sample
            schedulePendingFlush(after: 0)
            return
        }

        let elapsed = sample.timestamp - lastEmitAt
        if elapsed < minEmitInterval {
            pendingSample = sample
            schedulePendingFlush(after: minEmitInterval - elapsed)
            return
        }

        lastEmitAt = sample.timestamp
        pendingSample = sample
        schedulePendingFlush(after: 0)
    }

    /// 把 pending 样本异步投递出去。`delay <= 0` 时只做一次 runloop 跳（不额外等待）。
    private func schedulePendingFlush(after delay: TimeInterval) {
        guard !pendingFlushScheduled else { return }
        pendingFlushScheduled = true
        let fire = { [weak self] in
            guard let self else { return }
            self.pendingFlushScheduled = false
            guard let sample = self.pendingSample else { return }
            self.pendingSample = nil
            self.onSample?(sample)
        }
        if delay <= 0 {
            DispatchQueue.main.async(execute: fire)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
        }
    }

    private static func isMovementEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    /// 直接问系统当前按键状态。**只作为兜底**，不能作为拖拽判定的主依据 ——
    /// 实测（macOS 27.2）这个状态**滞后于事件流**，而且触控板手势拖拽根本没有物理按键。
    private static func anyMouseButtonDown() -> Bool {
        let state = CGEventSourceStateID.combinedSessionState
        return CGEventSource.buttonState(state, button: .left)
            || CGEventSource.buttonState(state, button: .right)
            || CGEventSource.buttonState(state, button: .center)
    }

    /// 判定「这一刻用户是不是正在拖拽」。
    ///
    /// ⚠️ 这里必须**优先用事件类型**，不能用按键状态。实测证据（合成一次普通按键拖拽，逐个事件读按键状态）：
    ///     leftMouseDown     → buttonState=false   ← 已经按下了，但状态还是 false
    ///     leftMouseDragged  → buttonState=false   ← 拖拽中的头两个事件依然是 false
    ///     leftMouseDragged  → buttonState=false
    ///     leftMouseDragged  → buttonState=true    ← 第 3 个事件才追上
    /// 也就是说：**每一次拖拽的开头都会有一小段「按键状态还没更新」的窗口**。
    /// 在那段窗口里，如果拿按键状态当拖拽依据，拖拽守卫就是失效的 —— 引擎会照常判定并执行聚焦
    /// （激活/置顶那个窗口），而**在拖拽会话中改变窗口叠放会让 macOS 取消整个拖拽**。
    /// 用户看到的现象就是「窗口拖不动了」。
    ///
    /// 更糟的是触控板：用「三指拖移 / 轻点拖移」拖窗口时**全程没有物理按键按下**，
    /// buttonState 自始至终是 false —— 守卫等于完全不存在。
    ///
    /// 所以：拖动类事件和按下类事件一律判为拖拽；松开类事件一律判为不拖拽；
    /// 只有 mouseMoved / flagsChanged 这种「不带按键语义」的事件才去问按键状态。
    private static func isDragging(type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return false
        default:
            return anyMouseButtonDown()
        }
    }
}

/// C 回调不能捕获上下文，所以 self 通过 userInfo 传进来。
private let mouseTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MouseMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleTapEvent(type: type, event: event)
    // listen-only tap 的返回值会被忽略，但必须非 nil。
    return Unmanaged.passUnretained(event)
}

// MARK: - 权限诊断

extension MouseMonitor {
    /// 给 UI 与 hf-probe 用：一次性说清「为什么收不到鼠标事件」。
    /// 本机实测（macOS 27.2）：
    ///   - AXIsProcessTrusted = false
    ///   - CGPreflightListenEventAccess = false（输入监控）
    ///   - CGPreflightPostEventAccess = false
    ///   - CGEventTap 能创建成功，但 tapIsEnabled 立刻是 false，收到 0 个事件
    /// 所以「tap 建好了」不等于「能收到事件」，必须看 tapEnabled。
    static func permissionDiagnosis() -> [String: Any] {
        [
            "accessibilityTrusted": Permissions.isAccessibilityTrusted,
            "listenEventAccess": CGPreflightListenEventAccess(),
            "postEventAccess": CGPreflightPostEventAccess(),
            "hint": Permissions.isAccessibilityTrusted
                ? "辅助功能已授权"
                : "需要在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 HoverFocus；"
                + "若勾选后仍收不到鼠标事件，再去「输入监控」里勾选一次"
        ]
    }
}
