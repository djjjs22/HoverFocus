//  FocusEngine — 判定核心（core-engine 所有）
//
//  纯逻辑：handle() / tick() 只读注入的 probe 与 clock()，零副作用
//  （不写 UserDefaults、不调 actuator、不碰 UI）。唯一有副作用的方法是 perform()。
//
//  判定顺序严格照 Contracts.swift 顶部的 1–16 步（verifier 按这个顺序写测试）：
//     1 !enabled → 2 dragging → 3 modifiers → 4 menuBar → 5 noWindow
//     6 nonNormalWindow / notOnScreen → 7 ownApp → 8 systemUI → 9 appHidden
//    10 excludedApp → 11 fullScreenBlocked → 12 sameWindow → 13 cooldown
//    14 计时重置 → 15 dwell 未到 → 16 act
//
//  实现要点（与 verifier 约定的测试契约，改动必须同步通知）：
//   · 时间源一律取注入的 clock()。MouseSample.timestamp 只做诊断，不参与判定，
//     否则「fake clock 推进 + 采样时间戳不变」的测试会得到错误结果。
//   · 第 12 步 sameWindow 在第 14 步 dwell 之前 —— 鼠标在已聚焦窗口上晃不会反复触发动作，
//     这是 AutoFocus「手一抖焦点就跑了」的主因。
//   · 第 1–5 步的任何 return 都**清掉** dwell 计时（第 6–13 步确认窗口身份、且它正是正在计时的
//     窗口时才保留）。只有「连续停留在同一窗口上 ≥ dwell」才允许动作 —— 光标跑去菜单栏/桌面、
//     换到别的窗口、被拖拽或修饰键打断，统统重新计时。不清的话多次短停留的时间会**累加**，
//     几个来回就凑够 dwell 触发误抢焦点（真机 harness 实测两种形态：窗口↔菜单栏来回；
//     以及按住 cmd / 拖拽的行程）—— 用户抱怨的「手一抖焦点就跑了」正是这两类。
//   · perform() 之后清空 pending：一次动作后必须重新攒满一个 dwell 才会再动，
//     避免「聚焦没生效 → 每 150ms 重试一次」把 AX/SkyLight 打爆。
//   · handle()/tick() 自己不发起任何 AX 请求，只调用 WindowProbing 的方法
//     （命中测试 3pt/80ms 缓存、focusedWindow 50ms 缓存都由 WindowProbe 负责）。
//   · zOrderIndex 很贵，只在 perform() 路径里由 FocusController 调用，不在这里调。

import Foundation
import CoreGraphics

final class FocusEngine {
    init(settings: SettingsStore,
         probe: WindowProbing,
         actuator: FocusActing,
         clock: @escaping MonotonicClock) {
        self.settings = settings
        self.probe = probe
        self.actuator = actuator
        self.clock = clock
    }

    let settings: SettingsStore
    let probe: WindowProbing
    let actuator: FocusActing
    let clock: MonotonicClock

    private(set) var stats = EngineStats()
    private(set) var lastDecision: FocusDecision?
    private(set) var lastOutcome: FocusOutcome?

    /// 正在 dwell 计时的目标窗口
    private(set) var pendingWindowID: CGWindowID?
    private(set) var pendingSince: TimeInterval?
    private var lastActionAt: TimeInterval?

    /// 最近一次采样。tick() 用它重新判定，让鼠标静止时 dwell 也能到点。
    private var lastSample: MouseSample?
    /// 最近一次判定为 .act 的窗口。perform() 优先用它，避免再打一次命中测试。
    private var lastTargetWindow: WindowRef?
    /// 重入保护：perform 会调 FocusController，后者在主线程做短暂等待；
    /// 万一上层（delegate 或 run loop）在动作执行期间又回调进来，直接拒绝而不是叠一次动作。
    private var isPerforming = false

    // MARK: - 判定

    /// 消费一个鼠标采样，只做判定，不动手。
    @discardableResult
    func handle(_ sample: MouseSample) -> FocusDecision {
        stats.samples += 1
        lastSample = sample
        return evaluate(sample: sample, now: clock())
    }

    /// 鼠标静止时由定时器驱动，让 dwell 能到点。
    @discardableResult
    func tick() -> FocusDecision {
        guard let sample = lastSample else {
            // 还没收到任何采样，无从判定。这里不增加 stats.samples（tick 不是采样）。
            record(.noWindow)
            return .ignore(.noWindow)
        }
        return evaluate(sample: sample, now: clock())
    }

