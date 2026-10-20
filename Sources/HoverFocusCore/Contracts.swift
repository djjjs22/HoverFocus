//  HoverFocus — 契约层（冻结 API）
//  ─────────────────────────────────────────────────────────────────────────
//  本文件定义全工程的核心契约，其余代码都按此实现与测试。
//  改这个文件 = 改公共接口，所有实现方都要同步。
//
//  为什么要有这个文件：这是全工程唯一的接口约定处。接口如果只靠口头约定，
//  合起来一定编译不过。这里把「谁给谁什么」钉死：
//
//      MouseEventSource ──sample──▶ FocusDriver ──▶ FocusEngine ──decision──▶ FocusActing
//                                        ▲              ▲
//                                   WindowProbing   SettingsStore
//
//  ─────────────────────────────────────────────────────────────────────────
//  坐标约定（重要，bug 高发区）
//  全工程内部统一使用 **Quartz 全局坐标**：原点在主显示器左上角，x 向右、y 向下。
//  CoreGraphics / AXUIElementCopyElementAtPosition / CGWindowList 都用这套坐标。
//  AppKit（NSScreen / NSWindow / NSEvent）用 **Cocoa 坐标**：原点左下角、y 向上。
//  两套坐标只允许通过 CoordinateSpace 互相转换，任何地方都不许自己手算翻转。
//
//  时钟约定
//  所有时间戳都用单调时钟（CACurrentMediaTime 语义，单位秒），不要用 Date()。
//  鼠标静止时不会再产生 sample，因此 dwell 计时必须由定时器调用 tick() 推进。
//
//  线程约定
//  以下类型全部只在主线程使用（MainActor）。鼠标事件的回调必须立刻切回主线程。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// MARK: - 坐标转换

