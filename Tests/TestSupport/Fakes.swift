//  HoverFocus — 测试替身（verifier 所有）
//  ─────────────────────────────────────────────────────────────────────────
//  全部是**纯逻辑替身**：不碰 AX、不碰真实屏幕、不碰真实时钟。
//  这样测试在本机（无辅助功能权限）也能无条件跑通。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

// MARK: - 时钟

final class FakeClock {
    /// 单调时钟读数（秒）
    var now: TimeInterval = 0

    var reader: MonotonicClock { { [unowned self] in self.now } }
}

// MARK: - 设置

final class FakeSettingsStore: SettingsStore {
    var settings: Settings
    private var observers: [(Settings) -> Void] = []
    private(set) var observerCount = 0

    init(_ s: Settings = .default) { settings = s }

    func addObserver(_ callback: @escaping (Settings) -> Void) {
        observers.append(callback)
        observerCount += 1
    }

    func update(_ s: Settings) {
        settings = s
        for o in observers { o(s) }
    }
}

// MARK: - 窗口探测

final class FakeProbe: WindowProbing {
    var windowAtPoint: WindowRef?
    var focused: WindowRef?
    var own: pid_t = 4242
    var systemUIPIDs: Set<pid_t> = []
    var hiddenPIDs: Set<pid_t> = []
    var fullScreen = false
    /// 前台 App 是否正在编辑单行输入框（第 3.5 步守卫）
    var foregroundTextEditor = false
    private(set) var textEditorCalls = 0
    var zOrders: [CGWindowID: Int] = [:]
    /// 按调用顺序依次吐出的 z 序（用尽后回落到 zOrders）。
    /// 用来模拟「聚焦前后 z 序变化」—— FocusController 的 didRaise 就是靠前后对比实测的。
    var zOrderSequences: [CGWindowID: [Int?]] = [:]
    private(set) var zOrderCalls: [CGWindowID] = []

    private(set) var windowAtCalls: [CGPoint] = []
    private(set) var focusedWindowCalls = 0

    func window(atQuartzPoint point: CGPoint) -> WindowRef? {
        windowAtCalls.append(point)
        return windowAtPoint
    }

    func focusedWindow() -> WindowRef? {
        focusedWindowCalls += 1
        return focused
    }

    func ownPID() -> pid_t { own }

    func isSystemUI(pid: pid_t) -> Bool { systemUIPIDs.contains(pid) }

    func isAppHidden(pid: pid_t) -> Bool { hiddenPIDs.contains(pid) }

    func frontmostAppIsFullScreen() -> Bool { fullScreen }

    func frontmostAppHasActiveTextEditor() -> Bool {
        textEditorCalls += 1
        return foregroundTextEditor
    }

    func zOrderIndex(of windowID: CGWindowID) -> Int? {
        zOrderCalls.append(windowID)
        if var seq = zOrderSequences[windowID], !seq.isEmpty {
            let value = seq.removeFirst()
            zOrderSequences[windowID] = seq
            return value
        }
        return zOrders[windowID]
    }
}

// MARK: - 执行器

final class FakeActuator: FocusActing {
    /// 报告用的策略（模拟真实 actuator 的降级：focusOnly 也可能被迫置顶）
    var strategyToReport: FocusStrategy = .skyLightNoRaise
    var didRaiseToReport = false
    var didActivateToReport = true
    var errorToReport: String?

    private(set) var calls: [(window: WindowRef, raise: Bool)] = []

    func focus(window: WindowRef, raise: Bool) -> FocusOutcome {
        calls.append((window, raise))
        return FocusOutcome(window: window,
                            strategy: strategyToReport,
                            didRaise: didRaiseToReport,
                            didActivate: didActivateToReport,
                            error: errorToReport)
    }
}

// MARK: - 鼠标事件源

final class FakeMonitor: MouseEventSource {
    /// 声明这个假事件源是否需要辅助功能授权（默认 false，与 MousePoller 一致）
    var requiresAccessibilityPermission = false
    var onSample: ((MouseSample) -> Void)?
    private(set) var isRunning = false
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
        if let e = startError { throw e }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// 测试里手动喂一个采样（替代真实 CGEventTap）
    func emit(_ sample: MouseSample) { onSample?(sample) }
}