    /// 1–16 步判定主体。只读 probe / settings / clock()。
    private func evaluate(sample: MouseSample, now: TimeInterval) -> FocusDecision {
        var s = settings.settings.sanitized()
        // Contracts.sanitized() 对 NaN 无能为力（min/max 遇 NaN 会原样放行），
        // 这里兜底换成默认值，免得 dwell/cooldown 判定被 NaN 直接穿透。
        if !s.dwellDelay.isFinite { s.dwellDelay = Settings.default.dwellDelay }
        if !s.cooldown.isFinite { s.cooldown = Settings.default.cooldown }
        let dwell = s.dwellDelay

        // ── 第 1–5 步：还没确认「指针仍停在正在计时的那个窗口上」，一律清掉 dwell 计时 ──
        // 统一规则：只有第 6–13 步确认了窗口身份、且它就是正在计时的窗口时，才保留计时。
        // 否则多次短停留的时间会**累加**，几个来回就凑够 dwell 误抢焦点 ——
        // 真机 harness 实测的两种形态：①窗口↔菜单栏/桌面来回；②按住 cmd 或拖拽的行程
        // （第 2/3 步先于第 4/5 步 return，曾绕过清理）。用户抱怨的「手一抖焦点就跑了」正是这两类。

        // 1. 总开关（关掉时清计时也合理：重新打开时从零开始）
        if !s.enabled {
            clearPending()
            return ignore(.disabled)
        }

        // 2. 拖拽中（拖窗口 / 拖选文字）
        if sample.isDragging && s.suppressWhileDragging {
            clearPending()
            return ignore(.dragging)
        }

        // 3. 按住修饰键（cmd/opt/ctrl/shift）
        if sample.hasIntentModifier && s.requireNoModifiers {
            clearPending()
            return ignore(.modifiersHeld)
        }

        // 3.5 前台 App 正在编辑单行输入框（Finder 重命名 / 表格单元格编辑）→ 绝不动焦点。
        //     这类编辑会话一旦失焦会被**直接取消**（用户白编辑）。这是 AutoFocus 的老 bug，
        //     用户明确要求我们不要重蹈。放在很前面：它保护的是「用户正在输入」这个状态，
        //     优先级高于一切「要不要切窗口」的判断。
        if probe.frontmostAppHasActiveTextEditor() {
            clearPending()
            return ignore(.textEditing)
        }

        // 4. 指针在菜单栏上
        if CoordinateSpace.isInMenuBarRegion(sample.point) {
            clearPending()
            return ignore(.inMenuBar)
        }

        // 5. 指针下没有窗口（桌面 / 空白）
        guard let window = probe.window(atQuartzPoint: sample.point) else {
            clearPending()
            return ignore(.noWindow)
        }

        // 6. 非普通窗口（layer != 0：浮层 / Dock / 提示条），以及不在当前 Space
        //    的窗口（WindowProbe 对「跨 Space」返回 isOnScreen=false）——「绝不跨 Space 乱跳」。
        if window.layer != 0 { return ignore(.nonNormalWindow, leaving: window) }
        if !window.isOnScreen { return ignore(.notOnScreen, leaving: window) }

        // 7. 是我们自己的窗口（设置窗口不该被自己抢焦点）
        if window.pid == probe.ownPID() { return ignore(.ownApp, leaving: window) }

        // 8. 系统 UI（Dock / 控制中心 / 通知中心 / WindowServer / Spotlight / 本工具）
        if probe.isSystemUI(pid: window.pid) { return ignore(.systemUI, leaving: window) }

        // 9. 目标 App 被 cmd-H 隐藏
        if probe.isAppHidden(pid: window.pid) { return ignore(.appHidden, leaving: window) }

        // 10. 排除名单（bundle id 为主键，appName 兜底）
        if isExcluded(window, in: s) { return ignore(.excludedApp, leaving: window) }

        // 11. 前台 App 全屏中，不抢焦点
        if s.respectFullScreen && probe.frontmostAppIsFullScreen() {
            return ignore(.fullScreenBlocked, leaving: window)
        }

        // 12. 已经是当前焦点窗口 —— 最重要的防抖，必须在 dwell 计时之前
        if let focused = probe.focusedWindow(), focused.windowID == window.windowID {
            return ignore(.sameWindow, leaving: window)
        }

        // 13. 距上次动作太近（cooldown 下限由 Contracts.sanitized() 钳到 0.06，
        //     用来盖过 WindowProbe.focusedWindow() 的 50ms 缓存）
        if let last = lastActionAt, now - last < s.cooldown {
            return ignore(.cooldown, leaving: window)
        }

        // 14. 目标窗口 != 正在计时的窗口 → 重置计时（dwell == 0 时会直接落到第 16 步）
        if pendingWindowID != window.windowID {
            pendingWindowID = window.windowID
            pendingSince = now
        }

        // 15. 停留时间还不够
        let since = pendingSince ?? now
        let elapsed = now - since
        if elapsed < dwell {
            let remaining = max(0, dwell - elapsed)
            let decision = FocusDecision.pending(windowID: window.windowID, remaining: remaining)
            record(decision: decision)
            return decision
        }

        // 16. 判定成立
        let action = FocusAction(windowID: window.windowID,
                                 pid: window.pid,
                                 raise: s.mode == .focusAndRaise)
        lastTargetWindow = window
        record(decision: .act(action))
        return .act(action)
    }

