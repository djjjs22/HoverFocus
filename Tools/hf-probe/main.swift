//  hf-probe — HoverFocus 诊断探针
//  ─────────────────────────────────────────────────────────────────────────
//  为什么需要它：本机没有辅助功能权限、看不到屏幕、菜单栏图标不是独立窗口，
//  所以「到底能不能只切焦点不置顶」这件事只能用进程内探针 + 系统查询来标定。
//
//  构建（见 Scripts/build-probe.sh）：
//      swiftc Sources/HoverFocusCore/*.swift Tools/hf-probe/main.swift -o build/hf-probe
//  即**链接真实核心代码**（WindowProbe / FocusController / SkyLightBridge / Permissions），
//  但所有「测量」都用本文件自己独立实现的 CGWindowList / NSWorkspace 查询 ——
//  不用被测代码去测被测代码。
//
//  输出：默认 `KEY=VALUE` 行（shell 直接 grep，无需 JSON 解析器）；--json 额外给一行 JSON。
//  AX 相关命令在无权限时**明确打印 AX_TRUSTED=0 / 错误码**，不是失败，是环境事实。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 输出
// ═══════════════════════════════════════════════════════════════════════

var jsonMode = false
var jsonBag: [String: Any] = [:]
/// FocusController（真实实现）最近一次结果，供 `focus --strategy controller` 打印
var controllerOutcome: FocusOutcome?

func emit(_ key: String, _ value: Any) {
    print("\(key)=\(value)")
    jsonBag[key] = value
}

func emitJSONIfRequested() {
    guard jsonMode else { return }
    if let data = try? JSONSerialization.data(withJSONObject: jsonBag, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print("JSON=\(text)")
    }
}

