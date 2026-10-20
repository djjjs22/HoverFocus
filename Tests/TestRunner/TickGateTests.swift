//  HoverFocus — tick 闸门回归测试
//  ─────────────────────────────────────────────────────────────────────────
//  为什么专门测这个：`needsTick` 是「别在没事的时候重跑判定」的闸门，
//  它存在的原因是一个**真实且很难查的性能故障**：
//
//    30Hz 的 tick 每次都重跑完整判定 → 每轮判定都会打跨进程 AX 查询
//    （命中测试 / 焦点窗口 / 全屏检查 / 隐藏检查），实测合起来
//    **每秒约 81 次**，全部落在「正在使用的那款 App」身上。
//    目标 App 的主线程被这些请求压住，来不及响应 mousedown，
//    自绘标题栏的 App（Edge / 微信 / Electron 系）走 macOS 的 drag-trait 手势，
//    对时序很敏感 → **手势激活失败 → 窗口拖不动**。
//
//  而加闸门时我自己踩了一个**死锁**（本文件的第 2 条用例就是防它）：
//    ① 指针移动期间不做命中测试（省 AX）
//    ② tick 只在「正在等 dwell」时才跑
//    → 指针停下后，最后一个采样仍被 ① 挡掉，没设计时，② 于是永不 tick，
//      **引擎再也没有机会解析出当前窗口**，悬停切焦点整个失效。
//    修法：`needsTick` 必须把「上一次结论是 .noWindow」也算作「有事可做」。
//
//  这几条用例的价值不在覆盖率，而在于：闸门一改错，核心功能会**静默失效**
//  （不崩、不报错，就是不动），只有这类断言能挡住。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

private func makeEngine(_ probe: FakeProbe, _ actuator: FakeActuator,
                        dwell: TimeInterval = 0.12) -> FocusEngine {
    let store = FakeSettingsStore(settings(dwell: dwell))
    return FocusEngine(settings: store, probe: probe, actuator: actuator,
                       clock: { ProcessInfo.processInfo.systemUptime })
}

private func sample(_ x: CGFloat = 500, _ y: CGFloat = 400,
                    dragging: Bool = false) -> MouseSample {
    MouseSample(point: CGPoint(x: x, y: y), timestamp: ProcessInfo.processInfo.systemUptime,
                isDragging: dragging, modifiers: [])
}

func runTickGateTests() {
    TestHarness.shared.beginSuite("tick 闸门（性能 / 死锁回归）")

    test("tick 闸门：还没判定过 → 必须 tick（否则永远启动不起来）") {
        let probe = FakeProbe()
        let engine = makeEngine(probe, FakeActuator())
        expectTrue(engine.needsTick, "lastDecision 为 nil 时应 tick，否则引擎永远不会被驱动")
}

    test("tick 闸门：【死锁回归】上次是 .noWindow → 必须继续 tick") {
        // 场景：指针在移动 → 命中测试被「指针还在动」的闸门挡掉 → 结论 .noWindow。
        // 指针停下后，如果这里返回 false，tick 就再也不跑，
        // 引擎永远解析不出窗口 → **悬停切焦点彻底失效**（且不报任何错）。
        let probe = FakeProbe()
        probe.windowAtPoint = nil          // 指针下没有窗口
        let engine = makeEngine(probe, FakeActuator())

        _ = engine.handle(sample())
        if case .ignore(.noWindow) = engine.lastDecision! {
            expectTrue(true, "前提成立：结论为 .noWindow ✓")
        } else {
            expectTrue(false, "前提不成立，实际 \(String(describing: engine.lastDecision))")
            return
        }
        expectTrue(engine.needsTick, "上次是 .noWindow 时必须继续 tick —— 否则解析不出窗口（死锁）")

        // 反向验证：让窗口出现，tick 一次就应该能解析出来并进入计时
        probe.windowAtPoint = makeWindow(id: 7, pid: 9999)
        _ = engine.tick()
        if case .pending(let wid, _) = engine.lastDecision! {
            expectEq(wid, 7, "窗口出现后 tick 应解析出该窗口并开始计时")
        } else {
            expectTrue(false, "窗口出现后 tick 应给出 .pending，实际 \(String(describing: engine.lastDecision))")
        }
}

    test("tick 闸门：正在等 dwell → 必须 tick（否则计时永远到不了点）") {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 11, pid: 9999)
        let engine = makeEngine(probe, FakeActuator(), dwell: 5.0)

        _ = engine.handle(sample())
        if case .pending = engine.lastDecision! {
            expectTrue(true, "前提成立：正在计时 ✓")
        } else {
            expectTrue(false, "应进入计时，实际 \(String(describing: engine.lastDecision))")
            return
        }
        expectTrue(engine.needsTick, "dwell 计时中必须 tick，否则指针静止时永远到不了点")
}

    test("tick 闸门：已停在已聚焦窗口 → 不该 tick（省掉每秒几十次 AX）") {
        // 这是**稳态最常见**的情况：指针停在一个已经聚焦的窗口上。
        // 指针不动 → 状态不会变 → 重跑判定毫无收益，却会持续打 AX 查询压住那个 App。
        let probe = FakeProbe()
        let w = makeWindow(id: 21, pid: 9999)
        probe.windowAtPoint = w
        probe.focused = w          // 它就是当前焦点窗口 → 第 12 步 .sameWindow
        let engine = makeEngine(probe, FakeActuator())

        _ = engine.handle(sample())
        if case .ignore(.sameWindow) = engine.lastDecision! {
            expectTrue(true, "前提成立：结论为 .sameWindow ✓")
        } else {
            expectTrue(false, "应判 .sameWindow，实际 \(String(describing: engine.lastDecision))")
            return
        }
        expectTrue(!engine.needsTick,
                   "已确认停在已聚焦窗口上时不该再 tick —— 否则每秒几十次跨进程 AX 会压垮目标 App")
}

    test("tick 闸门：动作之后不该继续 tick") {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 31, pid: 9999)
        let actuator = FakeActuator()
        let engine = makeEngine(probe, actuator, dwell: 0)

        _ = engine.handle(sample())            // dwell=0 → 直接到第 16 步
        if case .act = engine.lastDecision! {
            expectTrue(true, "前提成立：判定为动作 ✓")
        } else {
            expectTrue(false, "dwell=0 应直接动作，实际 \(String(describing: engine.lastDecision))")
            return
        }
        expectTrue(!engine.needsTick, "动作之后（同窗口已是焦点）不该再 tick")
}
}
