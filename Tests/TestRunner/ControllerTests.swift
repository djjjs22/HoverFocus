//  HoverFocus — FocusController / SettingsStore 单测
//  ─────────────────────────────────────────────────────────────────────────
//  FocusController 是「只切焦点不置顶」这条需求的执行端，而它唯一诚实的输出
//  就是 didRaise（由 z 序前后对比**实测**得出）。本机没有辅助功能权限，
//  所以这里只测「测量逻辑本身」：z 序怎么变 → didRaise 怎么报。
//
//  ⚠️ 全部用**不存在的 pid**（999999）：SkyLight / NSRunningApplication 都不会
//     真的切前台，测试不会搅乱用户的窗口。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics
import AppKit

private let GHOST_PID: pid_t = 999_999

func runControllerTests() {
    TestHarness.shared.beginSuite("FocusController（didRaise 实测口径）")

    test("FocusController：z 序 after < before → didRaise=true（真的置顶了）") {
        let probe = FakeProbe()
        let w = makeWindow(id: 777, pid: GHOST_PID, bundleID: "com.ghost.app")
        probe.zOrderSequences[777] = [2, 0, 0, 0, 0]
        probe.focused = w
        let outcome = FocusController(probe: probe).focus(window: w, raise: true)
        expectEq(outcome.strategy, .publicActivate, "raise=true 走公开 activate")
        expectEq(outcome.didRaise, true, "z 2→0 算置顶")
        expectEq(outcome.didActivate, true, "probe.focusedWindow() 报目标已在前台")
        expectEq(outcome.window, w, "outcome.window 必须原样带回")
    }

    test("FocusController：z 序没变 → didRaise=false（真·没置顶）") {
        let probe = FakeProbe()
        let w = makeWindow(id: 777, pid: GHOST_PID)
        probe.zOrderSequences[777] = [2, 2, 2, 2, 2, 2]
        probe.focused = w
        let outcome = FocusController(probe: probe).focus(window: w, raise: true)
        expectEq(outcome.didRaise, false, "z 2→2 不算置顶")
    }

    test("FocusController：z 序读不到 → 保守 didRaise=true（绝不假装没置顶）") {
        let probe = FakeProbe()
        let w = makeWindow(id: 777, pid: GHOST_PID)
        // zOrders 空 + 无序列 → focus 前后都是 nil（跨 Space / CGWindowList 查不到）
        probe.focused = w
        let outcome = FocusController(probe: probe).focus(window: w, raise: true)
        expectEq(outcome.didRaise, true, "测不出来时必须保守报 true")
    }

    test("FocusController：raise=false 且 z 序真的没变 → didRaise=false") {
        let probe = FakeProbe()
        let w = makeWindow(id: 777, pid: GHOST_PID)
        probe.zOrderSequences[777] = [2, 2, 2, 2, 2, 2]
        probe.focused = w
        let outcome = FocusController(probe: probe).focus(window: w, raise: false)
        expectEq(outcome.didRaise, false, "不置顶路径下 z 序不变")
    }

    test("FocusController：raise=false 但窗口被顶上去了 → 如实报 didRaise=true") {
        let probe = FakeProbe()
        let w = makeWindow(id: 777, pid: GHOST_PID)
        probe.zOrderSequences[777] = [3, 1, 1, 1, 1]
        probe.focused = w
        let outcome = FocusController(probe: probe).focus(window: w, raise: false)
        expectEq(outcome.didRaise, true, "降级路径实际置顶了就必须如实上报（上层据此警告用户）")
    }

    test("FocusController：幽灵 pid → fail-soft 不崩，且如实给出 error") {
        let probe = FakeProbe()
        let w = makeWindow(id: 777, pid: GHOST_PID)
        probe.zOrderSequences[777] = [2, 2, 2, 2, 2, 2]
        probe.focused = nil
        let outcome = FocusController(probe: probe).focus(window: w, raise: true)
        expectTrue(outcome.error != nil, "不存在的 pid 不可能真激活成功，必须给 error，实际 nil")
        expectEq(outcome.didActivate, false, "拿不到前台状态时不许报成功")
    }

    test("FocusController：动作路径不许阻塞（raise=true 50 次平均 < 5ms，防 33ms 回归）") {
        // 这是「不许再引入阻塞式观测」的守门断言：修复前动作路径里有 4×5ms 的 settle 轮询
        // （真机上表现为鼠标事件被卡 33ms），本条能把它抓回来。
        // raise=true 是纯逻辑路径（幽灵 pid 让 NSRunningApplication(pid:) 直接返回 nil），
        // 不含任何 Mach IPC，所以可以卡紧到 5ms。
        // raise=false 会真的打一次 AX IPC（降级链），阈值不稳定，故意不卡。
        let probe = FakeProbe()
        let w = makeWindow(id: 8888, pid: 999_999)
        probe.zOrderSequences[8888] = Array(repeating: 1, count: 400)
        let controller = FocusController(probe: probe)

        // 预热一次：首次调用含一次性 dlopen / 首次 CGWindowList（真机约 18ms），不算进阈值
        _ = controller.focus(window: w, raise: true)

        let n = 50
        let t0 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<n { _ = controller.focus(window: w, raise: true) }
        let avgMs = (ProcessInfo.processInfo.systemUptime - t0) / Double(n) * 1000
        expectTrue(avgMs < 5.0,
                   String(format: "raise=true 平均 %.3f ms（阈值 5ms；修复前的 settle 是 4×5ms≈20ms）", avgMs))
    }

    test("SkyLightBridge：mode 常量与符号加载状态（只报告，不断言符号在不在）") {
        expectEq(SkyLightBridge.userGeneratedMode, 0x200, "kCPSUserGenerated")
        print("      SkyLightBridge.isAvailable = \(SkyLightBridge.isAvailable)"
              + "（系统事实：符号在不在不由本工程决定）")
    }
}

