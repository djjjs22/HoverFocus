//  HoverFocus — 契约层单测
//  ─────────────────────────────────────────────────────────────────────────
//  测 Contracts.swift 里那些「冻结的、被多处依赖的」纯逻辑：
//  坐标转换、修饰键判定、窗口普通性、枚举 rawValue（UI 直接展示，不许漂移）。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

func runContractTests() {
    TestHarness.shared.beginSuite("契约层（Contracts.swift）")

    test("MouseSample.hasIntentModifier：cmd/opt/ctrl/shift 算，capsLock/fn 不算") {
        func sample(_ flags: CGEventFlags) -> MouseSample {
            MouseSample(point: .zero, timestamp: 0, isDragging: false, modifiers: flags)
        }
        expectEq(sample(.maskCommand).hasIntentModifier, true, "cmd")
        expectEq(sample(.maskAlternate).hasIntentModifier, true, "option")
        expectEq(sample(.maskControl).hasIntentModifier, true, "ctrl")
        expectEq(sample(.maskShift).hasIntentModifier, true, "shift")
        expectEq(sample([.maskCommand, .maskShift]).hasIntentModifier, true, "cmd+shift")
        expectEq(sample(.maskAlphaShift).hasIntentModifier, false, "capsLock 不算")
        expectEq(sample(.maskSecondaryFn).hasIntentModifier, false, "fn 不算")
        expectEq(sample([]).hasIntentModifier, false, "无修饰键")
        expectEq(sample([.maskAlphaShift, .maskSecondaryFn]).hasIntentModifier, false, "capsLock+fn 不算")
    }

    test("WindowRef.isNormalWindow：layer==0 且 isOnScreen 才算普通窗口") {
        expectEq(makeWindow(id: 1, layer: 0, onScreen: true).isNormalWindow, true, "layer0+onScreen")
        expectEq(makeWindow(id: 1, layer: 0, onScreen: false).isNormalWindow, false, "不在屏上")
        expectEq(makeWindow(id: 1, layer: 1, onScreen: true).isNormalWindow, false, "layer1")
        expectEq(makeWindow(id: 1, layer: -1, onScreen: true).isNormalWindow, false, "layer-1")
    }

    test("Settings.sanitized：dwell 钳到 [0,1]，cooldown 钳到 [0.06,1]") {
        var s = Settings.default
        s.dwellDelay = -5
        expectEq(s.sanitized().dwellDelay, 0, "负 dwell 钳到 0")
        s.dwellDelay = 99
        expectEq(s.sanitized().dwellDelay, 1.0, "过大 dwell 钳到 1")
        s.cooldown = -1
        expectEq(s.sanitized().cooldown, 0.06, "负 cooldown 钳到下限 0.06")
        s.cooldown = 0
        expectEq(s.sanitized().cooldown, 0.06,
                 "cooldown=0 也抬到下限 0.06（用于盖过 WindowProbe.focusedWindow 的 50ms 缓存）")
        s.cooldown = 3
        expectEq(s.sanitized().cooldown, 1.0, "过大 cooldown 钳到 1")
        s.dwellDelay = 0.12
        s.cooldown = 0.15
        expectEq(s.sanitized(), s, "合法值原样返回")
    }

    test("Settings.default 的默认值（用户可见行为）") {
        let d = Settings.default
        expectEq(d.enabled, true, "默认开启")
        expectEq(d.mode, .focusOnly, "默认只切焦点不置顶")
        expectEq(d.dwellDelay, 0.12, "默认 dwell 0.12s")
        expectEq(d.cooldown, 0.15, "默认 cooldown 0.15s")
        expectEq(d.requireNoModifiers, true, "默认修饰键守卫开")
        expectEq(d.suppressWhileDragging, true, "默认拖拽守卫开")
        expectEq(d.respectFullScreen, true, "默认全屏守卫开")
        expectEq(d.excludedBundleIDs.isEmpty, true, "默认排除名单为空")
    }

    test("FocusIgnoreReason 的 rawValue 稳定（诊断面板直接展示）") {
        let expected: [String] = [
            "disabled", "dragging", "modifiersHeld", "inMenuBar", "noWindow",
            "ownApp", "systemUI", "appHidden", "nonNormalWindow", "excludedApp",
            "sameWindow", "cooldown", "fullScreenBlocked", "notOnScreen"
        ]
        let actual = [
            FocusIgnoreReason.disabled, .dragging, .modifiersHeld, .inMenuBar, .noWindow,
            .ownApp, .systemUI, .appHidden, .nonNormalWindow, .excludedApp,
            .sameWindow, .cooldown, .fullScreenBlocked, .notOnScreen
        ].map { $0.rawValue }
        expectEq(actual, expected, "14 个忽略原因的 rawValue")
        expectEq(Set(actual).count, 14, "rawValue 不重复")
    }

    test("FocusStrategy / ActivationMode 的 rawValue 与 displayName") {
        expectEq(FocusStrategy.allCases.map { $0.rawValue },
                 ["skyLightNoRaise", "axFrontmost", "publicActivate"], "策略 rawValue")
        expectEq(ActivationMode.allCases.map { $0.rawValue },
                 ["focusOnly", "focusAndRaise"], "模式 rawValue")
        expectEq(ActivationMode.focusOnly.displayName, "只切焦点，不置顶", "默认模式文案")
    }

    test("CoordinateSpace：Cocoa ↔ Quartz 是同一个翻转且互为逆运算") {
        let h = CoordinateSpace.primaryScreenHeight
        let cocoa = CGPoint(x: 10, y: 20)
        let quartz = CoordinateSpace.cocoaToQuartz(cocoa)
        expectEq(quartz, CGPoint(x: 10, y: h - 20), "cocoa→quartz 按主屏高度翻转 y")
        expectEq(CoordinateSpace.quartzToCocoa(quartz), cocoa, "往返必须回到原点")
    }

    test("CoordinateSpace.quartzRect(fromCocoa:)：矩形翻转用的是左下角 + 高度") {
        let h = CoordinateSpace.primaryScreenHeight
        let r = NSRect(x: 5, y: 30, width: 100, height: 50)
        let q = CoordinateSpace.quartzRect(fromCocoa: r)
        expectEq(q, CGRect(x: 5, y: h - 30 - 50, width: 100, height: 50), "翻转后的矩形")
    }

    test("CoordinateSpace：屏幕中央不在菜单栏，主屏顶边在菜单栏") {
        let h = CoordinateSpace.primaryScreenHeight
        guard h > 200 else {
            skipTest("无头环境（NSScreen 为空），坐标区域判定无意义")
            return
        }
        expectEq(CoordinateSpace.isInMenuBarRegion(CGPoint(x: 200, y: h * 0.5)), false,
                 "屏幕中央不是菜单栏")
        expectEq(CoordinateSpace.isInMenuBarRegion(menuBarPoint()), true,
                 "主屏顶边 y=1 是菜单栏")
    }

    test("EngineStats.count(of:)：缺省为 0，且按 rawValue 记账") {
        var st = EngineStats()
        expectEq(st.count(of: .disabled), 0, "空统计")
        st.ignoreCounts["disabled"] = 3
        expectEq(st.count(of: .disabled), 3, "按 rawValue 取计数")
    }
}
