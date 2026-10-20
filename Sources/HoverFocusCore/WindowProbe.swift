//  WindowProbe — AX 命中测试 + 窗口信息富化
//
//  这是整个工具最贵的部分，也是精度与「不跨 Space 乱跳」的关键。
//
//  精度：用 AXUIElementCopyElementAtPosition 做真正的命中测试，再向上走到 AXWindow。
//        不要用「窗口矩形包含该点」的朴素做法 —— 窗口重叠、圆角、阴影、子窗口、透明区域
//        都会判错，这正是很多同类工具「边缘处焦点乱跳」的原因。
//
//  性能：命中测试是 Mach IPC，而鼠标事件可达 120Hz。
//        实测（n=100）：未命中缓存 p50 1.0ms / p90 5.0ms / max 96ms；
//        命中缓存 0.0001ms。所以两层缓存是必须的：
//        位移 < 3pt 直接复用上次结果；窗口列表信息 100ms 一次。
//        注意 AX 调用跑在**主线程**上，超时 0.25s —— 遇到卡死的目标 App
//        最坏会阻塞主线程上百毫秒（实测 73ms）。要彻底解决需把它挪出主线程。
//
//  Space 守卫（用户明确要求的硬性验收项）：
//        用 CGWindowListCopyWindowInfo(.optionOnScreenOnly) 建立「当前 Space 上可见窗口」集合。
//        AX 命中测试在别的 Space 的窗口上通常也拿不到窗口元素；万一拿到了，
//        windowID 不在这个集合里 → 返回 isOnScreen=false → 引擎判 .notOnScreen 直接不动。
//        两层保险，绝不触发切 Space。
//
//  与 cooldown 的耦合（重要）：
//        focusedWindow() 有 focusCacheTTL(50ms) 的缓存，靠 Settings.cooldown(默认 150ms)
//        把「动作后缓存还没刷新」的窗口盖过去。所以 **cooldown 不得小于 60ms**，
//        否则可能出现「同一个窗口被反复聚焦」的动作风暴。

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// MARK: - 私有 API 动态加载（拿不到就 fail-soft，不影响其它功能）

private let axGetWindowFunc: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    let paths = [
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    ]
    for path in paths {
        guard let handle = dlopen(path, RTLD_LAZY) else { continue }
        if let symbol = dlsym(handle, "_AXUIElementGetWindow") {
            return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
        }
    }
    return nil
}()

/// 一个窗口在 CGWindowList 里的元信息
struct WindowInfo {
    var layer: Int
    var bounds: CGRect
    var title: String?
    var isOnScreen: Bool
    var ownerName: String?
    var ownerPID: pid_t
}

/// 命中测试模式。AX 精确但需要辅助功能权限；窗口列表降级不需要任何权限。
/// 降级模式对**分屏**（两个不重叠窗口）完全够用，窗口重叠/圆角/透明区域可能判错。
enum HitTestMode: String {
    case accessibility
    case windowListFallback
}

final class WindowProbe: WindowProbing {

    // MARK: 常量

    /// 命中测试缓存：位移小于这个值就复用上次结果
    private static let moveTolerance: CGFloat = 3.0
    /// 命中测试缓存有效期
    private static let hitCacheTTL: TimeInterval = 0.08
    /// 窗口列表缓存有效期
    private static let infoCacheTTL: TimeInterval = 0.10
    /// focusedWindow 缓存有效期。必须明显小于 Settings.cooldown 的下限（见文件头说明）
    /// 50ms → 100ms。原来的 50ms **比 tick 间隔（33ms）还短，等于没缓存**：
    /// 30Hz 的 tick 每次都会打一次跨进程 AX。100ms 仍小于 cooldown(150ms)，
    /// 不会让「动作后缓存未刷新」的问题复活。
    private static let focusCacheTTL: TimeInterval = 0.10
    /// AX 单次请求超时，防止目标 App 卡死时把我们拖住
    private static let axTimeout: Float = 0.25
    /// 向上找 AXWindow 的最大层数
    private static let maxAncestorDepth = 24

