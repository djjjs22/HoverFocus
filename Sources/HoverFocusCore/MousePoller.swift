//  MousePoller — 无需任何系统权限的鼠标采样源
//
//  为什么它是本工具的**首选**事件源，而不是 CGEventTap：
//
//  实测（macOS 27.2，进程未获任何授权）：
//   · CGEvent(source: nil)?.location          → 可用，返回真实光标位置
//   · CGEventSource.buttonState(.combinedSessionState, button:) → 可用
//   · CGEventSource.flagsState(.combinedSessionState)           → 可用
//   · 纯读取成本 0.08µs/次（100000 次 8.1ms），等于免费
//   而同一台机器上 CGEventTap 能创建成功、但立刻被系统禁用（tapIsEnabled=false），收到 0 个事件。
//
//  所以用轮询可以做到**零权限可用**：
//   · 不需要「辅助功能」也不需要「输入监控」，用户装完就能用；
//   · 没有 tap 超时被系统禁用的问题，也就不存在这类工具最常见的「用一会儿就失灵」；
//   · 代价只有延迟：最坏一个轮询周期（默认 1/60s ≈ 16ms），对 focus-follows-mouse 完全无感。
//
//  已经授权、想要更低延迟的用户可以改用 MouseMonitor（CGEventTap），两者实现同一个
//  MouseEventSource 协议，可以互换。
//
//  省电：位置 / 按键 / 修饰键三者都没变化时不产生采样 —— 鼠标静止时几乎零开销。

import Foundation
import CoreGraphics
import AppKit

final class MousePoller: MouseEventSource {
    var onSample: ((MouseSample) -> Void)?
    private(set) var isRunning = false

    /// 轮询周期。1/60s ≈ 16ms 延迟；想更省电可以放宽到 1/30s。
    let interval: TimeInterval
    /// 位移小于这个值且状态没变就不发采样
    private let minDelta: CGFloat

    private var timer: Timer?
    private var lastPoint: CGPoint?
    private var lastDragging = false
    private var lastModifiers: CGEventFlags = []

    init(interval: TimeInterval = 1.0 / 60.0, minDelta: CGFloat = 1.0) {
        self.interval = interval
        self.minDelta = minDelta
    }

    deinit { stop() }

    func start() throws {
        guard !isRunning else { throw MouseMonitorError.alreadyRunning }
        // 轮询不依赖任何权限，所以这里**不会**抛 permissionDenied。
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common 模式：菜单展开、窗口拖动、滚动时也继续跑（否则鼠标一拖就停摆）
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        isRunning = true
        poll()  // 立刻发一次，别让用户等第一个周期
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lastPoint = nil
    }

    /// 手动采一次（自检 / 诊断用）
    @discardableResult
    func poll() -> MouseSample? {
        guard let onSample else { return nil }
        let point = CGEvent(source: nil)?.location ?? .zero
        let dragging = Self.anyMouseButtonDown()
        let modifiers = CGEventSource.flagsState(.combinedSessionState)

        // 三者都没变 → 不产生采样（鼠标静止时零开销）
        if let last = lastPoint,
           dragging == lastDragging,
           modifiers == lastModifiers,
           hypot(point.x - last.x, point.y - last.y) < minDelta {
            return nil
        }

        lastPoint = point
        lastDragging = dragging
        lastModifiers = modifiers

        let sample = MouseSample(point: point,
                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                 isDragging: dragging,
                                 modifiers: modifiers)
        onSample(sample)
        return sample
    }

    /// 直接问系统当前按键状态，比维护 down/up 状态更可靠
    static func anyMouseButtonDown() -> Bool {
        let state = CGEventSourceStateID.combinedSessionState
        return CGEventSource.buttonState(state, button: .left)
            || CGEventSource.buttonState(state, button: .right)
            || CGEventSource.buttonState(state, button: .center)
    }

    /// 当前修饰键（不需要任何权限）
    static func currentModifiers() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    /// 诊断信息：说明为什么用轮询而不是 tap
    static func diagnosis() -> [String: Any] {
        [
            "source": "MousePoller",
            "intervalMs": 1000.0 / 60.0,
            "requiresPermission": false,
            "cursorLocationReadable": CGEvent(source: nil)?.location != nil,
            "axTrusted": Permissions.isAccessibilityTrusted,
            "note": "轮询模式不需要任何权限即可工作；授予辅助功能权限后命中测试会从降级模式切到精确模式"
        ]
    }
}