func note(_ text: String) {
    print("# \(text)")
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 私有 API
// ═══════════════════════════════════════════════════════════════════════
//  这里**不重复实现** SkyLight 封装：直接用核心代码里的 SkyLightBridge，
//  这样标定出来的结果就是 App 实际会走的那条路径。

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 独立测量（不经过被测代码）
// ═══════════════════════════════════════════════════════════════════════

struct ProbeWin {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    var bounds: CGRect
    var owner: String
    var title: String?
    var onScreen: Bool
}

/// 前 → 后的窗口顺序（CGWindowListCopyWindowInfo 的顺序即 z 序，0 = 最前）
func probeWindowList(onScreenOnly: Bool = true) -> [ProbeWin] {
    let options: CGWindowListOption = onScreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { entry in
        guard let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
        let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
        return ProbeWin(
            id: CGWindowID(number.uint32Value),
            pid: (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            bounds: bounds,
            owner: entry[kCGWindowOwnerName as String] as? String ?? "?",
            title: entry[kCGWindowName as String] as? String,
            onScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
        )
    }
}

/// z 序下标（0 = 最前）。窗口不在列表里返回 nil。
func probeZIndex(of windowID: CGWindowID) -> Int? {
    probeWindowList().firstIndex { $0.id == windowID }
}

/// 只统计 layer-0 窗口的 z 序（更贴近「应用窗口有没有被置顶」的语义）
func probeZIndexLayer0(of windowID: CGWindowID) -> Int? {
    probeWindowList().filter { $0.layer == 0 }.firstIndex { $0.id == windowID }
}

func probeFrontmostPID() -> pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
}

/// NSWorkspace.frontmostApplication **必须跑 RunLoop 才会更新**（usleep 拿不到新值）。
func spinRunLoop(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func appName(_ pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
}

func bundleID(_ pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
}

/// 目标 pid 最靠前的 layer-0 窗口
func topWindow(of pid: pid_t) -> ProbeWin? {
    probeWindowList().first { $0.pid == pid && $0.layer == 0 }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 三种激活策略（探针自己实现，用于标定）
// ═══════════════════════════════════════════════════════════════════════

struct StrategyResult {
    var strategy: String
    var available: Bool
    var code: Int32
    var note: String
}

func applySkyLightNoRaise(pid: pid_t, windowID: CGWindowID) -> StrategyResult {
    guard let setFront = SkyLightBridge.setFrontProcess else {
        return StrategyResult(strategy: "skyLightNoRaise", available: false, code: -1,
                              note: "_SLPSSetFrontProcessWithOptions 符号不可用")
    }
    guard let getPSN = SkyLightBridge.processForPID else {
        return StrategyResult(strategy: "skyLightNoRaise", available: false, code: -1,
                              note: "GetProcessForPID 符号不可用")
    }
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    let psnErr = getPSN(pid, &psn)
    guard psnErr == 0 else {
        return StrategyResult(strategy: "skyLightNoRaise", available: true, code: Int32(psnErr),
                              note: "GetProcessForPID 返回 \(psnErr)")
    }
    let err = setFront(&psn, UInt32(windowID), SkyLightBridge.userGeneratedMode)
    return StrategyResult(strategy: "skyLightNoRaise", available: true, code: err,
                          note: err == 0 ? "调用成功" : "调用返回 \(err)")
}

func applyAXFrontmost(pid: pid_t) -> StrategyResult {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    let err = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    return StrategyResult(strategy: "axFrontmost", available: true, code: Int32(err.rawValue),
                          note: err == .success ? "调用成功" : "AXError \(err.rawValue)")
}

func applyPublicActivate(pid: pid_t) -> StrategyResult {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return StrategyResult(strategy: "publicActivate", available: true, code: -1,
                              note: "NSRunningApplication(pid:) 为 nil")
    }
    let ok = app.activate(options: [.activateIgnoringOtherApps])
    return StrategyResult(strategy: "publicActivate", available: true, code: ok ? 0 : -1,
                          note: ok ? "activate 被受理" : "activate 返回 false")
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 子命令
// ═══════════════════════════════════════════════════════════════════════

func cmdTrust() -> Int32 {
    let trusted = Permissions.isAccessibilityTrusted
    emit("AX_TRUSTED", trusted ? 1 : 0)
    emitJSONIfRequested()
    return trusted ? 0 : 3
}

func cmdCheck() -> Int32 {
    note("HoverFocus 环境自检")
    let trusted = Permissions.isAccessibilityTrusted
    emit("AX_TRUSTED", trusted ? 1 : 0)
    emit("LISTEN_EVENT_ACCESS", CGPreflightListenEventAccess() ? 1 : 0)
    emit("POST_EVENT_ACCESS", CGPreflightPostEventAccess() ? 1 : 0)

    // CGEventTap 能否创建（listenOnly）
    var tapOK = false
    let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
    let callback: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
    if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                   options: .listenOnly, eventsOfInterest: mask,
                                   callback: callback, userInfo: nil) {
        tapOK = true
        CFMachPortInvalidate(tap)
    }
    emit("EVENT_TAP_OK", tapOK ? 1 : 0)
    emit("SKYLIGHT_SETFRONT_AVAILABLE", SkyLightBridge.setFrontProcess != nil ? 1 : 0)
    emit("GETPROCESSFORPID_AVAILABLE", SkyLightBridge.processForPID != nil ? 1 : 0)

    // 坐标自洽
    let height = CoordinateSpace.primaryScreenHeight
    emit("PRIMARY_SCREEN_HEIGHT", height)
    if let screen = NSScreen.screens.first {
        let q = CoordinateSpace.quartzRect(fromCocoa: screen.frame)
        let v = CoordinateSpace.quartzRect(fromCocoa: screen.visibleFrame)
        emit("SCREEN_FRAME_QUARTZ", "\(Int(q.minX)),\(Int(q.minY)),\(Int(q.width)),\(Int(q.height))")
        emit("SCREEN_VISIBLE_QUARTZ", "\(Int(v.minX)),\(Int(v.minY)),\(Int(v.width)),\(Int(v.height))")
        emit("MENUBAR_HEIGHT", Int(v.minY - q.minY))
    } else {
        emit("SCREEN_FRAME_QUARTZ", "none")
        emit("MENUBAR_HEIGHT", -1)
    }
    let probe = CGPoint(x: 12.5, y: 34.5)
    let roundTrip = CoordinateSpace.quartzToCocoa(CoordinateSpace.cocoaToQuartz(probe))
    let roundTripOK = abs(roundTrip.x - probe.x) < 0.001 && abs(roundTrip.y - probe.y) < 0.001
    emit("COORD_ROUNDTRIP_OK", roundTripOK ? 1 : 0)

    // 真实鼠标位置：Cocoa 与 Quartz 两套读数必须自洽
    let cocoa = NSEvent.mouseLocation
    let quartz = CGEvent(source: nil)?.location ?? .zero
    emit("MOUSE_QUARTZ", String(format: "%.1f,%.1f", quartz.x, quartz.y))
    emit("MOUSE_COCOA", String(format: "%.1f,%.1f", cocoa.x, cocoa.y))
    let mouseConsistent = abs(quartz.x - cocoa.x) < 1.0 && abs((height - cocoa.y) - quartz.y) < 1.0
    emit("MOUSE_SPACES_CONSISTENT", mouseConsistent ? 1 : 0)
    emit("MENUBAR_HIT_500_10", CoordinateSpace.isInMenuBarRegion(CGPoint(x: 500, y: 10)) ? 1 : 0)

    // 命中测试模式（真实核心代码里的判定）
    let wp = WindowProbe()
    wp.refreshHitTestMode()
    emit("HIT_TEST_MODE", wp.hitTestMode.rawValue)

    // AX 命中测试错误码（权限未授予时 -25211 = kAXErrorAPIDisabled）
    let systemWide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let axErr = AXUIElementCopyElementAtPosition(systemWide, Float(quartz.x), Float(quartz.y), &element)
    emit("AX_HIT_ERROR", Int(axErr.rawValue))
    emit("AX_HIT_OK", axErr == .success ? 1 : 0)

    // 降级模式（CGWindowList 矩形包含）在鼠标位置命中的窗口
    if let hit = wp.window(atQuartzPoint: quartz) {
        emit("PROBE_HIT_WINDOW", Int(hit.windowID))
        emit("PROBE_HIT_PID", Int(hit.pid))
        emit("PROBE_HIT_APP", hit.appName ?? "?")
    } else {
        emit("PROBE_HIT_WINDOW", -1)
    }

    emit("FRONT_PID", Int(probeFrontmostPID()))
    emit("FRONT_APP", appName(probeFrontmostPID()))
    emitJSONIfRequested()
    return 0
}

func cmdList() -> Int32 {
    let list = probeWindowList()
    for (i, w) in list.enumerated() {
        let b = "\(Int(w.bounds.minX)),\(Int(w.bounds.minY)),\(Int(w.bounds.width)),\(Int(w.bounds.height))"
        print("Z=\(i) ID=\(w.id) PID=\(w.pid) LAYER=\(w.layer) BOUNDS=\(b) ONSCREEN=\(w.onScreen ? 1 : 0) OWNER=\(w.owner)")
    }
    emit("WINDOW_COUNT", list.count)
    emitJSONIfRequested()
    return 0
}

func cmdFrontmost() -> Int32 {
    // frontmostApplication 需要 RunLoop 才刷新
    spinRunLoop(0.35)
    let pid = probeFrontmostPID()
    emit("FRONT_PID", pid)
    emit("FRONT_APP", appName(pid))
    emit("FRONT_BUNDLE", bundleID(pid))
    emitJSONIfRequested()
    return 0
}

func cmdZorder(_ args: [String]) -> Int32 {
    guard let raw = value(of: "--window", in: args), let wid = UInt32(raw) else {
        FileHandle.standardError.write("用法: hf-probe zorder --window <id>\n".data(using: .utf8)!)
        return 2
    }
    let all = probeWindowList()
    emit("Z_INDEX", all.firstIndex { $0.id == wid } ?? -1)
    emit("Z_INDEX_LAYER0", all.filter { $0.layer == 0 }.firstIndex { $0.id == wid } ?? -1)
    emit("WINDOW_COUNT", all.count)
    emitJSONIfRequested()
    return 0
}

func cmdHit(_ args: [String]) -> Int32 {
    var point = CGEvent(source: nil)?.location ?? .zero
    let positional = args.filter { !$0.hasPrefix("--") }
    if positional.count >= 2, let x = Double(positional[0]), let y = Double(positional[1]) {
        point = CGPoint(x: x, y: y)
    }
    emit("POINT", String(format: "%.1f,%.1f", point.x, point.y))
    emit("IN_MENUBAR", CoordinateSpace.isInMenuBarRegion(point) ? 1 : 0)

    let systemWide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
    emit("AX_HIT_ERROR", Int(err.rawValue))
    emit("AX_HIT_OK", err == .success ? 1 : 0)
    if err == .success, let element {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            emit("AX_HIT_PID", Int(pid))
            emit("AX_HIT_APP", appName(pid))
        }
    } else if err.rawValue == -25211 {
        note("权限未授予（kAXErrorAPIDisabled = -25211）：AX 命中测试不可用，这不是 bug")
    }

    let wp = WindowProbe()
    wp.refreshHitTestMode()
    emit("HIT_TEST_MODE", wp.hitTestMode.rawValue)
    if let hit = wp.window(atQuartzPoint: point) {
        emit("PROBE_HIT_WINDOW", Int(hit.windowID))
        emit("PROBE_HIT_PID", Int(hit.pid))
        emit("PROBE_HIT_APP", hit.appName ?? "?")
        emit("PROBE_HIT_BOUNDS",
             "\(Int(hit.bounds.minX)),\(Int(hit.bounds.minY)),\(Int(hit.bounds.width)),\(Int(hit.bounds.height))")
        emit("PROBE_HIT_LAYER", hit.layer)
        emit("PROBE_HIT_ONSCREEN", hit.isOnScreen ? 1 : 0)
        emit("PROBE_HIT_ZINDEX", probeZIndex(of: hit.windowID) ?? -1)
    } else {
        emit("PROBE_HIT_WINDOW", -1)
    }

    // 独立复算：窗口列表矩形包含（降级模式的语义）
    let visible = CoordinateSpace.screenVisibleFrame(containingQuartzPoint: point)
    emit("INDEP_VISIBLE_FRAME_OK", visible != nil ? 1 : 0)
    var independent: CGWindowID = 0
    if visible != nil {
        for w in probeWindowList() where w.layer == 0 && w.onScreen && w.bounds.contains(point) {
            independent = w.id
            break
        }
    }
    emit("INDEP_HIT_WINDOW", independent == 0 ? -1 : Int(independent))
    emitJSONIfRequested()
    return 0
}

func cmdWarp(_ args: [String]) -> Int32 {
    let positional = args.filter { !$0.hasPrefix("--") }
    guard positional.count >= 2, let x = Double(positional[0]), let y = Double(positional[1]) else {
        FileHandle.standardError.write("用法: hf-probe warp <x> <y> [--post]\n".data(using: .utf8)!)
        return 2
    }
    let target = CGPoint(x: x, y: y)
    CGWarpMouseCursorPosition(target)
    CGAssociateMouseAndMouseCursorPosition(1)
    emit("WARPED_TO", String(format: "%.1f,%.1f", x, y))

    var posted = false
    if args.contains("--post") {
        // 合成一个 mouseMoved 事件，让目标进程的 CGEventTap 真的看到采样。
        // 这需要本进程自己持有「输入监控/辅助功能」权限（与被测 App 的授权相互独立）。
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: target, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
            posted = true
        }
    }
    emit("POSTED_MOUSE_MOVED", posted ? 1 : 0)
    spinRunLoop(0.05)
    let actual = CGEvent(source: nil)?.location ?? .zero
    emit("ACTUAL_MOUSE", String(format: "%.1f,%.1f", actual.x, actual.y))
    emit("WARP_OK", (abs(actual.x - x) < 2 && abs(actual.y - y) < 2) ? 1 : 0)
    emitJSONIfRequested()
    return 0
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 激活策略标定
// ═══════════════════════════════════════════════════════════════════════

/// 施加一个策略并**独立测量**结果。
/// before 的取法：先看目标窗口当前 z 序；再施加策略；z 序同步可读，frontmost 需要跑 RunLoop。
func calibrateOne(strategy: String,
                  pid: pid_t,
                  windowID: CGWindowID,
                  resetPID: pid_t?) -> [String: Any] {
    // 复位：把参照 App 切回前台，保证每种策略都从「目标不是前台」的同一初始状态出发
    if let resetPID, resetPID != pid, resetPID > 0 {
        _ = applyPublicActivate(pid: resetPID)
        spinRunLoop(0.5)
    }

    let zBefore = probeZIndexLayer0(of: windowID)
    let frontBefore = probeFrontmostPID()

    let result: StrategyResult
    switch strategy {
    case "skyLightNoRaise": result = applySkyLightNoRaise(pid: pid, windowID: windowID)
    case "axFrontmost":     result = applyAXFrontmost(pid: pid)
    case "publicActivate":  result = applyPublicActivate(pid: pid)
    case "controller":      result = applyController(pid: pid, windowID: windowID)
    default:
        return ["strategy": strategy, "error": "未知策略"]
    }

    // z 序同步可读；frontmost 必须跑 RunLoop
    let zImmediate = probeZIndexLayer0(of: windowID)
    spinRunLoop(0.5)
    let zAfter = probeZIndexLayer0(of: windowID)
    let frontAfter = probeFrontmostPID()

    let activated = frontAfter == pid
    var raised = false
    if let b = zBefore, let a = zAfter { raised = a < b }
    else if zBefore == nil && zAfter != nil { raised = true }   // 之前不在列表、现在出现了

    return [
        "strategy": strategy,
        "available": result.available,
        "code": Int(result.code),
        "note": result.note,
        "zBefore": zBefore ?? -1,
        "zAfter": zAfter ?? -1,
        "zImmediate": zImmediate ?? -1,
        "frontBefore": Int(frontBefore),
        "frontAfter": Int(frontAfter),
        "activated": activated,
        "raised": raised
    ]
}

/// 真实核心代码（FocusController）的端到端行为 —— 这一行才代表 App 实际会做的事
func applyController(pid: pid_t, windowID: CGWindowID) -> StrategyResult {
    guard let win = probeWindowList().first(where: { $0.id == windowID }) else {
        return StrategyResult(strategy: "controller", available: true, code: -1, note: "找不到窗口")
    }
    let ref = WindowRef(windowID: win.id, pid: win.pid, bounds: win.bounds, title: win.title,
                        appName: win.owner, bundleID: bundleID(win.pid),
                        layer: win.layer, isOnScreen: win.onScreen)
    let controller = FocusController(probe: WindowProbe())
    let outcome = controller.focus(window: ref, raise: false)
    controllerOutcome = outcome
    return StrategyResult(strategy: "controller", available: true, code: 0,
                          note: "实际策略=\(outcome.strategy.rawValue) didRaise=\(outcome.didRaise) "
                              + "didActivate=\(outcome.didActivate) error=\(outcome.error ?? "nil")")
}

func cmdFocus(_ args: [String]) -> Int32 {
    guard let pidRaw = value(of: "--pid", in: args), let pid = Int32(pidRaw) else {
        FileHandle.standardError.write("用法: hf-probe focus --pid <pid> [--window <id>] [--strategy skyLightNoRaise|axFrontmost|publicActivate|controller] [--reset-pid <pid>]\n".data(using: .utf8)!)
        return 2
    }
    let strategy = value(of: "--strategy", in: args) ?? "skyLightNoRaise"
    var windowID: CGWindowID
    if let raw = value(of: "--window", in: args), let wid = UInt32(raw) {
        windowID = wid
    } else if let top = topWindow(of: pid) {
        windowID = top.id
    } else {
        FileHandle.standardError.write("找不到 pid=\(pid) 的 layer-0 窗口\n".data(using: .utf8)!)
        return 4
    }
    var resetPID: pid_t? = nil
    if let raw = value(of: "--reset-pid", in: args), let rp = Int32(raw) { resetPID = rp }

    emit("TARGET_PID", Int(pid))
    emit("TARGET_APP", appName(pid))
    emit("TARGET_WINDOW", Int(windowID))
    let row = calibrateOne(strategy: strategy, pid: pid, windowID: windowID, resetPID: resetPID)
    for key in ["strategy", "available", "code", "note", "zBefore", "zAfter",
                "frontBefore", "frontAfter", "activated", "raised"] {
        emit(key, row[key] ?? "?")
    }
    if let outcome = controllerOutcome, strategy == "controller" {
        emit("CONTROLLER_STRATEGY", outcome.strategy.rawValue)
        emit("CONTROLLER_DID_RAISE", outcome.didRaise ? 1 : 0)
        emit("CONTROLLER_DID_ACTIVATE", outcome.didActivate ? 1 : 0)
        emit("CONTROLLER_ERROR", outcome.error ?? "nil")
    }
    emitJSONIfRequested()
    return 0
}

func cmdCalibrate(_ args: [String]) -> Int32 {
    guard let pidRaw = value(of: "--pid", in: args), let pid = Int32(pidRaw) else {
        FileHandle.standardError.write("用法: hf-probe calibrate --pid <pid> [--window <id>] [--reset-pid <pid>]\n".data(using: .utf8)!)
        return 2
    }
    var windowID: CGWindowID
    if let raw = value(of: "--window", in: args), let wid = UInt32(raw) {
        windowID = wid
    } else if let top = topWindow(of: pid) {
        windowID = top.id
    } else {
        FileHandle.standardError.write("找不到 pid=\(pid) 的 layer-0 窗口\n".data(using: .utf8)!)
        return 4
    }
    let startFront = probeFrontmostPID()
    var resetPID: pid_t? = nil
    if let raw = value(of: "--reset-pid", in: args), let rp = Int32(raw) {
        resetPID = rp
    } else if startFront != pid && startFront > 0 {
        resetPID = startFront     // 默认用探针启动时的前台 App 当参照
    }

    emit("TARGET_PID", Int(pid))
    emit("TARGET_APP", appName(pid))
    emit("TARGET_WINDOW", Int(windowID))
    emit("RESET_PID", resetPID.map { Int($0) } ?? -1)
    emit("RESET_APP", resetPID.map { appName($0) } ?? "-")
    emit("SKYLIGHT_AVAILABLE", SkyLightBridge.isAvailable ? 1 : 0)
    emit("GETPROCESSFORPID_AVAILABLE", SkyLightBridge.processForPID != nil ? 1 : 0)
    emit("AX_TRUSTED", Permissions.isAccessibilityTrusted ? 1 : 0)

    if startFront == pid {
        note("目标 App 当前已是前台：三种策略的差异可能测不出来，请先切到别的 App 再跑，或用 --reset-pid 指定参照 App")
    }

    var rows: [[String: Any]] = []
    for strategy in ["skyLightNoRaise", "axFrontmost", "publicActivate", "controller"] {
        let row = calibrateOne(strategy: strategy, pid: pid, windowID: windowID, resetPID: resetPID)
        rows.append(row)
        print("")
        print(String(format: "%-18@  可用=%@  码=%-6@ 置顶=%@  前台=%@  z %@→%@",
                     strategy as NSString,
                     ((row["available"] as? Bool) ?? false) ? "是" : "否",
                     "\(row["code"] ?? "?")" as NSString,
                     ((row["raised"] as? Bool) ?? false) ? "是" : "否",
                     ((row["activated"] as? Bool) ?? false) ? "是" : "否",
                     "\(row["zBefore"] ?? "?")" as NSString,
                     "\(row["zAfter"] ?? "?")" as NSString))
        print("                   说明：\(row["note"] ?? "")")
        emit("CAL_\(strategy)_RAISED", ((row["raised"] as? Bool) ?? false) ? 1 : 0)
        emit("CAL_\(strategy)_ACTIVATED", ((row["activated"] as? Bool) ?? false) ? 1 : 0)
        emit("CAL_\(strategy)_Z_BEFORE", row["zBefore"] ?? -1)
        emit("CAL_\(strategy)_Z_AFTER", row["zAfter"] ?? -1)
        emit("CAL_\(strategy)_CODE", row["code"] ?? -1)
    }
    jsonBag["calibration"] = rows
    emitJSONIfRequested()
    return 0
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 核心链路端到端（不需要任何系统权限）
// ═══════════════════════════════════════════════════════════════════════
//  把**真实**的 WindowProbe + FocusController + FocusEngine + MousePoller 接成
//  与 App 相同的链路（只少菜单栏 UI），然后把指针移到目标窗口中心停住，
//  看它是否真的把焦点切过去、以及有没有把窗口置顶。
//
//  为什么这条证据可信：整条链路没有替身 —— 采样是真的（轮询真实光标）、
//  命中测试是真的（WindowProbe）、私有 SkyLight 调用是真的、z 序测量是本文件
//  独立实现的。
//  为什么它**不能**替代完整端到端：菜单栏 App 本体没参与，权限门和菜单栏 UI 都没被覆盖。

final class PipelineRecorder: FocusDriverDelegate {
    var decisions: [FocusDecision] = []
    var lastOutcome: FocusOutcome?
    func focusDriver(_ driver: FocusDriver, didDecide decision: FocusDecision, outcome: FocusOutcome?) {
        decisions.append(decision)
        if let outcome { lastOutcome = outcome }
    }
    func focusDriver(_ driver: FocusDriver, didSurfaceWarning message: String) {
        print("# warning: \(message)")
    }
}

func cmdPipeline(_ args: [String]) -> Int32 {
    guard let pidRaw = value(of: "--pid", in: args), let pid = Int32(pidRaw) else {
        FileHandle.standardError.write("用法: hf-probe pipeline --pid <pid> [--window <id>] [--dwell 0.3] [--seconds 3]\n".data(using: .utf8)!)
        return 2
    }
    var windowID: CGWindowID
    if let raw = value(of: "--window", in: args), let wid = UInt32(raw) {
        windowID = wid
    } else if let top = topWindow(of: pid) {
        windowID = top.id
    } else {
        FileHandle.standardError.write("找不到 pid=\(pid) 的 layer-0 窗口\n".data(using: .utf8)!)
        return 4
    }
    let dwell = value(of: "--dwell", in: args).flatMap(Double.init) ?? 0.3
    let seconds = value(of: "--seconds", in: args).flatMap(Double.init) ?? 3.0

    guard let win = probeWindowList().first(where: { $0.id == windowID }) else {
        FileHandle.standardError.write("窗口 \(windowID) 不在当前 Space 的可见列表里\n".data(using: .utf8)!)
        return 4
    }
    let center = CGPoint(x: win.bounds.midX, y: win.bounds.midY)
    let origin = CGEvent(source: nil)?.location ?? .zero

    // 临时 defaults suite：绝不碰用户的 HoverFocus.* 偏好
    let suiteName = "hf-probe.pipeline.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsSettingsStore(defaults: defaults)
    store.settings.dwellDelay = dwell
    store.settings.cooldown = 0.25
    store.settings.mode = .focusOnly

    let probe = WindowProbe()
    let controller = FocusController(probe: probe)
    let monitor = MousePoller(interval: 1.0 / 60.0)
    let driver = FocusDriver(settings: store, probe: probe, actuator: controller,
                             monitor: monitor, tickInterval: 1.0 / 60.0)
    driver.permissionCheck = { true }   // 这条路径本来就不需要辅助功能权限

    let recorder = PipelineRecorder()
    driver.delegate = recorder

    let zBefore = probeZIndexLayer0(of: windowID)
    let frontBefore = probeFrontmostPID()
    emit("TARGET_PID", Int(pid))
    // 诊断：判定链路为什么不动（sameWindow 的判据是 probe.focusedWindow()）
    emit("TRACE_FOCUSED_WINDOW", probe.focusedWindow().map { Int($0.windowID) } ?? -1)
    emit("TRACE_FOCUSED_PID", probe.focusedWindow().map { Int($0.pid) } ?? -1)
    emit("TRACE_HIT_WINDOW", probe.window(atQuartzPoint: center).map { Int($0.windowID) } ?? -1)
    emit("TARGET_WINDOW", Int(windowID))
    emit("TARGET_CENTER", String(format: "%.1f,%.1f", center.x, center.y))
    emit("DWELL", dwell)
    emit("Z_BEFORE", zBefore ?? -1)
    emit("FRONT_BEFORE", Int(frontBefore))
    emit("HIT_TEST_MODE", probe.hitTestMode.rawValue)

    if frontBefore == pid {
        // 目标 App 本来就是前台：引擎第 12 步必然判 .sameWindow，这条用例不成立。
        // 明确报 SKIP —— 既不算通过，也不算产品失败。
        emit("PIPELINE_SKIPPED", 1)
        emit("PIPELINE_SKIP_REASON", "target_already_frontmost")
        emitJSONIfRequested()
        return 3
    }

    do {
        try driver.start()
    } catch {
        emit("PIPELINE_START_ERROR", "\(error)")
        return 1
    }

    CGWarpMouseCursorPosition(center)
    CGAssociateMouseAndMouseCursorPosition(1)

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    driver.stop()
    CGWarpMouseCursorPosition(origin)   // 恢复指针，不留副作用

    let zAfter = probeZIndexLayer0(of: windowID)
    let frontAfter = probeFrontmostPID()
    emit("TRACE_FOCUSED_WINDOW_END", probe.focusedWindow().map { Int($0.windowID) } ?? -1)
    emit("TRACE_FOCUSED_PID_END", probe.focusedWindow().map { Int($0.pid) } ?? -1)
    let stats = driver.engineStats

    emit("SAMPLES", stats.samples)
    emit("ACTIONS", stats.actions)
    emit("IGNORE_SAMEWINDOW", stats.count(of: .sameWindow))
    emit("IGNORE_COOLDOWN", stats.count(of: .cooldown))
    emit("IGNORE_NOWINDOW", stats.count(of: .noWindow))
    emit("IGNORE_OTHER", stats.count(of: .ownApp) + stats.count(of: .systemUI)
         + stats.count(of: .appHidden) + stats.count(of: .excludedApp)
         + stats.count(of: .nonNormalWindow) + stats.count(of: .notOnScreen)
         + stats.count(of: .inMenuBar) + stats.count(of: .disabled)
         + stats.count(of: .dragging) + stats.count(of: .modifiersHeld)
         + stats.count(of: .fullScreenBlocked))
    emit("Z_AFTER", zAfter ?? -1)
    emit("FRONT_AFTER", Int(frontAfter))
    emit("DECISIONS", recorder.decisions.count)
    emit("FOCUS_ACTIVATED", frontAfter == pid ? 1 : 0)

    let raised: Bool
    if let b = zBefore, let a = zAfter { raised = a < b }
    else if zBefore == nil && zAfter != nil { raised = true }
    else { raised = false }
    emit("FOCUS_RAISED", raised ? 1 : 0)

    if let outcome = recorder.lastOutcome {
        emit("OUTCOME_STRATEGY", outcome.strategy.rawValue)
        emit("OUTCOME_DID_RAISE", outcome.didRaise ? 1 : 0)
        emit("OUTCOME_DID_ACTIVATE", outcome.didActivate ? 1 : 0)
        emit("OUTCOME_ERROR", outcome.error ?? "nil")
    }
    let ok = (frontAfter == pid) && !raised
    emit("PIPELINE_SKIPPED", 0)
    emit("PIPELINE_OK", ok ? 1 : 0)
    emitJSONIfRequested()
    return ok ? 0 : 1
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - 入口
// ═══════════════════════════════════════════════════════════════════════

func value(of flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
jsonMode = rawArgs.contains("--json")

/// 第一个非 flag 参数是子命令；没有子命令时默认 check。
var rest = rawArgs
let command: String
if let first = rest.first, !first.hasPrefix("--") {
    command = first
    rest.removeFirst()
} else {
    command = "check"
}

let exitCode: Int32
switch command {
case "trust":     exitCode = cmdTrust()
case "check":     exitCode = cmdCheck()
case "list":      exitCode = cmdList()
case "hit":       exitCode = cmdHit(rest)
case "frontmost": exitCode = cmdFrontmost()
case "zorder":    exitCode = cmdZorder(rest)
case "focus":     exitCode = cmdFocus(rest)
case "calibrate": exitCode = cmdCalibrate(rest)
case "warp":      exitCode = cmdWarp(rest)
case "pipeline":  exitCode = cmdPipeline(rest)
case "help":
    print("""
    hf-probe — HoverFocus 诊断探针

      hf-probe check [--json]                 权限 / 坐标自洽 / 命中模式 自检
      hf-probe trust                          已授权 exit 0，未授权 exit 3
      hf-probe list                           按 z 序（前→后）列出屏幕上的窗口
      hf-probe hit [x y] [--json]             对 (x,y)（默认鼠标位置）做命中测试
      hf-probe frontmost                      当前前台 App（会跑 RunLoop 等它刷新）
      hf-probe zorder --window <id>           某窗口的 z 序
      hf-probe warp <x> <y> [--post]          移动指针（--post 额外合成 mouseMoved）
      hf-probe focus --pid <pid> [--window <id>] [--strategy S] [--reset-pid <pid>]
      hf-probe calibrate --pid <pid> [--window <id>] [--reset-pid <pid>]
      hf-probe pipeline --pid <pid> [--window <id>] [--dwell 0.3] [--seconds 3]

    策略 S：skyLightNoRaise | axFrontmost | publicActivate | controller
    """)
    exitCode = 0
default:
    FileHandle.standardError.write("未知命令：\(command)（用 hf-probe help 看用法）\n".data(using: .utf8)!)
    exitCode = 2
}
exit(exitCode)