// MARK: - 构造辅助

/// 一个安全的「不在菜单栏里」的 Quartz 坐标点。
/// 无头环境（NSScreen 为空）时退回 (200,400) —— 此时 isInMenuBarRegion 恒为 false。
func safePoint() -> CGPoint {
    let h = CoordinateSpace.primaryScreenHeight
    guard h > 200 else { return CGPoint(x: 200, y: 400) }
    return CGPoint(x: 200, y: h * 0.5)
}

/// 主屏顶边下方 1pt，几何上必落在菜单栏横带内（前提：菜单栏没被自动隐藏）。
func menuBarPoint() -> CGPoint {
    CGPoint(x: 200, y: 1)
}

/// 本机菜单栏是否可用作测试前提（自动隐藏时 visibleFrame == frame，判不出菜单栏）
func menuBarIsTestable() -> Bool {
    CoordinateSpace.isInMenuBarRegion(menuBarPoint())
}

func makeWindow(id: CGWindowID,
                pid: pid_t = 1000,
                x: CGFloat = 100, y: CGFloat = 100,
                w: CGFloat = 400, h: CGFloat = 300,
                title: String? = "测试窗口",
                appName: String? = "TestApp",
                bundleID: String? = "com.test.app",
                layer: Int = 0,
                onScreen: Bool = true) -> WindowRef {
    WindowRef(windowID: id, pid: pid,
              bounds: CGRect(x: x, y: y, width: w, height: h),
              title: title, appName: appName, bundleID: bundleID,
              layer: layer, isOnScreen: onScreen)
}

func settings(enabled: Bool = true,
              mode: ActivationMode = .focusOnly,
              dwell: TimeInterval = 0.5,
              cooldown: TimeInterval = 0.25,
              requireNoModifiers: Bool = true,
              suppressWhileDragging: Bool = true,
              respectFullScreen: Bool = true,
              excludedBundleIDs: Set<String> = [],
              excludedAppNames: Set<String> = []) -> Settings {
    Settings(enabled: enabled, mode: mode, dwellDelay: dwell, cooldown: cooldown,
             requireNoModifiers: requireNoModifiers,
             suppressWhileDragging: suppressWhileDragging,
             respectFullScreen: respectFullScreen,
             excludedBundleIDs: excludedBundleIDs,
             excludedAppNames: excludedAppNames)
}

// MARK: - 场景（把 engine + 四个替身打包，让用例短）

final class Scenario {
    let store: FakeSettingsStore
    let probe: FakeProbe
    let actuator: FakeActuator
    let clock: FakeClock
    let engine: FocusEngine

    init(settings s: Settings = .default) {
        store = FakeSettingsStore(s)
        probe = FakeProbe()
        actuator = FakeActuator()
        clock = FakeClock()
        engine = FocusEngine(settings: store, probe: probe, actuator: actuator, clock: clock.reader)
    }

    /// 把时钟拨到绝对时刻 t，用同一时刻造采样喂给 engine。
    /// 时钟读数与 sample.timestamp 保持一致 —— 契约允许实现取任一者，测试不偏袒。
    @discardableResult
    func handle(at t: TimeInterval,
                point: CGPoint? = nil,
                dragging: Bool = false,
                modifiers: CGEventFlags = []) -> FocusDecision {
        clock.now = t
        let s = MouseSample(point: point ?? safePoint(),
                            timestamp: t,
                            isDragging: dragging,
                            modifiers: modifiers)
        return engine.handle(s)
    }

    @discardableResult
    func tick(at t: TimeInterval) -> FocusDecision {
        clock.now = t
        return engine.tick()
    }

    @discardableResult
    func perform(_ action: FocusAction) -> FocusOutcome {
        engine.perform(action)
    }

    /// 走完「悬停 → 到点 → 执行」的完整一轮
    @discardableResult
    func handleAndPerform(at t: TimeInterval,
                          point: CGPoint? = nil) -> FocusOutcome? {
        let d = handle(at: t, point: point)
        if case .act(let a) = d { return perform(a) }
        return nil
    }
}
