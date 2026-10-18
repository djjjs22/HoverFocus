//  HoverFocus — FocusEngine 16 步判定顺序测试
//  ─────────────────────────────────────────────────────────────────────────
//  判定顺序契约见 Sources/HoverFocusCore/Contracts.swift 顶部注释。
//  每个用例用 steps:[...] 标注覆盖的步骤号，末尾的覆盖矩阵会检查 16 步无遗漏。
//
//  约定：所有时刻都是**绝对**的单调时钟秒数（Scenario.handle(at:) 会把时钟拨到该时刻）。
//  dwell / cooldown 用二进制可精确表示的 0.5 / 0.25，避免浮点误差污染边界断言。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

private let PID_A: pid_t = 1000
private let PID_B: pid_t = 2000

func runStepTests() {
    TestHarness.shared.beginSuite("FocusEngine 16 步判定顺序")

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 1：!enabled → .disabled
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 1：总开关关闭 → .disabled", steps: [1]) {
        let s = Scenario(settings: settings(enabled: false, dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        expectIgnore(s.handle(at: 0), .disabled, "enabled=false")
    }

    test("步骤 1 优先级最高：关闭时拖拽+修饰键+菜单栏也还是 .disabled", steps: [1]) {
        let s = Scenario(settings: settings(enabled: false, dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        let d = s.handle(at: 0, point: menuBarPoint(), dragging: true, modifiers: .maskCommand)
        expectIgnore(d, .disabled, "步骤 1 必须先于 2/3/4")
    }

    test("步骤 1：关闭时不产生任何动作", steps: [1]) {
        let s = Scenario(settings: settings(enabled: false, dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        for t in stride(from: 0.0, through: 2.0, by: 0.1) { _ = s.handle(at: t) }
        expectEq(s.actuator.calls.count, 0, "关闭状态下 actuator 调用次数")
        expectEq(s.engine.stats.actions, 0, "stats.actions")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 2：isDragging && suppressWhileDragging → .dragging
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 2：拖拽中 → .dragging", steps: [2]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        expectIgnore(s.handle(at: 0, dragging: true), .dragging, "isDragging=true")
    }

    test("步骤 2 优先于 3/4：拖拽+修饰键+菜单栏 → .dragging", steps: [2]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        let d = s.handle(at: 0, point: menuBarPoint(), dragging: true, modifiers: .maskCommand)
        expectIgnore(d, .dragging, "步骤 2 必须先于 3/4")
    }

    test("步骤 2：suppressWhileDragging=false 时拖拽不压制", steps: [2]) {
        let s = Scenario(settings: settings(dwell: 0, suppressWhileDragging: false))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        expectAct(s.handle(at: 0, dragging: true), windowID: 1, pid: PID_A, raise: false,
                  "关掉拖拽守卫后应当直接动作")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 3：modifiers && requireNoModifiers → .modifiersHeld
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 3：按住 cmd → .modifiersHeld", steps: [3]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        expectIgnore(s.handle(at: 0, modifiers: .maskCommand), .modifiersHeld, "cmd 按下")
    }

    test("步骤 3：shift / ctrl / option 任一都算意图修饰键", steps: [3]) {
        for (name, flag) in [("shift", CGEventFlags.maskShift),
                             ("ctrl", CGEventFlags.maskControl),
                             ("option", CGEventFlags.maskAlternate)] {
            let s = Scenario(settings: settings(dwell: 0))
            s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
            expectIgnore(s.handle(at: 0, modifiers: flag), .modifiersHeld, "\(name) 按下")
        }
    }

    test("步骤 3：capsLock / fn 不算意图修饰键（不压制）", steps: [3]) {
        for (name, flag) in [("capsLock", CGEventFlags.maskAlphaShift),
                             ("fn", CGEventFlags.maskSecondaryFn)] {
            let s = Scenario(settings: settings(dwell: 0))
            s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
            expectAct(s.handle(at: 0, modifiers: flag), windowID: 1, pid: PID_A, raise: false,
                      "\(name) 不该触发修饰键守卫")
        }
    }

    test("步骤 3：requireNoModifiers=false 时不压制", steps: [3]) {
        let s = Scenario(settings: settings(dwell: 0, requireNoModifiers: false))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        expectAct(s.handle(at: 0, modifiers: .maskCommand), windowID: 1, pid: PID_A, raise: false,
                  "关掉修饰键守卫后应当动作")
    }

    test("步骤 3 优先于 4：修饰键+菜单栏 → .modifiersHeld", steps: [3]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        let d = s.handle(at: 0, point: menuBarPoint(), modifiers: .maskCommand)
        expectIgnore(d, .modifiersHeld, "步骤 3 必须先于 4")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 4：指针在菜单栏 → .inMenuBar
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 4：指针在菜单栏 → .inMenuBar", steps: [4]) {
        guard menuBarIsTestable() else {
            skipTest("本机菜单栏被自动隐藏，构造不出菜单栏坐标（CoordinateSpace.isInMenuBarRegion 恒 false）")
            return
        }
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        expectIgnore(s.handle(at: 0, point: menuBarPoint()), .inMenuBar, "指针 y=1（主屏顶边）")
    }

    test("步骤 4 优先于 5：菜单栏上即使命中窗口也不动作", steps: [4]) {
        guard menuBarIsTestable() else {
            skipTest("本机菜单栏被自动隐藏，构造不出菜单栏坐标")
            return
        }
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        let d = s.handle(at: 0, point: menuBarPoint())
        expectIgnore(d, .inMenuBar, "步骤 4 必须先于 5")
        expectEq(s.actuator.calls.count, 0, "菜单栏上不许调用 actuator")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 5：window(at:) == nil → .noWindow
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 5：指针下没有窗口 → .noWindow", steps: [5]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = nil
        expectIgnore(s.handle(at: 0), .noWindow, "桌面/空白处")
    }

    test("步骤 5：window(at:) 收到的是未被翻转的采样点", steps: [5]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = nil
        let p = CGPoint(x: 123, y: safePoint().y)
        _ = s.handle(at: 0, point: p)
        expectTrue(s.probe.windowAtCalls.count >= 1, "必须调用 window(atQuartzPoint:)")
        if let got = s.probe.windowAtCalls.last {
            expectEq(got, p, "传给 probe 的点（Quartz 坐标必须原样透传，不许自己翻转）")
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 6：非普通窗口 / 不在当前 Space
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 6：layer != 0 的浮层 → .nonNormalWindow", steps: [6]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 7, pid: PID_A, layer: 3, onScreen: true)
        expectIgnore(s.handle(at: 0), .nonNormalWindow, "layer=3（浮层/Dock 层）")
    }

    test("步骤 6：不在当前 Space（isOnScreen=false）→ .notOnScreen", steps: [6]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 8, pid: PID_A, layer: 0, onScreen: false)
        expectIgnore(s.handle(at: 0), .notOnScreen, "isOnScreen=false（另一个 Space）")
    }

    test("步骤 6 优先于 7：非普通窗口即使属于自己 → .nonNormalWindow", steps: [6]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 9, pid: s.probe.own, layer: 1, onScreen: true)
        expectIgnore(s.handle(at: 0), .nonNormalWindow, "步骤 6 必须先于 7")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 7：pid == ownPID → .ownApp
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 7：命中自己的窗口 → .ownApp", steps: [7]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 2, pid: s.probe.own)
        expectIgnore(s.handle(at: 0), .ownApp, "pid == ownPID")
    }

    test("步骤 7 优先于 8：自己的 pid 同时在系统 UI 名单里 → .ownApp", steps: [7]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.systemUIPIDs = [s.probe.own]
        s.probe.windowAtPoint = makeWindow(id: 2, pid: s.probe.own)
        expectIgnore(s.handle(at: 0), .ownApp, "步骤 7 必须先于 8")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 8：isSystemUI(pid) → .systemUI
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 8：系统 UI 进程 → .systemUI", steps: [8]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.systemUIPIDs = [PID_B]
        s.probe.windowAtPoint = makeWindow(id: 3, pid: PID_B)
        expectIgnore(s.handle(at: 0), .systemUI, "Dock / 控制中心等")
    }

    test("步骤 8 优先于 9：系统 UI 且被隐藏 → .systemUI", steps: [8]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.systemUIPIDs = [PID_B]
        s.probe.hiddenPIDs = [PID_B]
        s.probe.windowAtPoint = makeWindow(id: 3, pid: PID_B)
        expectIgnore(s.handle(at: 0), .systemUI, "步骤 8 必须先于 9")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 9：isAppHidden(pid) → .appHidden
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 9：目标 App 被 cmd-H 隐藏 → .appHidden", steps: [9]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.hiddenPIDs = [PID_A]
        s.probe.windowAtPoint = makeWindow(id: 4, pid: PID_A)
        expectIgnore(s.handle(at: 0), .appHidden, "cmd-H 隐藏的 App")
    }

    test("步骤 9 优先于 10：隐藏且命中排除名单 → .appHidden", steps: [9]) {
        let s = Scenario(settings: settings(dwell: 0, excludedBundleIDs: ["com.test.app"]))
        s.probe.hiddenPIDs = [PID_A]
        s.probe.windowAtPoint = makeWindow(id: 4, pid: PID_A, bundleID: "com.test.app")
        expectIgnore(s.handle(at: 0), .appHidden, "步骤 9 必须先于 10")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 10：命中排除名单 → .excludedApp
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 10：bundleID 命中排除名单 → .excludedApp", steps: [10]) {
        let s = Scenario(settings: settings(dwell: 0, excludedBundleIDs: ["com.bad.app"]))
        s.probe.windowAtPoint = makeWindow(id: 5, pid: PID_A, bundleID: "com.bad.app")
        expectIgnore(s.handle(at: 0), .excludedApp, "bundleID 在主键名单里")
    }

    test("步骤 10：bundleID 缺失时用 appName 兜底 → .excludedApp", steps: [10]) {
        let s = Scenario(settings: settings(dwell: 0, excludedAppNames: ["坏应用"]))
        s.probe.windowAtPoint = makeWindow(id: 5, pid: PID_A, appName: "坏应用", bundleID: nil)
        expectIgnore(s.handle(at: 0), .excludedApp, "appName 兜底命中")
    }

    test("步骤 10：未命中名单 → 继续走 dwell 流程", steps: [10]) {
        let s = Scenario(settings: settings(dwell: 0.5, excludedBundleIDs: ["com.other.app"]))
        s.probe.windowAtPoint = makeWindow(id: 5, pid: PID_A, bundleID: "com.test.app")
        expectPending(s.handle(at: 0), windowID: 5, remaining: 0.5, "未被排除，应进入计时")
    }

    test("步骤 10 优先于 11：排除 App 且全屏 → .excludedApp", steps: [10]) {
        let s = Scenario(settings: settings(dwell: 0, excludedBundleIDs: ["com.bad.app"]))
        s.probe.fullScreen = true
        s.probe.windowAtPoint = makeWindow(id: 5, pid: PID_A, bundleID: "com.bad.app")
        expectIgnore(s.handle(at: 0), .excludedApp, "步骤 10 必须先于 11")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 11：前台 App 全屏 && respectFullScreen → .fullScreenBlocked
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 11：前台全屏 + respectFullScreen → .fullScreenBlocked", steps: [11]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.fullScreen = true
        s.probe.windowAtPoint = makeWindow(id: 6, pid: PID_A)
        expectIgnore(s.handle(at: 0), .fullScreenBlocked, "全屏守卫")
    }

    test("步骤 11：respectFullScreen=false 时全屏不阻挡", steps: [11]) {
        let s = Scenario(settings: settings(dwell: 0, respectFullScreen: false))
        s.probe.fullScreen = true
        s.probe.windowAtPoint = makeWindow(id: 6, pid: PID_A)
        expectAct(s.handle(at: 0), windowID: 6, pid: PID_A, raise: false, "关掉全屏守卫后应当动作")
    }

    test("步骤 11 优先于 12：全屏 + 目标就是焦点窗口 → .fullScreenBlocked", steps: [11]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.fullScreen = true
        let w = makeWindow(id: 6, pid: PID_A)
        s.probe.windowAtPoint = w
        s.probe.focused = w
        expectIgnore(s.handle(at: 0), .fullScreenBlocked, "步骤 11 必须先于 12")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 12：windowID == focusedWindow()?.windowID → .sameWindow
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 12：目标就是当前焦点窗口 → .sameWindow", steps: [12]) {
        let s = Scenario(settings: settings(dwell: 0))
        let w = makeWindow(id: 10, pid: PID_A)
        s.probe.windowAtPoint = w
        s.probe.focused = w
        expectIgnore(s.handle(at: 0), .sameWindow, "已聚焦窗口上悬停")
    }

    test("步骤 12：focusedWindow() 为 nil 时不误判 sameWindow", steps: [12]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 10, pid: PID_A)
        s.probe.focused = nil
        expectAct(s.handle(at: 0), windowID: 10, pid: PID_A, raise: false, "拿不到焦点窗口时应正常动作")
    }

    test("步骤 12 优先于 13：刚动作完又悬停在焦点窗口 → .sameWindow（不是 .cooldown）", steps: [12]) {
        let s = Scenario(settings: settings(dwell: 0, cooldown: 0.25))
        let w = makeWindow(id: 10, pid: PID_A)
        s.probe.windowAtPoint = w
        s.probe.focused = nil
        expectAct(s.handle(at: 0), windowID: 10, pid: PID_A, raise: false, "先动作一次")
        s.probe.focused = w   // 动作生效后，该窗口成为焦点窗口
        expectIgnore(s.handle(at: 0.1), .sameWindow, "冷却期内但已是焦点窗口 → 步骤 12 必须先于 13")
    }

    test("步骤 12 优先于 14：同一窗口长时间悬停永不动作，也不启动计时", steps: [12]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        let w = makeWindow(id: 10, pid: PID_A)
        s.probe.windowAtPoint = w
        s.probe.focused = w
        for t in stride(from: 0.0, through: 3.0, by: 0.5) {
            expectIgnore(s.handle(at: t), .sameWindow, "t=\(t) 仍是 .sameWindow")
        }
        expectEq(s.actuator.calls.count, 0, "焦点窗口上悬停不许产生动作（AutoFocus 抖动主因）")
        expectEq(s.engine.pendingWindowID, nil, "第 12 步命中时不该进入第 14 步的计时")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 13：距上次动作 < cooldown → .cooldown
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 13：动作后冷却期内 → .cooldown", steps: [13]) {
        let s = Scenario(settings: settings(dwell: 0, cooldown: 0.25))
        let a = makeWindow(id: 11, pid: PID_A)
        s.probe.windowAtPoint = a
        expectAct(s.handle(at: 0), windowID: 11, pid: PID_A, raise: false, "先动作一次")
        s.perform(FocusAction(windowID: 11, pid: PID_A, raise: false))
        s.probe.focused = a
        s.probe.windowAtPoint = makeWindow(id: 12, pid: PID_B)
        expectIgnore(s.handle(at: 0.1), .cooldown, "距上次动作 0.1s < 0.25s")
    }

    test("步骤 13 边界：恰好等于 cooldown 时不再压制", steps: [13]) {
        let s = Scenario(settings: settings(dwell: 0, cooldown: 0.25))
        s.probe.windowAtPoint = makeWindow(id: 11, pid: PID_A)
        expectAct(s.handle(at: 0), windowID: 11, pid: PID_A, raise: false, "先动作一次")
        s.perform(FocusAction(windowID: 11, pid: PID_A, raise: false))
        s.store.update(settings(dwell: 0.5, cooldown: 0.25))   // 后面要断言 pending 的剩余量
        s.probe.windowAtPoint = makeWindow(id: 12, pid: PID_B)
        expectPending(s.handle(at: 0.25), windowID: 12, remaining: 0.5, "0.25 == cooldown，不该再压制")
    }

    test("步骤 13 优先于 14：冷却期内换到新窗口也不启动计时", steps: [13]) {
        let s = Scenario(settings: settings(dwell: 0, cooldown: 0.25))
        s.probe.windowAtPoint = makeWindow(id: 11, pid: PID_A)
        expectAct(s.handle(at: 0), windowID: 11, pid: PID_A, raise: false, "先动作一次")
        s.perform(FocusAction(windowID: 11, pid: PID_A, raise: false))
        s.store.update(settings(dwell: 0.5, cooldown: 0.25))
        s.probe.windowAtPoint = makeWindow(id: 12, pid: PID_B)
        expectIgnore(s.handle(at: 0.1), .cooldown, "冷却期内")
        // 若计时在冷却期内被启动，0.25 时刻的剩余会小于满额
        expectPending(s.handle(at: 0.25), windowID: 12, remaining: 0.5,
                      "冷却期不得提前开始 dwell 计时")
    }

    test("步骤 13：cooldown=0 被契约抬到下限 0.06（保护 focusedWindow 的 50ms 缓存）", steps: [13]) {
        let s = Scenario(settings: settings(dwell: 0, cooldown: 0))
        s.probe.windowAtPoint = makeWindow(id: 11, pid: PID_A)
        expectAct(s.handle(at: 0), windowID: 11, pid: PID_A, raise: false, "先动作一次")
        s.perform(FocusAction(windowID: 11, pid: PID_A, raise: false))
        s.store.update(settings(dwell: 0.5, cooldown: 0))
        s.probe.windowAtPoint = makeWindow(id: 12, pid: PID_B)
        expectIgnore(s.handle(at: 0.05), .cooldown, "0.05 < 有效下限 0.06，仍要压制")
        expectPending(s.handle(at: 0.06), windowID: 12, remaining: 0.5,
                      "0.06 == 有效下限，不再压制")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 14：目标窗口 != 正在计时的窗口 → 重置计时，返回 .pending(dwell)
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 14：首次悬停新窗口 → .pending(remaining = dwell)", steps: [14]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectPending(s.handle(at: 0), windowID: 20, remaining: 0.5, "首次悬停给满额 dwell")
    }

    test("步骤 14：换到另一个窗口 → 计时重置为满额", steps: [14]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectPending(s.handle(at: 0), windowID: 20, remaining: 0.5, "先悬停 A")
        s.probe.windowAtPoint = makeWindow(id: 21, pid: PID_B)
        expectPending(s.handle(at: 0.4), windowID: 21, remaining: 0.5,
                      "中途换窗口必须重置计时（否则 0.1s 后就误触发）")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 15：now - 计时起点 < dwell → .pending(剩余)
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 15：未到点 → .pending(剩余 = dwell - 已过)", steps: [15]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectPending(s.handle(at: 0), windowID: 20, remaining: 0.5, "t=0 开始计时")
        expectPending(s.handle(at: 0.2), windowID: 20, remaining: 0.3, "t=0.2 剩余 0.3")
        expectPending(s.handle(at: 0.4), windowID: 20, remaining: 0.1, "t=0.4 剩余 0.1")
        expectEq(s.actuator.calls.count, 0, "未到点不许动作")
    }

    test("步骤 15：中途换窗口再回来 → 计时从零重算", steps: [15]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        let a = makeWindow(id: 20, pid: PID_A)
        s.probe.windowAtPoint = a
        expectPending(s.handle(at: 0), windowID: 20, remaining: 0.5, "悬停 A")
        s.probe.windowAtPoint = makeWindow(id: 21, pid: PID_B)
        expectPending(s.handle(at: 0.3), windowID: 21, remaining: 0.5, "换到 B 重置")
        s.probe.windowAtPoint = a
        expectPending(s.handle(at: 0.6), windowID: 20, remaining: 0.5, "回到 A 也要重新计满额")
    }

    test("步骤 14/15：鼠标静止时靠 tick 推进 dwell", steps: [14, 15]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectPending(s.handle(at: 0), windowID: 20, remaining: 0.5, "t=0 采样开始计时")
        expectPending(s.tick(at: 0.2), windowID: 20, remaining: 0.3, "静止时 tick 推进到 0.2")
        expectPending(s.tick(at: 0.4), windowID: 20, remaining: 0.1, "静止时 tick 推进到 0.4")
        expectEq(s.actuator.calls.count, 0, "tick 未到点不许动作")
    }

    // ═══════════════════════════════════════════════════════════════════
    // 步骤 16：否则 → .act(...)
    // ═══════════════════════════════════════════════════════════════════
    test("步骤 16：dwell 到点 → .act", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectPending(s.handle(at: 0), windowID: 20, remaining: 0.5, "开始计时")
        expectAct(s.handle(at: 0.5), windowID: 20, pid: PID_A, raise: false, "t=0.5 到点动作")
    }

    test("步骤 16 边界：now - start 恰好 == dwell 时动作（>=）", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        _ = s.handle(at: 0)
        expectAct(s.handle(at: 0.5), windowID: 20, pid: PID_A, raise: false, "恰好到点必须动作")
    }

    test("步骤 16：dwell=0 时首个采样立刻动作", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectAct(s.handle(at: 0), windowID: 20, pid: PID_A, raise: false, "dwell=0")
    }

    test("步骤 16：focusOnly 模式 → raise=false；focusAndRaise → raise=true", steps: [16]) {
        let s1 = Scenario(settings: settings(mode: .focusOnly, dwell: 0))
        s1.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectAct(s1.handle(at: 0), windowID: 20, pid: PID_A, raise: false, "focusOnly")

        let s2 = Scenario(settings: settings(mode: .focusAndRaise, dwell: 0))
        s2.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        expectAct(s2.handle(at: 0), windowID: 20, pid: PID_A, raise: true, "focusAndRaise")
    }

    test("步骤 16：tick 到点 → .act", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        _ = s.handle(at: 0)
        expectAct(s.tick(at: 0.5), windowID: 20, pid: PID_A, raise: false, "静止鼠标 tick 到点")
    }

    test("步骤 16：到点后再次采样，未执行 perform 时仍会给出 .act", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0.5, cooldown: 0.25))
        s.probe.windowAtPoint = makeWindow(id: 20, pid: PID_A)
        _ = s.handle(at: 0)
        expectAct(s.handle(at: 0.5), windowID: 20, pid: PID_A, raise: false, "第一次到点")
        expectAct(s.handle(at: 0.6), windowID: 20, pid: PID_A, raise: false,
                  "未执行 perform 时冷却未启动，仍应给出 .act（由 driver 决定是否去重）")
    }

    // ═══════════════════════════════════════════════════════════════════
    // tick 的守卫（拖拽/修饰键期间静止也不能动作）
    // ═══════════════════════════════════════════════════════════════════
    test("tick 守卫：拖拽/修饰键期间静止，tick 不许动作", steps: [2, 3]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 30, pid: PID_A)
        _ = s.handle(at: 0, dragging: true, modifiers: .maskCommand)
        expectNotAct(s.tick(at: 1.0), "拖拽+修饰键期间 tick 不许动作")
    }

    test("tick 边界：还没采样过时 tick → .noWindow、不许崩", steps: [5, 14]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 30, pid: PID_A)
        expectIgnore(s.tick(at: 1.0), .noWindow, "无采样历史时 tick 按无窗口处理")
        expectEq(s.engine.stats.samples, 0, "tick 不该增加 stats.samples")
        expectEq(s.actuator.calls.count, 0, "无采样历史时不许动作")
    }

    // ═══════════════════════════════════════════════════════════════════
    // perform()：唯一有副作用的方法
    // ═══════════════════════════════════════════════════════════════════
    test("perform：把决策交给 actuator 并更新 stats / 冷却基准", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0))
        let w = makeWindow(id: 40, pid: PID_A)
        s.probe.windowAtPoint = w
        expectAct(s.handle(at: 0), windowID: 40, pid: PID_A, raise: false, "到点动作")
        let outcome = s.perform(FocusAction(windowID: 40, pid: PID_A, raise: false))
        expectEq(s.actuator.calls.count, 1, "actuator 调用次数")
        expectEq(s.actuator.calls.first?.window.windowID, 40, "actuator 收到的 windowID")
        expectEq(s.actuator.calls.first?.raise, false, "actuator 收到的 raise")
        expectEq(s.engine.stats.actions, 1, "stats.actions")
        expectEq(s.engine.stats.lastActionAt, 0, "stats.lastActionAt")
        expectEq(s.engine.currentCooldownBaseline(), 0, "冷却基准时刻")
        expectEq(outcome.didActivate, true, "outcome.didActivate 透传")
    }

    test("perform：actuator 报 didRaise 时如实透传（不伪装成不置顶）", steps: [16]) {
        let s = Scenario(settings: settings(mode: .focusOnly, dwell: 0))
        s.actuator.didRaiseToReport = true
        s.actuator.strategyToReport = .publicActivate
        s.probe.windowAtPoint = makeWindow(id: 40, pid: PID_A)
        _ = s.handle(at: 0)
        let outcome = s.perform(FocusAction(windowID: 40, pid: PID_A, raise: false))
        expectEq(outcome.didRaise, true, "actuator 说置顶了就必须报 true")
        expectEq(outcome.strategy, .publicActivate, "实际策略透传")
        expectEq(s.engine.lastOutcome?.didRaise, true, "lastOutcome 记账")
    }

    test("perform：拿不到 WindowRef 时必须报 error、didActivate=false、不计冷却/统计", steps: [16]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = nil     // probe 已失效
        let outcome = s.perform(FocusAction(windowID: 999, pid: PID_A, raise: false))
        expectTrue(outcome.error != nil, "拿不到窗口时必须给出 error，实际 error=\(String(describing: outcome.error))")
        expectEq(outcome.didActivate, false, "拿不到窗口时不许报 didActivate=true")
        expectEq(s.engine.stats.actions, 0, "失败不计入 stats.actions")
        expectEq(s.engine.currentCooldownBaseline(), nil, "失败不建立冷却基准")
    }

    test("stats：采样数 / 忽略计数 / lastDecision 记账", steps: [1]) {
        let s = Scenario(settings: settings(enabled: false, dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 1, pid: PID_A)
        _ = s.handle(at: 0)
        _ = s.handle(at: 0.1)
        _ = s.handle(at: 0.2)
        expectEq(s.engine.stats.samples, 3, "stats.samples")
        expectEq(s.engine.stats.count(of: .disabled), 3, "disabled 忽略计数")
        if case .ignore(let r)? = s.engine.lastDecision {
            expectEq(r, .disabled, "lastDecision")
        } else {
            expectTrue(false, "lastDecision 应为 .ignore(.disabled)，实际 \(String(describing: s.engine.lastDecision))")
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // 性能预算（纯逻辑替身下）
    // ═══════════════════════════════════════════════════════════════════
    test("性能：handle 在替身下平均耗时 < 1ms（契约预算）", steps: [15]) {
        let s = Scenario(settings: settings(dwell: 10))
        s.probe.windowAtPoint = makeWindow(id: 50, pid: PID_A)
        let n = 10_000
        let t0 = ProcessInfo.processInfo.systemUptime
        for i in 0..<n { _ = s.handle(at: Double(i) * 0.0001) }
        let dt = ProcessInfo.processInfo.systemUptime - t0
        let avgMs = dt / Double(n) * 1000
        expectTrue(avgMs < 1.0, String(format: "handle 平均 %.4f ms（预算 1ms；本项不含真实 AX 命中测试）", avgMs))
    }
}