    /// 记录一次 ignore。若指针此刻停在**别的**窗口上，顺带清掉旧窗口的 dwell 计时。
    private func ignore(_ reason: FocusIgnoreReason, leaving window: WindowRef? = nil) -> FocusDecision {
        if let w = window, let pending = pendingWindowID, pending != w.windowID {
            clearPending()
        }
        record(reason)
        return .ignore(reason)
    }

    /// 清掉 dwell 计时：指针已经不在待计时的那个窗口上了。
    private func clearPending() {
        pendingWindowID = nil
        pendingSince = nil
    }

    private func isExcluded(_ window: WindowRef, in settings: Settings) -> Bool {
        if let bundleID = window.bundleID, settings.excludedBundleIDs.contains(bundleID) { return true }
        if let name = window.appName, settings.excludedAppNames.contains(name) { return true }
        return false
    }

    // MARK: - 执行

    /// 执行 act 决策。会更新 lastActionAt / stats。这是唯一有副作用的方法。
    @discardableResult
    func perform(_ action: FocusAction) -> FocusOutcome {
        guard !isPerforming else {
            let outcome = FocusOutcome(
                window: WindowRef(windowID: action.windowID, pid: action.pid, bounds: .zero,
                                  title: nil, appName: nil, bundleID: nil,
                                  layer: 0, isOnScreen: true),
                strategy: .publicActivate,
                didRaise: false,
                didActivate: false,
                error: "上一个聚焦动作还在执行中，已拒绝重入（windowID=\(action.windowID)）")
            lastOutcome = outcome
            return outcome
        }
        isPerforming = true
        defer { isPerforming = false }

        let now = clock()

        // 目标窗口：先用第 16 步缓存的 WindowRef（省一次命中测试），
        // 失效了就按最后一次采样点重新探测；两者都拿不到就如实报错，不伪造成功。
        var target: WindowRef?
        if let cached = lastTargetWindow,
           cached.windowID == action.windowID, cached.pid == action.pid {
            target = cached
        } else if let point = lastSample?.point,
                  let probed = probe.window(atQuartzPoint: point),
                  probed.windowID == action.windowID {
            target = probed
        }

        guard let window = target else {
            let outcome = FocusOutcome(
                window: WindowRef(windowID: action.windowID, pid: action.pid, bounds: .zero,
                                  title: nil, appName: nil, bundleID: nil,
                                  layer: 0, isOnScreen: true),
                strategy: .publicActivate,
                didRaise: false,
                didActivate: false,
                error: "找不到 windowID=\(action.windowID) 对应的窗口（探测结果已失效），未执行任何聚焦动作")
            lastOutcome = outcome
            return outcome
        }

        let outcome = actuator.focus(window: window, raise: action.raise)
        lastOutcome = outcome
        // 只有真的调用了 actuator 才记冷却 —— 找不到窗口不算一次动作。
        noteAction(at: now)
        // 一次动作之后要求重新攒满 dwell，防止聚焦失败时反复重试。
        pendingWindowID = nil
        pendingSince = nil
        lastTargetWindow = nil
        return outcome
    }

    /// 清掉 pending 与冷却（例如总开关刚被打开时）。
    func reset() {
        pendingWindowID = nil
        pendingSince = nil
        lastActionAt = nil
        lastTargetWindow = nil
    }

    // MARK: - 诊断记账

    func record(_ reason: FocusIgnoreReason) {
        lastDecision = .ignore(reason)
        stats.ignoreCounts[reason.rawValue, default: 0] += 1
    }

    func record(decision: FocusDecision) {
        lastDecision = decision
    }

    func noteAction(at time: TimeInterval) {
        lastActionAt = time
        stats.actions += 1
        stats.lastActionAt = time
    }

    func currentCooldownBaseline() -> TimeInterval? { lastActionAt }
}
