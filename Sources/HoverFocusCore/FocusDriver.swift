//  FocusDriver — 把 MouseEventSource / FocusEngine / 定时器接起来（core-engine 所有）
//
//  数据流（见 Contracts.swift 顶部）：
//      monitor.onSample ──▶ engine.handle ──▶ .act 时 engine.perform ──▶ actuator
//      tick Timer (1/30s) ──▶ engine.tick ──▶ 同上
//      每次判定 ──▶ delegate.didDecide
//
//  为什么需要 tick Timer：鼠标静止时不会再产生 sample，而 dwell 是「停留在同一窗口上的时长」，
//  所以必须由定时器推进 engine.tick()，否则用户把鼠标停在窗口上不动永远不会触发。
//
//  stop() 的干净性（硬性要求）：
//   · invalidate tick Timer；
//   · monitor.onSample = nil（停掉之后即使底层 tap 还有残留回调也不再进 engine）；
//   · monitor.stop()；
//   · isStarted = false，consume/tickOnce 双保险拒绝回调 delegate。
//
//  非契约测试接缝（init 签名没改，只是多了两个属性，verifier 用它测接线）：
//   · permissionCheck：默认查系统辅助功能授权，测试可替换为 { true } 走通接线；
//   · isTicking：tick Timer 是否有效，用来断言 stop() 真的停掉了定时器。

import Foundation
import CoreGraphics

protocol FocusDriverDelegate: AnyObject {
    /// 每次判定后回调，用于日志 / 诊断面板
    func focusDriver(_ driver: FocusDriver, didDecide decision: FocusDecision, outcome: FocusOutcome?)
    /// 需要用户关注的问题（例如「不置顶模式实际降级成了置顶」）
    func focusDriver(_ driver: FocusDriver, didSurfaceWarning message: String)
}

final class FocusDriver {
    init(settings: SettingsStore,
         probe: WindowProbing,
         actuator: FocusActing,
         monitor: MouseEventSource,
         clock: @escaping MonotonicClock = { ProcessInfo.processInfo.systemUptime },
         tickInterval: TimeInterval = 1.0 / 30.0) {
        self.settings = settings
        self.probe = probe
        self.actuator = actuator
        self.monitor = monitor
        self.clock = clock
        self.tickInterval = tickInterval
        self.engine = FocusEngine(settings: settings, probe: probe, actuator: actuator, clock: clock)
    }

    let settings: SettingsStore
    let probe: WindowProbing
    let actuator: FocusActing
    let monitor: MouseEventSource
    let clock: MonotonicClock
    let tickInterval: TimeInterval
    let engine: FocusEngine

    weak var delegate: FocusDriverDelegate?

    /// 权限检查接缝。默认查系统辅助功能授权；测试可替换成 { true }。
    var permissionCheck: () -> Bool = { Permissions.isAccessibilityTrusted }

    private var tickTimer: Timer?
    private var isStarted = false
    /// 是否已经接上 FocusController 的延迟补测（接上了就以补测结论告警，避免滞后假阴性/重复告警）。
    private var hasRaiseResolutionWiring = false

    /// tick Timer 是否有效（非契约，供测试断言 stop() 没泄漏定时器）。
    var isTicking: Bool { tickTimer?.isValid ?? false }

    /// 启动鼠标监听 + dwell 定时器。事件源需要授权且权限不足时抛 MouseMonitorError。
    func start() throws {
        guard !isStarted, !monitor.isRunning else { throw MouseMonitorError.alreadyRunning }

        // 只在事件源**自己声明需要授权**时才查权限（该属性已是真正的 protocol requirement，
        // 走动态派发：MouseMonitor=true，MousePoller / 假实现=false）。
        // 零权限的 MousePoller 绝不能被这道门槛挡死 —— app-shell 已经把它当默认事件源，
        // 无条件查 AXIsProcessTrusted 会让 App 一启动就抛「缺少辅助功能权限」。
        // （MouseMonitor.start() 内部还会再查一次 tapIsEnabled，所以即使这里漏判也不会静默失灵。）
        if monitor.requiresAccessibilityPermission {
            guard permissionCheck() else { throw MouseMonitorError.permissionDenied }
        }

        // 先挂回调再 start，避免启动瞬间的采样被丢掉。
        monitor.onSample = { [weak self] sample in
            self?.consume(sample)
        }
        do {
            try monitor.start()
        } catch {
            // 启动失败就把回调摘干净，别留一个半启动状态。
            monitor.onSample = nil
            throw error
        }
        isStarted = true
        wireRaiseResolution()
        startTicking()
    }

