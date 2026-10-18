//  HoverFocus — FocusDriver 接线测试
//  ─────────────────────────────────────────────────────────────────────────
//  driver 的职责是「把 monitor / engine / timer / delegate 接起来」，
//  它本身没有判定逻辑，所以这里只测接线是否真的通、stop() 是否干净。
//
//  本机 AXIsProcessTrusted()=false，所以必须用 permissionCheck = { true } 接缝
//  把权限门打开（这是 提供的非契约测试接缝）。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

final class RecorderDelegate: FocusDriverDelegate {
    var decisions: [FocusDecision] = []
    var outcomes: [FocusOutcome?] = []
    var warnings: [String] = []

    func focusDriver(_ driver: FocusDriver, didDecide decision: FocusDecision, outcome: FocusOutcome?) {
        decisions.append(decision)
        outcomes.append(outcome)
    }

    func focusDriver(_ driver: FocusDriver, didSurfaceWarning message: String) {
        warnings.append(message)
    }
}

/// 造一个权限门已打开的 driver（本机没有辅助功能权限，必须绕过）
private func makeDriver(settings s: Settings,
                        probe: FakeProbe,
                        actuator: FakeActuator,
                        monitor: FakeMonitor,
                        clock: @escaping MonotonicClock,
                        tickInterval: TimeInterval = 0.01) -> FocusDriver {
    let store = FakeSettingsStore(s)
    let driver = FocusDriver(settings: store, probe: probe, actuator: actuator,
                             monitor: monitor, clock: clock, tickInterval: tickInterval)
    driver.permissionCheck = { true }
    return driver
}

private func sampleAt(_ t: TimeInterval) -> MouseSample {
    MouseSample(point: safePoint(), timestamp: t, isDragging: false, modifiers: [])
}