// ═══════════════════════════════════════════════════════════════════════

func runSettingsStoreTests() {
    TestHarness.shared.beginSuite("UserDefaultsSettingsStore")

    func scratchStore() -> (store: UserDefaultsSettingsStore, defaults: UserDefaults, name: String) {
        let name = "HoverFocusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (UserDefaultsSettingsStore(defaults: defaults), defaults, name)
    }

    test("首次启动：读不到任何键 → 全默认值") {
        let (store, defaults, name) = scratchStore()
        defer { defaults.removePersistentDomain(forName: name) }
        expectEq(store.settings, Settings.default, "空 defaults 必须给默认值")
    }

    test("观察者：注册时不回调；变更回调一次；重复写同值不回调") {
        let (store, defaults, name) = scratchStore()
        defer { defaults.removePersistentDomain(forName: name) }
        var observed: [Settings] = []
        store.addObserver { observed.append($0) }
        expectEq(observed.count, 0, "注册时不许立刻回调")

        store.settings.dwellDelay = 0.3
        expectEq(observed.count, 1, "变更回调一次")
        expectEq(observed.last?.dwellDelay, 0.3, "回调里带的是新值")
        expectEq(store.settings.dwellDelay, 0.3, "内存值已更新")

        store.settings.dwellDelay = 0.3
        expectEq(observed.count, 1, "重复写同一个值不许回调")

        store.settings.cooldown = 0.4
        expectEq(observed.count, 2, "换一个字段变更要回调")
    }

    test("写入非法值：dwell 钳到 [0,1]，cooldown 钳到 [0.06,1]") {
        let (store, defaults, name) = scratchStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.settings.dwellDelay = 99
        expectEq(store.settings.dwellDelay, 1.0, "过大 dwell 钳到 1")
        store.settings.cooldown = -3
        expectEq(store.settings.cooldown, 0.06, "负 cooldown 钳到下限 0.06")
        store.settings.cooldown = 0
        expectEq(store.settings.cooldown, 0.06, "cooldown=0 也抬到下限 0.06")
    }

    test("持久化：新实例能读回刚写的值") {
        let (store, defaults, name) = scratchStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.settings.dwellDelay = 0.42
        store.settings.mode = .focusAndRaise
        store.settings.excludedBundleIDs = ["com.a", "com.b"]

        let reopened = UserDefaultsSettingsStore(defaults: defaults)
        expectEq(reopened.settings.dwellDelay, 0.42, "dwell 落盘读回")
        expectEq(reopened.settings.mode, .focusAndRaise, "mode 落盘读回")
        expectEq(reopened.settings.excludedBundleIDs, ["com.a", "com.b"], "排除名单落盘读回")
    }

    test("脏数据：字符串 / NaN 一律退回默认值，不把 NaN 放进内存") {
        let name = "HoverFocusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("not a number", forKey: UserDefaultsSettingsStore.Key.dwellDelay)
        defaults.set(Double.nan, forKey: UserDefaultsSettingsStore.Key.cooldown)
        defaults.set("garbage", forKey: UserDefaultsSettingsStore.Key.mode)

        let store = UserDefaultsSettingsStore(defaults: defaults)
        expectEq(store.settings.dwellDelay, Settings.default.dwellDelay, "字符串 dwell 退回默认")
        expectEq(store.settings.cooldown, Settings.default.cooldown, "NaN cooldown 退回默认")
        expectEq(store.settings.mode, Settings.default.mode, "非法 mode 退回默认")
        expectTrue(store.settings.cooldown.isFinite, "内存里不许留 NaN（会让第 13 步判定穿透）")
    }
}