    func stop() {
        isStarted = false
        stopTicking()
        monitor.onSample = nil
        monitor.stop()
        // 摘掉延迟补测回调：停掉之后不该再有任何告警。
        if let controller = actuator as? FocusController { controller.onRaiseResolved = nil }
        hasRaiseResolutionWiring = false
    }

    var isRunning: Bool { monitor.isRunning }

    var engineStats: EngineStats { engine.stats }

    // MARK: - 接线

    /// 接上 FocusController 的**延迟补测**。
    ///
    /// 为什么要它：窗口服务器把「置顶」反映到 z 序上要 ~150ms（Lead 实测 4/4 轮），
    /// 而动作路径上不能 sleep（会卡住 CGEventTap 的鼠标事件投递 33ms）。所以动作返回时
    /// 拿到的 didRaise 是**临时值**（对会置顶的策略来说通常是滞后的 false），
    /// 真实结论由 +0.18s 的补测回调给出 —— 这里把它接到告警上。
    private func wireRaiseResolution() {
        guard let controller = actuator as? FocusController else {
            hasRaiseResolutionWiring = false
            return
        }
        controller.onRaiseResolved = { [weak self] resolution in
            self?.handleRaiseResolution(resolution)
        }
        hasRaiseResolutionWiring = true
    }

    private func handleRaiseResolution(_ resolution: FocusController.RaiseResolution) {
        guard isStarted else { return }
        // 只对「本来要求不置顶、结果被置顶」这一种情况告警 —— 这正是用户最在意的验收项。
        if !resolution.expectsRaise && resolution.didRaise {
            delegate?.focusDriver(self, didSurfaceWarning:
                "「只切焦点不置顶」未能保持窗口叠放顺序：延迟补测确认该窗口被置顶了"
                + "（策略：\(resolution.strategy.displayName)，窗口 id=\(resolution.windowID)）")
        }
    }

    private func consume(_ sample: MouseSample) {
        guard isStarted else { return }
        process(engine.handle(sample))
    }

    private func tickOnce() {
        // 双保险：即使 Timer 的 invalidate 和某次已经排队的回调擦肩而过，
        // stop() 之后也绝不进 engine、绝不回调 delegate。
        guard isStarted else { return }
        process(engine.tick())
    }

    private func startTicking() {
        stopTicking()
        let interval = max(tickInterval, 1.0 / 120.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickOnce()
        }
        timer.tolerance = interval * 0.25
        // .common 模式：菜单打开 / 拖拽跟踪期间定时器也要继续跑。
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func process(_ decision: FocusDecision) {
        switch decision {
        case .act(let action):
            let outcome = engine.perform(action)
            delegate?.focusDriver(self, didDecide: decision, outcome: outcome)
            surfaceWarnings(for: action, outcome: outcome)
        case .ignore, .pending:
            delegate?.focusDriver(self, didDecide: decision, outcome: nil)
        }
    }

    /// 把「用户需要知道」的坏消息抛给上层，不静默吞掉。
    private func surfaceWarnings(for action: FocusAction, outcome: FocusOutcome) {
        if let error = outcome.error {
            delegate?.focusDriver(self, didSurfaceWarning:
                "聚焦失败：\(error)（策略：\(outcome.strategy.displayName)，目标 pid=\(action.pid)）")
        }
        if !action.raise {
            if outcome.strategy != .skyLightNoRaise {
                delegate?.focusDriver(self, didSurfaceWarning:
                    "「只切焦点不置顶」已降级为「\(outcome.strategy.displayName)」"
                    + (SkyLightBridge.isAvailable
                       ? "（私有 SkyLight 调用失败）"
                       : "（私有 SkyLight 符号不可用）"))
            }
            // 接上了延迟补测就以补测结论为准（见 handleRaiseResolution）：
            // 动作路径读到的 didRaise 是滞后的临时值，用它告警既可能假阴性、又可能和补测重复。
            if !hasRaiseResolutionWiring && outcome.didRaise {
                delegate?.focusDriver(self, didSurfaceWarning:
                    "「只切焦点不置顶」未能保持窗口叠放顺序：该窗口实际被置顶了"
                    + "（策略：\(outcome.strategy.displayName)，窗口 id=\(action.windowID)）")
            }
        }
    }
}