enum CoordinateSpace {
    /// 主显示器高度（points）。Cocoa ↔ Quartz 翻转的基准。
    static var primaryScreenHeight: CGFloat {
        // NSScreen.screens[0] 是主屏（带菜单栏那块），其 frame 高度即翻转基准。
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Cocoa（左下原点）→ Quartz（左上原点）
    static func cocoaToQuartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Quartz（左上原点）→ Cocoa（左下原点）
    static func quartzToCocoa(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Cocoa 矩形 → Quartz 矩形
    static func quartzRect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryScreenHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    /// 该点落在哪块屏幕的可见区域内（Quartz 坐标）。nil = 不在任何屏幕（罕见）。
    static func screenVisibleFrame(containingQuartzPoint point: CGPoint) -> CGRect? {
        for screen in NSScreen.screens {
            let f = quartzRect(fromCocoa: screen.visibleFrame)
            if f.contains(point) { return f }
        }
        return nil
    }

    /// 该点是否落在某块屏幕的菜单栏区域（Quartz 坐标）。
    static func isInMenuBarRegion(_ point: CGPoint) -> Bool {
        for screen in NSScreen.screens {
            let full = quartzRect(fromCocoa: screen.frame)
            let visible = quartzRect(fromCocoa: screen.visibleFrame)
            guard full.contains(point) else { continue }
            // 菜单栏 = 屏幕顶边到可见区域顶边之间的横带
            if point.y < visible.minY { return true }
        }
        return false
    }
}

// MARK: - 鼠标采样

/// 一次鼠标状态快照。由 MouseEventSource 产生，FocusEngine 消费。
struct MouseSample: Equatable {
    /// Quartz 全局坐标
    var point: CGPoint
    /// 单调时钟时间戳（秒）
    var timestamp: TimeInterval
    /// 采样时刻是否有任意鼠标键处于按下状态（拖拽窗口 / 拖选文字）
    var isDragging: Bool
    /// 采样时刻的修饰键。用 CGEventFlags 而不是 NSEvent.ModifierFlags，
    /// 因为 CGEventTap 直接给的就是它，避免转换层。
    var modifiers: CGEventFlags

    /// 是否按住了「会让用户意图变复杂」的修饰键。
    /// 注意：capsLock / fn 不算（capsLock 是锁定态，fn 常用于功能键）。
    var hasIntentModifier: Bool {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return !modifiers.intersection(mask).isEmpty
    }
}

// MARK: - 窗口

/// 一个可被聚焦的窗口。由 WindowProbe 组装（AX 命中测试 + CGWindowList 富化）。
struct WindowRef: Equatable, Hashable {
    /// CGWindowID，窗口的唯一标识。跨 Space 稳定。
    var windowID: CGWindowID
    /// 拥有该窗口的进程 pid
    var pid: pid_t
    /// Quartz 坐标下的窗口边界
    var bounds: CGRect
    /// 窗口标题（可能为 nil，某些 App 不暴露）
    var title: String?
    /// App 显示名，如 "Safari"
    var appName: String?
    /// App bundle id，如 "com.apple.Safari"。排除名单以此为主键。
    var bundleID: String?
    /// CGWindowList 的 kCGWindowLayer。0 = 普通应用窗口；>0 = 浮层/Dock/菜单等。
    var layer: Int
    /// 该窗口当前是否真的显示在屏幕上（跨 Space 的窗口为 false）
    var isOnScreen: Bool

    /// 普通应用窗口 = layer 0 且可见。
    var isNormalWindow: Bool { layer == 0 && isOnScreen }
}

// MARK: - 探测（只读，无副作用）

protocol WindowProbing: AnyObject {
    /// 该点最顶层的窗口。没有窗口（桌面/菜单栏/空白）返回 nil。
    /// 实现要求：必须使用 AXUIElementCopyElementAtPosition 命中测试，
    /// 再向上走到 AXWindow 层级；不要用「窗口矩形包含该点」的朴素做法，
    /// 那会在窗口重叠、圆角、阴影、子窗口上判错。
    func window(atQuartzPoint point: CGPoint) -> WindowRef?

    /// 当前前台 App 的焦点窗口（用于 sameWindow 判定）。
    /// 拿不到时返回 nil。
    func focusedWindow() -> WindowRef?

    /// 本工具自身 pid。用于排除自己（设置窗口不该被自己抢焦点）。
    func ownPID() -> pid_t

    /// 是否属于系统 UI 进程（Dock / 控制中心 / 通知中心 / WindowServer /
    /// Spotlight / 本工具）。这些 pid 一律不聚焦。
    func isSystemUI(pid: pid_t) -> Bool

    /// 该 App 是否处于隐藏状态（cmd-H）。隐藏的 App 不该被悬停唤醒。
    func isAppHidden(pid: pid_t) -> Bool

    /// 前台 App 当前是否处于全屏（占据整块屏幕、菜单栏自动隐藏）。
    /// 用于「全屏时绝不抢焦点」这条硬性验收项。
    func frontmostAppIsFullScreen() -> Bool

    /// 前台 App 是不是正在编辑一个**单行文本输入框**（行内重命名 / 表格单元格编辑 / 搜索框）。
    ///
    /// 为什么需要这条：Finder 里选中文件按 Return 重命名，文件名会变成高亮的行内输入框。
    /// 这个编辑会话要求 Finder 保持前台 —— 一旦被切走，**重命名会被直接取消**（用户白编辑）。
    /// 同理还有表格单元格编辑、某些行内改名场景。
    ///
    /// 判定范围故意收窄成「单行输入框（AXTextField / AXComboBox）且可编辑」：
    /// 多行文本区（聊天输入框、代码编辑器、网页 textarea）**不算**，否则在聊天框里打字时
    /// 悬停就再也不会切换窗口了 —— 那会把核心功能废掉。
    func frontmostAppHasActiveTextEditor() -> Bool

    /// 该窗口在当前屏幕上的 z 序（0 = 最前）。拿不到返回 nil。
    /// 用于「focus without raising」的**可测量**验证：聚焦前后 z 序不变才算没置顶。
    func zOrderIndex(of windowID: CGWindowID) -> Int?
}

extension WindowProbing {
    /// 默认 false：假实现（测试）与不支持 AX 的降级模式下都不做这项判定。
    ///
    /// ⚠️ 这条**必须**同时在 protocol body 里声明 + 在这里给默认实现。
    /// 只写在 extension 里会走静态派发，通过存在类型调用时永远拿到 false（踩过一次的坑）。
    func frontmostAppHasActiveTextEditor() -> Bool { false }
}

// MARK: - 执行（有副作用）

enum FocusStrategy: String, CaseIterable {
    /// 私有 SkyLight：_SLPSSetFrontProcessWithOptions，能只切前台不置顶
    case skyLightNoRaise
    /// 公开 AX：AXUIElementSetAttributeValue(app, kAXFrontmost, true)，通常会置顶
    case axFrontmost
    /// 公开 NSRunningApplication.activate()，一定会置顶
    case publicActivate

    var displayName: String {
        switch self {
        case .skyLightNoRaise: return "SkyLight 不置顶"
        case .axFrontmost:     return "AX 置前台"
        case .publicActivate:  return "NSRunningApplication"
        }
    }
}

struct FocusOutcome {
    var window: WindowRef
    /// 实际生效的策略
    var strategy: FocusStrategy
    /// 是否**真的**改变了窗口叠放顺序（由 z 序前后对比实测得出，不是猜的）
    var didRaise: Bool
    /// 是否成功成为前台 App
    var didActivate: Bool
    /// 失败原因（成功为 nil）
    var error: String?
}

protocol FocusActing: AnyObject {
    /// 把 window 所属 App 变成前台。raise=false 时尽最大努力不改变窗口叠放顺序，
    /// 若做不到必须如实把 FocusOutcome.didRaise 报成 true（不许假装成功）。
    func focus(window: WindowRef, raise: Bool) -> FocusOutcome
}

// MARK: - 决策（纯逻辑，零副作用，可单测）

/// 没有动作的全部原因。UI 诊断面板会直接展示这些枚举的 rawValue。
enum FocusIgnoreReason: String {
    case disabled               // 总开关关着
    case dragging               // 正在拖拽
    case modifiersHeld          // 按住修饰键
    case textEditing            // 前台 App 正在编辑单行输入框（Finder 重命名等）—— 切走会取消编辑
    case inMenuBar              // 指针在菜单栏上
    case noWindow               // 指针下没有窗口
    case ownApp                 // 是我们自己的窗口
    case systemUI               // Dock / 控制中心等系统 UI
    case appHidden              // 目标 App 被 cmd-H 隐藏
    case nonNormalWindow        // layer != 0（浮层、提示条等）
    case excludedApp            // 命中排除名单
    case sameWindow             // 已经是当前焦点窗口（最重要的防抖）
    case cooldown               // 距离上次动作太近
    case fullScreenBlocked      // 前台 App 全屏中，不抢
    case notOnScreen            // 窗口不在当前 Space 的可见范围内
}

struct FocusAction: Equatable {
    var windowID: CGWindowID
    var pid: pid_t
    var raise: Bool
}

enum FocusDecision: Equatable {
    /// 明确不动，附带原因
    case ignore(FocusIgnoreReason)
    /// 指针停在目标窗口上，dwell 计时中但还没到点
    case pending(windowID: CGWindowID, remaining: TimeInterval)
    /// 判定成立，请调用方执行 perform(action)
    case act(FocusAction)
}

// MARK: - 设置

enum ActivationMode: String, CaseIterable {
    /// 只切键盘焦点，不改变窗口叠放（默认，用户选定）
    case focusOnly
    /// 切前台并置顶该窗口
    case focusAndRaise

    var displayName: String {
        switch self {
        case .focusOnly:      return "只切焦点，不置顶"
        case .focusAndRaise:  return "切焦点并置顶窗口"
        }
    }
}

struct Settings: Equatable {
    var enabled: Bool
    var mode: ActivationMode
    /// 指针在同一窗口上停留多久才动手（秒）。0 = 立刻。默认 0.12
    var dwellDelay: TimeInterval
    /// 一次动作之后多久内不再动作（秒），防抖。默认 0.15
    var cooldown: TimeInterval
    /// 按住任意修饰键（cmd/opt/ctrl/shift）时不动焦点。默认 true
    var requireNoModifiers: Bool
    /// 拖拽期间完全禁用。默认 true
    var suppressWhileDragging: Bool
    /// 前台 App 全屏时绝不抢焦点。默认 true
    var respectFullScreen: Bool
    /// 排除的 App bundle id
    var excludedBundleIDs: Set<String>
    /// 排除的 App 显示名（bundle id 拿不到时的兜底）
    var excludedAppNames: Set<String>

    static let `default` = Settings(
        enabled: true,
        mode: .focusOnly,
        dwellDelay: 0.12,
        cooldown: 0.15,
        requireNoModifiers: true,
        suppressWhileDragging: true,
        respectFullScreen: true,
        excludedBundleIDs: [],
        excludedAppNames: []
    )

    /// 把用户输入的非法值钳到安全区间。UI 与持久化都要过这一层。
    func sanitized() -> Settings {
        var s = self
        s.dwellDelay = min(max(s.dwellDelay, 0), 1.0)
        // 下限 0.06 不是拍脑袋：WindowProbe.focusedWindow() 有 50ms 缓存，
        // 靠 cooldown 盖过「刚动作完、缓存还没刷新」的窗口，否则会出现
        // 「同一个窗口被反复聚焦」的动作风暴。见 WindowProbe.swift 文件头说明。
        s.cooldown = min(max(s.cooldown, 0.06), 1.0)
        return s
    }
}

protocol SettingsStore: AnyObject {
    var settings: Settings { get set }
    /// 注册变更回调，返回可用于取消的 token（或忽略）。
    func addObserver(_ callback: @escaping (Settings) -> Void)
}

// MARK: - 鼠标事件源

enum MouseMonitorError: Error, CustomStringConvertible {
    case permissionDenied
    case tapCreationFailed
    case alreadyRunning

    var description: String {
        switch self {
        case .permissionDenied:  return "缺少辅助功能权限，无法监听鼠标"
        case .tapCreationFailed: return "CGEventTap 创建失败"
        case .alreadyRunning:    return "监听已在运行"
        }
    }
}

protocol MouseEventSource: AnyObject {
    /// 每次鼠标移动/拖拽都会回调（已在主线程）。
    /// 实现方必须自己做节流（见下方 EngineStats 的预算要求）。
    var onSample: ((MouseSample) -> Void)? { get set }
    var isRunning: Bool { get }
    /// 该事件源是否需要「辅助功能 / 输入监控」授权。
    ///
    /// ⚠️ 这一行**必须**留在 protocol body 里，不能只写在 extension 里。
    /// 只写在 extension 的成员走**静态派发**：通过 `MouseEventSource` 存在类型访问时
    /// 永远拿到默认值 false，具体类型（MouseMonitor）覆写的 true 会被**静默忽略**。
    /// （用同构最小复现验证过：具体类型读 = true，存在类型读 = false。）
    /// body 里声明 + extension 给默认实现 = 正确的动态派发，且不破坏已有实现者。
    var requiresAccessibilityPermission: Bool { get }
    func start() throws
    func stop()
}

extension MouseEventSource {
    /// 默认 false：轮询源（MousePoller）与测试假实现都不需要授权。
    ///
    /// 背景（本机 macOS 27.2 实测）：未授权时 CGEventTap 能创建但被系统立刻禁用、
    /// 收到 0 个事件；而轮询光标位置完全不需要权限（CGEvent(source:).location /
    /// CGEventSource.buttonState / flagsState 均可用，纯读取 0.08µs）。
    /// 所以 MousePoller 是零权限的默认事件源，MouseMonitor(CGEventTap) 是可选的低延迟源，
    /// 只有后者需要权限门槛。
    var requiresAccessibilityPermission: Bool { false }
}

// MARK: - 引擎（决策核心）

struct EngineStats: Equatable {
    var samples: Int = 0
    var actions: Int = 0
    var lastActionAt: TimeInterval?
    /// 每个 ignore 原因被触发的次数，用于诊断面板和「为什么没生效」
    var ignoreCounts: [String: Int] = [:]

    func count(of reason: FocusIgnoreReason) -> Int { ignoreCounts[reason.rawValue] ?? 0 }
}

typealias MonotonicClock = () -> TimeInterval

/// FocusEngine 与 FocusDriver 的**冻结签名**见：
///   Sources/HoverFocusCore/FocusEngine.swift   
///   Sources/HoverFocusCore/FocusDriver.swift   
/// 签名不许改；实现由 负责。只依赖这里的 protocol 与那两个类。
///
/// FocusEngine 的判定顺序（这是本工具的质量核心，按这个顺序写测试）：
///
///   1. !enabled                            → .disabled
///   2. isDragging && suppressWhileDragging → .dragging
///   3. modifiers && requireNoModifiers     → .modifiersHeld
///   3.5 probe.frontmostAppHasActiveTextEditor() → .textEditing
///       （Finder 重命名 / 表格单元格编辑：切走会**取消**正在进行的编辑，必须让路）
///       —— 这是对 AutoFocus 老 bug 的直接修复，放在很前面因为它要保护的是「用户正在输入」这个状态
///   4. 指针在菜单栏                         → .inMenuBar
///   5. window(at:) == nil                  → .noWindow
///   6. 非普通窗口（layer != 0）             → .nonNormalWindow
///      窗口不在当前 Space                    → .notOnScreen
///   7. pid == ownPID                       → .ownApp
///   8. isSystemUI(pid)                     → .systemUI
///   9. isAppHidden(pid)                    → .appHidden
///  10. 命中排除名单                         → .excludedApp
///  11. 前台 App 全屏 && respectFullScreen   → .fullScreenBlocked
///  12. windowID == focusedWindow()?.windowID → .sameWindow
///  13. 距上次动作 < cooldown                → .cooldown
///  14. 目标窗口 != 正在计时的窗口            → 重置计时，返回 .pending(remaining: dwell)
///  15. now - 计时起点 < dwell               → .pending(remaining: 剩余)
///  16. 否则                                → .act(...)
///
/// 注意 12 必须在 14 之前：鼠标在已聚焦窗口上晃不该反复触发动作，
/// 这是 AutoFocus「手一抖焦点就跑了」的主因之一。
///
/// 性能预算：`handle()` 的**纯判定逻辑**必须在 **1ms 内**返回（鼠标移动事件每秒上百个）。
///
/// ⚠️ 这个 1ms **不含 AX 命中测试**。命中测试是 Mach IPC，实测（n=100，未命中缓存）：
/// p50 **1.0ms** / p90 **5.0ms** / max **96ms** —— 算上它，p90 已是 1ms 预算的 5 倍。所以：
///   · 1ms 是**判定逻辑的守门线**，不是端到端延迟承诺；
///   · 守门测试用的是假 probe（不触发真实 AX），**抓不到**命中测试的开销；
///   · 真实开销靠 WindowProbe 的两层缓存压下来（位移 < 3pt 复用：实测 0.0001ms）。
/// 想优化端到端延迟，方向是**减少命中测试次数 / 把它挪出主线程**，而不是优化判定逻辑。

// MARK: - 权限

enum Permissions {
    /// 是否已获得「辅助功能」授权
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 请求授权。prompt=true 会弹出系统对话框并把本 App 加进
    /// 系统设置 → 隐私与安全性 → 辅助功能 列表。
    @discardableResult
    static func requestAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 直接打开系统设置的辅助功能面板（用户手动勾选时用）
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