/// 转主 runloop，直到条件成立或超时。返回是否在超时前成立。
@discardableResult
private func spinRunLoop(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

func runDriverTests() {
    TestHarness.shared.beginSuite("FocusDriver 接线")

    test("driver：采样 → handle → .act → perform → delegate 全链路打通", steps: [16]) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 60, pid: 1000)
        let actuator = FakeActuator()
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: actuator, monitor: monitor, clock: clock.reader)
        let rec = RecorderDelegate()
        driver.delegate = rec

        do { try driver.start() } catch {
            expectTrue(false, "start() 不该抛错：\(error)")
            return
        }
        expectEq(driver.isTicking, true, "start 后 tick Timer 应在跑")
        expectEq(driver.isRunning, true, "start 后 monitor 应在跑")

        monitor.emit(sampleAt(0))

        expectEq(actuator.calls.count, 1, "actuator 调用次数")
        expectEq(actuator.calls.first?.window.windowID, 60, "actuator 收到的窗口")
        expectEq(actuator.calls.first?.raise, false, "focusOnly 模式 raise=false")
        expectEq(driver.engineStats.samples, 1, "engine 收到 1 个采样")
        expectEq(rec.decisions.count, 1, "delegate 判定回调次数")
        if case .act = rec.decisions.first {
            expectTrue(true, "delegate 收到 .act ✓")
        } else {
            expectTrue(false, "delegate 应收到 .act，实际 \(String(describing: rec.decisions.first))")
        }
        let outcome = rec.outcomes.first ?? nil
        expectTrue(outcome != nil, ".act 时 delegate 必须拿到非 nil outcome")
        driver.stop()
    }

    test("driver：pending 判定也要回调 delegate", steps: [14]) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 61, pid: 1000)
        let actuator = FakeActuator()
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0.5), probe: probe,
                                actuator: actuator, monitor: monitor, clock: clock.reader)
        let rec = RecorderDelegate()
        driver.delegate = rec
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }

        monitor.emit(sampleAt(0))
        expectEq(rec.decisions.count, 1, "pending 也要回调")
        expectPendingAny(rec.decisions.first ?? .ignore(.disabled), "delegate 收到 .pending")
        expectEq(actuator.calls.count, 0, "pending 不许动作")
        driver.stop()
    }

    test("driver：鼠标静止时靠 tick 定时器到点（不依赖新采样）", steps: [15, 16]) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 62, pid: 1000)
        let actuator = FakeActuator()
        let monitor = FakeMonitor()
        // 这条用例必须用**真实**单调时钟：定时器是真实时间驱动的
        let realClock: MonotonicClock = { ProcessInfo.processInfo.systemUptime }
        let driver = makeDriver(settings: settings(dwell: 0.05), probe: probe,
                                actuator: actuator, monitor: monitor,
                                clock: realClock, tickInterval: 0.01)
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }

        monitor.emit(sampleAt(realClock()))
        expectEq(actuator.calls.count, 0, "刚采样时还没到 dwell")

        let acted = spinRunLoop(until: { !actuator.calls.isEmpty }, timeout: 2.0)
        expectTrue(acted, "静止鼠标应当在 ~50ms 后靠 tick 到点并动作（tick Timer 没跑起来？）")
        expectEq(actuator.calls.first?.window.windowID, 62, "动作目标是悬停窗口")
        driver.stop()
    }

    test("driver：stop() 之后不再回调 delegate，Timer 已失效", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 63, pid: 1000)
        let actuator = FakeActuator()
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: actuator, monitor: monitor, clock: clock.reader)
        let rec = RecorderDelegate()
        driver.delegate = rec
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }
        monitor.emit(sampleAt(0))
        let before = rec.decisions.count

        driver.stop()
        expectEq(driver.isTicking, false, "stop 后 tick Timer 必须失效")
        expectEq(driver.isRunning, false, "stop 后 monitor 必须停")
        expectEq(monitor.stopCount, 1, "monitor.stop 调用次数")
        expectTrue(monitor.onSample == nil, "stop 后必须摘掉 onSample")

        monitor.emit(sampleAt(0.1))
        expectEq(rec.decisions.count, before, "stop 之后不许再有 delegate 回调")
        expectEq(actuator.calls.count, 1, "stop 之后不许再动作")
    }

    test("driver：事件源声明需要授权 + 无权限 → start() 抛 .permissionDenied，不留定时器", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 63, pid: 1000)
        let monitor = FakeMonitor()
        monitor.requiresAccessibilityPermission = true
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: FakeActuator(), monitor: monitor, clock: clock.reader)
        driver.permissionCheck = { false }

        do {
            try driver.start()
            expectTrue(false, "事件源声明需要授权且无权限时，start() 必须抛错")
        } catch let e as MouseMonitorError {
            if case .permissionDenied = e {
                expectTrue(true, "抛 .permissionDenied ✓")
            } else {
                expectTrue(false, "期望 .permissionDenied，实际 \(e)")
            }
        } catch {
            expectTrue(false, "期望 MouseMonitorError，实际 \(error)")
        }
        expectEq(driver.isTicking, false, "启动失败不该留下 tick Timer")
        expectEq(monitor.startCount, 0, "权限不过时不该去 start monitor")
    }

    test("driver：假事件源不声明需要授权 → permissionCheck=false 也照样能启动", steps: []) {
        // 语义（已通知）：门槛只看「事件源自己声明的需求」，
        // 假实现默认不需要授权，所以不该被 permissionCheck 挡掉。
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 64, pid: 1000)
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: FakeActuator(), monitor: monitor, clock: clock.reader)
        driver.permissionCheck = { false }
        do {
            try driver.start()
            expectTrue(true, "零权限事件源应当能启动 ✓")
        } catch {
            expectTrue(false, "不该被 permissionCheck 挡掉，实际抛了 \(error)")
        }
        expectEq(monitor.startCount, 1, "monitor.start 调用次数")
        driver.stop()
        expectEq(driver.isTicking, false, "stop 后不该留 tick Timer")
    }

    test("driver：真实 MouseMonitor（需要授权）+ 无授权 → start() 抛 .permissionDenied", steps: []) {
        guard !Permissions.isAccessibilityTrusted else {
            skipTest("本机已授予辅助功能权限，构造不出「无授权」前提")
            return
        }
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 65, pid: 1000)
        let clock = FakeClock()
        // 构造 MouseMonitor 无副作用（不会建 tap）；真正会抛错的是它自己的 start()。
        let driver = FocusDriver(settings: FakeSettingsStore(settings(dwell: 0)),
                                 probe: probe, actuator: FakeActuator(),
                                 monitor: MouseMonitor(), clock: clock.reader, tickInterval: 0.01)
        driver.permissionCheck = { false }
        do {
            try driver.start()
            expectTrue(false, "无授权 + 需要授权的事件源，start() 必须抛错")
        } catch let e as MouseMonitorError {
            if case .permissionDenied = e {
                expectTrue(true, "抛 .permissionDenied ✓")
            } else {
                expectTrue(false, "期望 .permissionDenied，实际 \(e)")
            }
        } catch {
            expectTrue(false, "期望 MouseMonitorError，实际 \(error)")
        }
        expectEq(driver.isTicking, false, "启动失败不该留下 tick Timer")
    }

    test("driver：MousePoller（零权限事件源）在无授权机器上也能启动", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 66, pid: 1000)
        let clock = FakeClock()
        let driver = FocusDriver(settings: FakeSettingsStore(settings(dwell: 0)),
                                 probe: probe, actuator: FakeActuator(),
                                 monitor: MousePoller(), clock: clock.reader, tickInterval: 0.01)
        driver.permissionCheck = { false }
        do {
            try driver.start()
            expectTrue(true, "轮询源零权限可用 ✓")
        } catch {
            expectTrue(false, "轮询源不该被权限挡住，实际抛了 \(error)")
        }
        expectEq(driver.isRunning, true, "monitor 已在跑")
        driver.stop()
        expectEq(driver.isRunning, false, "stop 后 monitor 已停")
        expectEq(driver.isTicking, false, "stop 后 tick Timer 已失效")
    }

    test("driver：重复 start() → .alreadyRunning，monitor.start 只调一次", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 65, pid: 1000)
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: FakeActuator(), monitor: monitor, clock: clock.reader)
        do { try driver.start() } catch { expectTrue(false, "首次 start 抛错：\(error)"); return }
        do {
            try driver.start()
            expectTrue(false, "重复 start 必须抛错")
        } catch let e as MouseMonitorError {
            if case .alreadyRunning = e {
                expectTrue(true, "抛 .alreadyRunning ✓")
            } else {
                expectTrue(false, "期望 .alreadyRunning，实际 \(e)")
            }
        } catch {
            expectTrue(false, "期望 MouseMonitorError，实际 \(error)")
        }
        expectEq(monitor.startCount, 1, "monitor.start 调用次数")
        driver.stop()
    }

    test("driver：monitor.start 抛错要向上传播，并摘掉 onSample", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 66, pid: 1000)
        let monitor = FakeMonitor()
        monitor.startError = MouseMonitorError.tapCreationFailed
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: FakeActuator(), monitor: monitor, clock: clock.reader)
        do {
            try driver.start()
            expectTrue(false, "monitor.start 抛错时 driver.start 必须向上抛")
        } catch let e as MouseMonitorError {
            if case .tapCreationFailed = e {
                expectTrue(true, "原样传播 .tapCreationFailed ✓")
            } else {
                expectTrue(false, "期望 .tapCreationFailed，实际 \(e)")
            }
        } catch {
            expectTrue(false, "期望 MouseMonitorError，实际 \(error)")
        }
        expectTrue(monitor.onSample == nil, "启动失败必须摘掉 onSample（不留半启动状态）")
        expectEq(driver.isTicking, false, "启动失败不该留定时器")
    }

    test("driver：focusOnly 模式实际置顶 → 必须走 didSurfaceWarning（不静默吞掉）", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 67, pid: 1000)
        let actuator = FakeActuator()
        actuator.didRaiseToReport = true
        actuator.strategyToReport = .publicActivate
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(mode: .focusOnly, dwell: 0), probe: probe,
                                actuator: actuator, monitor: monitor, clock: clock.reader)
        let rec = RecorderDelegate()
        driver.delegate = rec
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }

        monitor.emit(sampleAt(0))
        expectTrue(rec.warnings.count >= 1, "降级/置顶必须产生 warning，实际 \(rec.warnings.count) 条")
        expectTrue(rec.warnings.contains { $0.contains("置顶") },
                   "至少有一条 warning 要明说窗口被置顶了；实际：\(rec.warnings)")
        driver.stop()
    }

    test("driver：聚焦失败 → didSurfaceWarning", steps: []) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 68, pid: 1000)
        let actuator = FakeActuator()
        actuator.didActivateToReport = false
        actuator.errorToReport = "模拟失败"
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = makeDriver(settings: settings(dwell: 0), probe: probe,
                                actuator: actuator, monitor: monitor, clock: clock.reader)
        let rec = RecorderDelegate()
        driver.delegate = rec
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }

        monitor.emit(sampleAt(0))
        expectTrue(rec.warnings.count >= 1, "聚焦失败必须产生 warning")
        driver.stop()
    }

    test("driver：延迟补测确认被置顶 → 必须告警；未置顶 → 不许告警（产品真实告警路径）", steps: []) {
        // 这条必须用**真** FocusController：只有它才会让 driver 在 start() 里接上
        // onRaiseResolved，也才走得到产品真正的告警路径。
        // FakeActuator 只能覆盖「没接上补测」的 fallback 分支 —— 那是最危险那条路的盲区。
        // 幽灵 pid：不会真的抢用户焦点。
        let probe = FakeProbe()
        let w = makeWindow(id: 1001, pid: 999_999)
        probe.windowAtPoint = w
        // 动作路径的**临时值**刻意让它看起来「被置顶了」（z 3→0），
        // 用来验证：接了补测之后，动作路径的滞后临时值不许提前报警。
        probe.zOrderSequences[1001] = [3, 0, 0, 0, 0, 0]
        let controller = FocusController(probe: probe)
        let monitor = FakeMonitor()
        let clock = FakeClock()
        let driver = FocusDriver(settings: FakeSettingsStore(settings(mode: .focusOnly, dwell: 0)),
                                 probe: probe, actuator: controller, monitor: monitor,
                                 clock: clock.reader, tickInterval: 0.01)
        driver.permissionCheck = { true }
        let rec = RecorderDelegate()
        driver.delegate = rec

        expectTrue(controller.onRaiseResolved == nil, "start() 之前不该有补测接线")
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }
        expectTrue(controller.onRaiseResolved != nil, "start() 必须把延迟补测接到告警上")

        monitor.emit(sampleAt(0))   // dwell=0 → act → FocusController.focus(raise: false)

        // 动作路径的临时 didRaise 是 true，但权威值在补测里 → 此刻不许报「被置顶」
        expectTrue(!rec.warnings.contains { $0.contains("被置顶") },
                   "动作路径的滞后临时值不许提前报「被置顶」；实际：\(rec.warnings)")

        // 方向一：补测确认「本来要求不置顶，结果被置顶」→ 必须告警
        controller.onRaiseResolved?(FocusController.RaiseResolution(
            windowID: 1001, strategy: .skyLightNoRaise, expectsRaise: false, didRaise: true))
        let afterRaise = rec.warnings.count
        expectTrue(rec.warnings.contains { $0.contains("延迟补测") },
                   "补测确认被置顶必须告警；实际：\(rec.warnings)")

        // 方向二：补测确认「没置顶」→ 不许再多一条告警
        controller.onRaiseResolved?(FocusController.RaiseResolution(
            windowID: 1001, strategy: .skyLightNoRaise, expectsRaise: false, didRaise: false))
        expectEq(rec.warnings.count, afterRaise, "补测说没置顶时不许告警")

        // 方向三：expectsRaise=true（本来就要置顶）→ 即使 didRaise=true 也不许告警
        controller.onRaiseResolved?(FocusController.RaiseResolution(
            windowID: 1001, strategy: .publicActivate, expectsRaise: true, didRaise: true))
        expectEq(rec.warnings.count, afterRaise, "expectsRaise=true 时 didRaise=true 是预期行为，不许告警")

        driver.stop()
        expectTrue(controller.onRaiseResolved == nil, "stop() 必须摘掉补测接线（停掉后不该再有告警）")
    }

    test("driver：tick 的判定也会回调 delegate", steps: [15]) {
        let probe = FakeProbe()
        probe.windowAtPoint = makeWindow(id: 69, pid: 1000)
        let monitor = FakeMonitor()
        let realClock: MonotonicClock = { ProcessInfo.processInfo.systemUptime }
        let driver = makeDriver(settings: settings(dwell: 5.0), probe: probe,
                                actuator: FakeActuator(), monitor: monitor,
                                clock: realClock, tickInterval: 0.01)
        let rec = RecorderDelegate()
        driver.delegate = rec
        do { try driver.start() } catch { expectTrue(false, "start 抛错：\(error)"); return }

        monitor.emit(sampleAt(realClock()))
        _ = spinRunLoop(until: { rec.decisions.count >= 3 }, timeout: 1.0)
        expectTrue(rec.decisions.count >= 3,
                   "tick 判定也要回调 delegate，实际只收到 \(rec.decisions.count) 次")
        if case .pending? = rec.decisions.last {
            expectTrue(true, "tick 判定为 .pending ✓")
        } else {
            expectTrue(false, "dwell=5s 时 tick 判定应为 .pending，实际 \(String(describing: rec.decisions.last))")
        }
        driver.stop()
    }
}