    private static let systemUIBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.systemuiserver",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.WindowManager",
        "com.apple.wallpaper.agent",
        "com.apple.universalaccessAuthWarn"
    ]

    private static let systemUINames: Set<String> = [
        "Dock", "程序坞",
        "Control Center", "控制中心",
        "Notification Center", "通知中心",
        "Spotlight", "聚焦",
        "Window Server", "WindowServer",
        "WindowManager", "MenuBarAgent",
        "Wallpaper", "墙纸",
        "universalAccessAuthWarn",
        "SystemUIServer"
    ]

    // MARK: 状态

    private let systemWide = AXUIElementCreateSystemWide()
    private let ownPIDValue = ProcessInfo.processInfo.processIdentifier

    private var hitCache: (point: CGPoint, window: WindowRef?, at: TimeInterval)?
    private var focusCache: (window: WindowRef?, at: TimeInterval)?
    /// 「前台 App 正在编辑单行输入框」的缓存。这是个 AX 查询，不能每个采样都打。
    private var textEditorCache: (active: Bool, at: TimeInterval)?
    private var infoCache: [CGWindowID: WindowInfo] = [:]
    private var infoOrder: [CGWindowID] = []
    private var infoCacheAt: TimeInterval = -1

    init() {
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)
    }

    /// 当前实际生效的命中测试模式。UI 必须如实展示：
    /// 降级模式下「窗口重叠时可能判错」，不能假装和 AX 模式一样准。
    private(set) var hitTestMode: HitTestMode = Permissions.isAccessibilityTrusted ? .accessibility : .windowListFallback

    /// 命中测试**实际**走的路线。
    ///
    /// 必须和 `hitTestMode` 分开：`hitTestMode` 描述的是「本机能力」（有没有权限），
    /// 而这个是「这一次实际发生了什么」。两者混在一起会骗人 ——
    /// 不实现 `accessibilityHitTest:` 的 App（实测：Telegram 返回 -25208）每次都走矩形匹配，
    /// 但诊断面板会显示「精确模式（AX 命中测试）」。这个项目最讲「如实交代」，
    /// 不能让用户以为那一击是精确命中的。
    enum HitTestRoute: String {
        case accessibility      // 走通了 AX 精确命中
        case windowListFallback // 退到窗口列表（矩形包含）匹配
    }
    private(set) var lastHitRoute: HitTestRoute = .accessibility

    /// 刷新 hitTestMode（权限可能在运行中被授予/撤销，不需要重启 App）
    func refreshHitTestMode() {
        hitTestMode = Permissions.isAccessibilityTrusted ? .accessibility : .windowListFallback
    }

    // MARK: - WindowProbing

    func ownPID() -> pid_t { ownPIDValue }

    /// 指针必须「停下」这么久，才值得做一次真正的命中测试。
    ///
    /// 为什么需要这道闸门：命中测试是**跨进程 AX 调用**（`AXUIElementCopyElementAtPosition`），
    /// 请求会被路由到「指针下那个 App 的主线程」去计算 —— Chromium 系（Edge）要遍历无障碍树，
    /// 很贵。原来按 60Hz 打，等于每秒给目标 App 塞 60 次同步 AX 请求，**把它的 UI 线程压住**，
    /// 于是它来不及响应 mousedown，自绘标题栏的 drag-trait 手势激活失败。
    /// 真实现象（2026-10-20 定位）：**Edge / 微信 / Electron 系窗口拖不动**，
    /// 而系统原生窗口正常 —— 因为只有自绘标题栏的 App 走 drag-trait 那条路。
    ///
    /// 而 dwell 的语义本来就是「指针在同一个窗口上**停住**」：指针在移动时，
    /// 判定结果无论如何都会被丢弃。所以移动期间干脆不查 —— 行为不变，
    /// 跨进程请求量却降了一个数量级。
    private static let settleDelay: TimeInterval = 0.06
    private var lastMoveAt: TimeInterval = 0
    private var lastMovePoint: CGPoint?

    func window(atQuartzPoint point: CGPoint) -> WindowRef? {
        let now = ProcessInfo.processInfo.systemUptime

        // 先记录「指针什么时候动过」
        if let last = lastMovePoint {
            if hypot(point.x - last.x, point.y - last.y) > Self.moveTolerance {
                lastMoveAt = now
                lastMovePoint = point
            }
        } else {
            lastMovePoint = point
            lastMoveAt = now
        }

        // 还在动 / 刚停下 → 不做跨进程查询，也不判定。
        // 返回 nil 会让引擎走 clearPending（安全侧），不会误抢焦点。
        if now - lastMoveAt < Self.settleDelay { return nil }

        // 通知横幅 / 通知中心面板优先于一切：指针压在它上面就直接返回它
        // （layer ≠ 0 → 引擎判 .nonNormalWindow → 不动），连 AX 都不用打。
        // 理由见 notificationOverlay 的注释 —— 聚焦会让未读消息被标成已读，不可逆。
        if let overlay = notificationOverlay(atQuartzPoint: point) { return overlay }

        if let cached = hitCache,
           now - cached.at < Self.hitCacheTTL,
           hypot(point.x - cached.point.x, point.y - cached.point.y) < Self.moveTolerance {
            return cached.window
        }
        let result = performHitTest(point)
        hitCache = (point, result, now)
        return result
    }

    func focusedWindow() -> WindowRef? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = focusCache, now - cached.at < Self.focusCacheTTL {
            return cached.window
        }
        let result = queryFocusedWindow()
        focusCache = (result, now)
        return result
    }

    func isSystemUI(pid: pid_t) -> Bool {
        if pid <= 0 || pid == ownPIDValue { return true }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            // 查不到进程信息时保守处理：宁可不聚焦
            return true
        }
        if let bundleID = app.bundleIdentifier, Self.systemUIBundleIDs.contains(bundleID) { return true }
        if let name = app.localizedName, Self.systemUINames.contains(name) { return true }
        return false
    }

    // MARK: - 通知类窗口守卫

    /// 通知横幅 / 通知中心面板的 owner 名称。
    /// 用 `WindowInfo.ownerName` 直接比对，避免每次命中测试都去查进程信息。
    private static let notificationOwnerNames: Set<String> = [
        "通知中心", "Notification Center",
        "UserNotificationCenter", "com.apple.notificationcenterui",
    ]

    /// 指针下的通知类窗口（横幅 / 通知中心面板）。
    ///
    /// **为什么需要这道守卫**：很多 IM（企业微信、微信）**一旦被聚焦就把消息标成已读**。
    /// 用户刻意留着不回的未读提醒会当场消失，而且不可逆 —— 他本来只是在看通知内容。
    /// 把鼠标移到通知横幅上就替他「读掉」消息，是比「不好用」严重得多的伤害。
    ///
    /// **为什么不能只靠 `isSystemUI`**：那道守卫看的是**命中测试返回的那个窗口**的 pid。
    /// 而通知横幅不一定会参与 AX 命中测试 —— 这时 AX 返回的是横幅**下面那个 App** 的元素，
    /// 守卫看到的是普通 App，于是照样切焦点。所以必须用窗口列表再交叉校验一次：
    /// 指针下只要压着通知类窗口，就把它返出去（layer ≠ 0 → 引擎判 .nonNormalWindow → 不动）。
    ///
    /// 先查这一层还有个附带好处：命中通知横幅时**连 AX 都不用打**。
    private func notificationOverlay(atQuartzPoint point: CGPoint) -> WindowRef? {
        refreshWindowInfoIfNeeded()
        // 通知中心除了横幅，还有一个**铺满屏幕的不可见背板窗口**。
        // 把背板当成横幅会把所有悬停都挡掉，所以面积超过可见区 60% 的一律跳过 ——
        // 真正的横幅（约 360×180）和展开的面板都远小于这个比例。
        let screenArea = CoordinateSpace.screenVisibleFrame(containingQuartzPoint: point)
            .map { $0.width * $0.height } ?? 0

        for windowID in infoOrder {
            guard let info = infoCache[windowID] else { continue }
            guard Self.isNotificationOverlay(ownerName: info.ownerName,
                                             bounds: info.bounds,
                                             isOnScreen: info.isOnScreen,
                                             screenArea: screenArea,
                                             point: point) else { continue }
            return makeRef(windowID: windowID, pid: info.ownerPID, info: info)
        }
        return nil
    }

    /// 纯判定：这个窗口是不是「指针下应当挡住悬停切焦点」的通知类窗口。
    ///
    /// 抽成静态纯函数是为了**可单测** —— 真实的通知横幅在测试环境里造不出来，
    /// 而这条规则一旦写错，用户未读消息会被静默标成已读（不可逆），值得单独测。
    static func isNotificationOverlay(ownerName: String?,
                                      bounds: CGRect,
                                      isOnScreen: Bool,
                                      screenArea: CGFloat,
                                      point: CGPoint) -> Bool {
        guard isOnScreen else { return false }
        guard let name = ownerName, notificationOwnerNames.contains(name) else { return false }
        guard bounds.contains(point) else { return false }
        // 跳过铺满屏幕的不可见背板
        if screenArea > 0, bounds.width * bounds.height > screenArea * 0.6 { return false }
        return true
    }

    /// 隐藏状态变化极少（只有 cmd-H），但**原来每次判定都查一遍** ——
    /// 实测 30Hz tick 下每秒 24 次。加按 pid 的短缓存。
    private var hiddenCache: [pid_t: (hidden: Bool, at: TimeInterval)] = [:]

    func isAppHidden(pid: pid_t) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = hiddenCache[pid], now - c.at < Self.appStateCacheTTL { return c.hidden }
        let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
        hiddenCache[pid] = (hidden, now)
        return hidden
    }

    // MARK: - 文本编辑守卫（修复 AutoFocus 的老 bug）

    /// 单行可编辑输入框的 AX role。**故意只收单行**：多行文本区（聊天框、代码编辑器、
    /// 网页 textarea）不算 —— 否则在聊天框里打字时悬停就再也不切窗口，核心功能就废了。
    private static let singleLineEditorRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    func frontmostAppHasActiveTextEditor() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = textEditorCache, now - cached.at < Self.focusCacheTTL { return cached.active }
        let active = queryFrontmostInlineEditor()
        textEditorCache = (active, now)
        return active
    }

    private func queryFrontmostInlineEditor() -> Bool {
        // 降级模式（没有辅助功能权限）拿不到 AX 焦点元素，只能返回 false —— 这条守卫失效，
        // 但降级模式本来就是「能用优先」，不额外加代价。
        guard Permissions.isAccessibilityTrusted else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        guard let focused = copyElementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else {
            return false
        }
        let role = role(of: focused) ?? ""
        guard Self.singleLineEditorRoles.contains(role) else { return false }
        // 可编辑才算「正在编辑」。AXEditable 拿不到时保守认为可编辑（单行输入框基本都是）。
        // AXEditable 在 Swift 里没有现成常量（kAXEditableAttribute 不存在），只能用字符串。
        if let editable = copyBoolAttribute(focused, "AXEditable" as CFString) { return editable }
        return true
    }

    /// 前台 App 是否全屏。**原来完全没有缓存**，30Hz tick 下每秒 24 次跨进程 AX 查询
    /// 全打在正在使用的那款 App 上（实测就是它把 Edge 的主线程压住、导致窗口拖不动）。
    /// 全屏状态切换是低频事件，缓存 0.5s 完全够用。
    private static let appStateCacheTTL: TimeInterval = 1.0
    private static let fullScreenCacheTTL: TimeInterval = 0.5
    private var fullScreenCache: (pid: pid_t, isFull: Bool, at: TimeInterval)?

    func frontmostAppIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let c = fullScreenCache, c.pid == app.processIdentifier,
           now - c.at < Self.fullScreenCacheTTL {
            return c.isFull
        }
        let result = computeFrontmostAppIsFullScreen(app: app)
        fullScreenCache = (app.processIdentifier, result, now)
        return result
    }

    /// 真正的计算（无缓存）。外层的 frontmostAppIsFullScreen 负责缓存。
    private func computeFrontmostAppIsFullScreen(app: NSRunningApplication) -> Bool {

        if Permissions.isAccessibilityTrusted {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
            if let windowElement = copyElementAttribute(appElement, kAXFocusedWindowAttribute as CFString) {
                // AXFullScreen 属性最准（原生全屏一定为 true），但**不能因为它是 false 就返回 false** ——
                // 有些窗口不是原生全屏、却几何上铺满整屏（游戏无边框全屏、手动拉满的播放器、
                // 铺满屏幕的终端等）。这里必须「原生全屏 OR 几何铺满」，否则几何兜底成了死代码。
                // 实测抓到的 bug：AXFullScreen=false 直接 return，导致铺满屏幕的窗口守卫失效。
                if copyBoolAttribute(windowElement, "AXFullScreen" as CFString) == true { return true }
                if let bounds = axBounds(of: windowElement), coversAnyScreen(bounds) { return true }
            }
        }

        // 降级 / 兜底：前台 App 的 z 序最靠前那个窗口是否盖住了整块屏幕
        // （全屏窗口会连菜单栏区域一起盖住，所以和 screen.frame 比而不是 visibleFrame）
        refreshWindowInfoIfNeeded()
        for windowID in infoOrder {
            guard let info = infoCache[windowID], info.ownerPID == app.processIdentifier, info.layer == 0 else { continue }
            return coversAnyScreen(info.bounds)
        }
        return false
    }

    /// 窗口是否（几何上）盖住整块屏幕。
    ///
    /// 容差用 **1% 相对值**而不是固定 2pt：真实全屏窗口的边界常常比屏幕 frame 内缩几个点
    /// （实测一个「铺满屏幕」的窗口是 2038×1178，而屏幕 frame 是 2048×1152，内缩约 5pt/侧）。
    /// 固定 2pt 会把它判成「不是全屏」，全屏守卫直接失效 —— 这是实测抓到的 bug。
    /// 反过来，「缩放/最大化」的普通窗口只覆盖 visibleFrame（高 1033，比 frame 少 119pt ≈ 10%），
    /// 1% 容差不会把它误判成全屏。两者差一个数量级，阈值是安全的。
    private func coversAnyScreen(_ bounds: CGRect) -> Bool {
        for screen in NSScreen.screens {
            let frame = CoordinateSpace.quartzRect(fromCocoa: screen.frame)
            let toleranceX = max(8, frame.width * 0.01)
            let toleranceY = max(8, frame.height * 0.01)
            if bounds.width >= frame.width - toleranceX && bounds.height >= frame.height - toleranceY {
                return true
            }
        }
        return false
    }

    func zOrderIndex(of windowID: CGWindowID) -> Int? {
        refreshWindowInfoIfNeeded(force: true)
        return infoOrder.firstIndex(of: windowID)
    }

    // MARK: - 命中测试

    private func performHitTest(_ point: CGPoint) -> WindowRef? {
        // 没有辅助功能权限时 AX 命中测试必然失败（实测返回 -25211 kAXErrorAPIDisabled），
        // 直接走窗口列表降级，别白花一次 IPC 的时间。
        guard Permissions.isAccessibilityTrusted else {
            hitTestMode = .windowListFallback
            lastHitRoute = .windowListFallback
            return hitTestViaWindowList(point)
        }
        hitTestMode = .accessibility
        lastHitRoute = .accessibility

        var elementRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        // ⚠️ 这条路径必须兜底到窗口列表命中测试，不能直接 return nil。
        //
        // 实测（macOS 27.2）：有些 App **不实现 accessibilityHitTest:**，对它们调
        // AXUIElementCopyElementAtPosition 会返回 kAXErrorNotImplemented(-25208)。
        // 已确认的：Telegram（在其窗口可见区域实测 err=-25208、element=nil）。
        // 如果这里直接返回 nil，引擎会判「鼠标下没有窗口」→ 这类 App **永远无法被悬停聚焦**，
        // 用户看到的现象就是「滑到那个窗口上没反应」。
        // 同理，AX 树稀疏/层级过深导致找不到 AXWindow 时也要兜底。
        guard error == .success, let element = elementRef else {
            lastHitRoute = .windowListFallback
            return hitTestViaWindowList(point)
        }
        guard let windowElement = findWindowElement(from: element) else {
            lastHitRoute = .windowListFallback
            return hitTestViaWindowList(point)
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(windowElement, &pid) == .success else {
            // 同上：AX 侧拿不到 pid 也别放弃，退回窗口列表命中测试。
            lastHitRoute = .windowListFallback
            return hitTestViaWindowList(point)
        }

        var windowID: CGWindowID = 0
        let gotWindowID = axGetWindowFunc?(windowElement, &windowID) == .success && windowID != 0

        refreshWindowInfoIfNeeded()

        if gotWindowID {
            if let info = infoCache[windowID] {
                // 在当前 Space 上可见 —— 正常路径
                return makeRef(windowID: windowID, pid: pid, info: info)
            }
            // 窗口元素拿到了，但它不在当前 Space 的可见窗口列表里：
            // 这正是「别的 Space / 已最小化 / 特殊窗口」的情况，如实标成不可见，
            // 让引擎判 .notOnScreen 而不动手（绝不切 Space）。
            return WindowRef(windowID: windowID,
                             pid: pid,
                             bounds: axBounds(of: windowElement) ?? .zero,
                             title: nil,
                             appName: appName(pid: pid),
                             bundleID: bundleID(pid: pid),
                             layer: 0,
                             isOnScreen: false)
        }

        // 私有 API 不可用：按 pid + 几何位置在可见窗口列表里兜底匹配
        return matchVisibleWindow(pid: pid, axWindow: windowElement)
    }

    /// 从命中元素向上找到 AXWindow。
    /// 快路径是直接读 AXWindow 属性（多数元素都有），慢路径才逐级走 parent。
    private func findWindowElement(from element: AXUIElement) -> AXUIElement? {
        if let windowElement = copyElementAttribute(element, kAXWindowAttribute as CFString),
           role(of: windowElement) == (kAXWindowRole as String) {
            return windowElement
        }

        var current: AXUIElement? = element
        var depth = 0
        while let element = current, depth < Self.maxAncestorDepth {
            if role(of: element) == (kAXWindowRole as String) { return element }
            current = copyElementAttribute(element, kAXParentAttribute as CFString)
            depth += 1
        }
        return nil
    }

    /// 无需任何权限的降级命中测试：按「前→后」顺序取第一个矩形包含该点的 layer-0 可见窗口。
    ///
    /// 与 AX 路径的**已知差异**（不要假装两者等价）：
    /// - 判不出圆角、阴影、透明区域、子窗口；窗口重叠时只能按矩形包含判断。
    /// - 系统 UI 的处理**已经与 AX 路径对齐**：指针下最上层是系统 UI 就一律不动。
    ///   （早期版本会跳过系统 UI 继续往后找，那会在悬停通知横幅时误抢它下面窗口的焦点。）
    private func hitTestViaWindowList(_ point: CGPoint) -> WindowRef? {
        // 菜单栏与 Dock 区域没有 layer-0 窗口，但「窗口的矩形」会延伸到那里
        // （实测：Dock 下方的点会命中一个被 Dock 盖住的窗口）。可见区域之外一律不算命中，
        // 否则鼠标滑过 Dock 就会把底下的窗口切到前台。
        guard CoordinateSpace.screenVisibleFrame(containingQuartzPoint: point) != nil else { return nil }

        refreshWindowInfoIfNeeded()
        for windowID in infoOrder {
            guard let info = infoCache[windowID] else { continue }
            guard info.layer == 0, info.isOnScreen, info.bounds.contains(point) else { continue }
            // 指针下最上层的窗口是系统 UI（通知横幅、控制中心等）→ **不动**，与 AX 路径一致。
            //
            // 这里曾经是 `continue`（跳过系统 UI 继续往下找）。那样会造成**误抢焦点**：
            // 悬停在通知横幅上时，命中的是横幅下面那个普通窗口，引擎会把它切到前台。
            // AX 路径只会拿到最上层元素 → 判为系统 UI → 不动。两条路径行为不一致本身就是缺陷，
            // 而且「不动」是安全的那一侧 ——「不误抢焦点」是这个项目的第一条硬性标准。
            if isSystemUI(pid: info.ownerPID) { return nil }
            return makeRef(windowID: windowID, pid: info.ownerPID, info: info)
        }
        return nil
    }

    private func queryFocusedWindow() -> WindowRef? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        // 降级模式：拿不到 AX 焦点窗口，用「前台 App 的 z 序最靠前那个 layer-0 窗口」近似。
        // 不这么做的话，引擎第 12 步 sameWindow 永远不成立 → 会退化成动作风暴。
        guard Permissions.isAccessibilityTrusted else {
            refreshWindowInfoIfNeeded()
            for windowID in infoOrder {
                guard let info = infoCache[windowID], info.ownerPID == app.processIdentifier, info.layer == 0 else { continue }
                return makeRef(windowID: windowID, pid: app.processIdentifier, info: info)
            }
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        guard let windowElement = copyElementAttribute(appElement, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        var windowID: CGWindowID = 0
        guard axGetWindowFunc?(windowElement, &windowID) == .success, windowID != 0 else {
            // 拿不到 windowID 时用几何信息兜底，至少 pid 是对的
            return matchVisibleWindow(pid: app.processIdentifier, axWindow: windowElement)
        }

        refreshWindowInfoIfNeeded()
        if let info = infoCache[windowID] {
            return makeRef(windowID: windowID, pid: app.processIdentifier, info: info)
        }
        return WindowRef(windowID: windowID,
                         pid: app.processIdentifier,
                         bounds: axBounds(of: windowElement) ?? .zero,
                         title: nil,
                         appName: app.localizedName,
                         bundleID: app.bundleIdentifier,
                         layer: 0,
                         isOnScreen: true)
    }

    // MARK: - 窗口列表

    private func refreshWindowInfoIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - infoCacheAt < Self.infoCacheTTL, !infoCache.isEmpty { return }

        var map: [CGWindowID: WindowInfo] = [:]
        var order: [CGWindowID] = []
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []

        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
            map[windowID] = WindowInfo(
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                // 注意：窗口标题在 macOS 10.15+ 需要「屏幕录制」权限才会返回，拿不到就是 nil，属正常
                title: entry[kCGWindowName as String] as? String,
                isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                ownerName: entry[kCGWindowOwnerName as String] as? String,
                ownerPID: (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            )
            order.append(windowID)
        }

        infoCache = map
        infoOrder = order
        infoCacheAt = now
    }

    private func makeRef(windowID: CGWindowID, pid: pid_t, info: WindowInfo) -> WindowRef {
        WindowRef(windowID: windowID,
                  pid: pid,
                  bounds: info.bounds,
                  title: info.title,
                  appName: info.ownerName ?? appName(pid: pid),
                  bundleID: bundleID(pid: pid),
                  layer: info.layer,
                  isOnScreen: info.isOnScreen)
    }

    /// 私有 API 不可用时的兜底：同 pid 的可见窗口里，边界最接近 AX 边界且包含该点的那个。
    private func matchVisibleWindow(pid: pid_t, axWindow: AXUIElement) -> WindowRef? {
        guard let bounds = axBounds(of: axWindow) else { return nil }
        refreshWindowInfoIfNeeded()
        var best: (windowID: CGWindowID, info: WindowInfo, distance: CGFloat)?
        for windowID in infoOrder {
            guard let info = infoCache[windowID], info.ownerPID == pid, info.layer == 0 else { continue }
            let distance = abs(info.bounds.minX - bounds.minX) + abs(info.bounds.minY - bounds.minY)
                + abs(info.bounds.width - bounds.width) + abs(info.bounds.height - bounds.height)
            if best == nil || distance < best!.distance {
                best = (windowID, info, distance)
            }
        }
        guard let best, best.distance < 4 else { return nil }
        return makeRef(windowID: best.windowID, pid: pid, info: best.info)
    }

    // MARK: - AX 小工具

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! String)
    }

    private func copyBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func role(of element: AXUIElement) -> String? {
        copyStringAttribute(element, kAXRoleAttribute as CFString)
    }

    private func axBounds(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute as CFString),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        guard AXValueGetValue((positionValue as! AXValue), .cgPoint, &origin),
              AXValueGetValue((sizeValue as! AXValue), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func appName(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private func bundleID(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
