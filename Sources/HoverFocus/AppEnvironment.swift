//  HoverFocus — 依赖装配点
//
//  ⚠️ 这是全 App **唯一**构造 / lead 具体类型的地方。
//  契约（Contracts.swift）只定义 protocol，具体实现分散在别人的文件里；
//  把装配集中在这里，接口一变只改这一处，UI 代码不用动。
//
//  事件源有两种，默认是**零权限**的轮询：
//    MousePoller  轮询光标位置。CGEvent(source:).location / buttonState / flagsState
//                 在未授权时全部可用，纯读取实测 0.08µs/次。
//                 → 用户装完不用去系统设置勾任何权限就能用。
//    MouseMonitor CGEventTap。延迟更低（事件驱动，无轮询周期），
//                 但**未授权时完全收不到事件**（tapCreate 成功但系统立刻禁用、0 事件），
//                 且会被系统禁用/需要重新 enable。属于可选的「低延迟模式」。
//
//  为什么默认轮询：这个工具的价值是「悬停即切焦点」，延迟最坏一个轮询周期（16ms）
//  对用户无感；而要求用户先去系统设置勾权限，会把绝大多数人挡在门外。
//  授予辅助功能后，WindowProbe 的命中测试会从降级模式升级为 AX 精确模式 ——
//  所以**权限是可选的精度增强，不是使用前提**。
//
//  注意：本工程所有源文件由一条 swiftc 命令编进同一个模块，
//  所以这里**不能**写 import HoverFocusCore。

import Foundation

// MARK: - 事件源选择

enum MonitorMode: String, CaseIterable {
    /// 零权限轮询（默认）
    case polling
    /// CGEventTap 低延迟（需要辅助功能/输入监控权限）
    case lowLatency

    var displayName: String {
        switch self {
        case .polling:    return "轮询光标位置（零权限）"
        case .lowLatency: return "CGEventTap 低延迟（需要辅助功能权限，推荐）"
        }
    }

    var shortName: String {
        switch self {
        case .polling:    return "轮询"
        case .lowLatency: return "低延迟 Tap"
        }
    }

    /// 这个事件源要不要辅助功能权限。MouseMonitor 为 true，MousePoller 为 false。
    /// 契约里 MouseEventSource 有这个属性（默认 false），这里保持一致。
    var requiresAccessibility: Bool { self == .lowLatency }
}

// MARK: - 事件源偏好持久化
//
//  契约里的 Settings 没有「事件源」字段（那是判定参数，这是 App 层的运行方式），
//  所以这里单独存一个键。故意**不用** "HoverFocus." 前缀 —— 那是 
//  的 Settings 键空间，混进去可能被他批量读取/清理时误伤。

enum MonitorPreference {
    static let defaultsKey = "HoverFocusUI.monitorMode"

    static func load() -> MonitorMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = MonitorMode(rawValue: raw) else {
            return .polling          // 默认零权限
        }
        return mode
    }

    static func save(_ mode: MonitorMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }

    static func makeMonitor(for mode: MonitorMode) -> MouseEventSource {
        switch mode {
        case .polling:    return MousePoller()
        case .lowLatency: return MouseMonitor()
        }
    }
}

// MARK: - 装配

final class AppEnvironment {
    let settings: SettingsStore
    let probe: WindowProbing
    let actuator: FocusActing

    /// 事件源与 driver 会因为用户切换「监听方式」而重建，所以不是 let
    private(set) var monitor: MouseEventSource
    private(set) var driver: FocusDriver
    private(set) var monitorMode: MonitorMode

    init(settings: SettingsStore,
         probe: WindowProbing,
         actuator: FocusActing,
         monitor: MouseEventSource,
         monitorMode: MonitorMode) {
        self.settings = settings
        self.probe = probe
        self.actuator = actuator
        self.monitor = monitor
        self.monitorMode = monitorMode
        self.driver = FocusDriver(settings: settings,
                                  probe: probe,
                                  actuator: actuator,
                                  monitor: monitor)
    }

    static func make() -> AppEnvironment {
        let store = UserDefaultsSettingsStore()
        let probe = WindowProbe()
        let actuator = FocusController(probe: probe)
        let mode = MonitorPreference.load()
        let monitor = MonitorPreference.makeMonitor(for: mode)
        return AppEnvironment(settings: store, probe: probe, actuator: actuator,
                              monitor: monitor, monitorMode: mode)
    }

    /// 切换事件源。FocusDriver 的 monitor 是 let，所以必须重建 driver。
    /// 调用方负责：先 stop() 旧 driver、清 delegate，切换后自行决定是否 start()。
    @discardableResult
    func switchMonitor(to mode: MonitorMode) -> FocusDriver {
        let newMonitor = MonitorPreference.makeMonitor(for: mode)
        monitor = newMonitor
        monitorMode = mode
        driver = FocusDriver(settings: settings, probe: probe, actuator: actuator, monitor: newMonitor)
        MonitorPreference.save(mode)
        Log.info("事件源已切换为 \(mode.shortName)（需要权限：\(mode.requiresAccessibility)）")
        return driver
    }

    // MARK: 诊断

    /// 当前事件源要不要权限（读契约里的 protocol 属性，不自己猜）
    var monitorRequiresAccessibility: Bool {
        monitor.requiresAccessibilityPermission
    }

    /// CGEventTap 被系统禁用过几次（只有低延迟模式有意义）
    var tapDisableCount: Int? {
        (monitor as? MouseMonitor)?.tapDisableCount
    }

    /// 事件源的诊断信息（两种模式给不同的字典）
    func monitorDiagnosis() -> [String: Any] {
        switch monitor {
        case is MousePoller:
            return MousePoller.diagnosis()
        case is MouseMonitor:
            return MouseMonitor.permissionDiagnosis()
        default:
            return ["source": "未知事件源"]
        }
    }
}
