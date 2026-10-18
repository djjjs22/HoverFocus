//  HoverFocus — 文本编辑守卫回归测试（契约第 3.5 步）
//  ─────────────────────────────────────────────────────────────────────────
//  防的是什么回归（AutoFocus 的老 bug）：
//    Finder 里选中文件按 Return 重命名，文件名变成高亮的行内输入框；此时一旦窗口失焦，
//    **重命名会被直接取消**，用户白编辑。同理表格单元格编辑、行内改名。
//
//  这条守卫是今晚紧急加的行为，此前只有人工验证。本文件把它钉死：
//    1. 命中时必须 .textEditing 且零动作；
//    2. 必须 clearPending —— 否则「编辑结束后立刻误切」；
//    3. 位置必须在第 3 步之后、第 4/5 步之前（顺序契约）；
//    4. 未命中时行为与改动前完全一致（不许误伤正常切换）。
//
//  步号用 17 代表契约里的「3.5」（见 TestHarness.textEditingStep）。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

private let STEP_35 = TestHarness.textEditingStep
private let PID_EDIT = pid_t(1000)
private let PID_OTHER = pid_t(2000)

func runTextEditingGuardTests() {
    TestHarness.shared.beginSuite("文本编辑守卫（契约第 3.5 步）")

    // ── 1. 命中 → .textEditing，且零动作
    test("3.5 步：前台在编辑单行输入框 → .textEditing，即使其余条件全部满足", steps: [STEP_35]) {
        // dwell=0：若没有这道守卫，这个采样一定会走到第 16 步直接 act。
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 100, pid: PID_EDIT)
        s.probe.foregroundTextEditor = true
        expectIgnore(s.handle(at: 0), .textEditing, "编辑中必须让路")
        expectEq(s.actuator.calls.count, 0, "编辑中不许产生任何动作（否则 Finder 重命名被取消）")
        expectEq(s.engine.stats.count(of: .textEditing), 1, "stats 要记 textEditing")
    }

    // ── 2. 未命中时行为与改动前一致
    test("3.5 步：未在编辑 → 行为与改动前一致（dwell=0 立刻 act）", steps: [STEP_35]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 101, pid: PID_EDIT)
        s.probe.foregroundTextEditor = false
        expectAct(s.handle(at: 0), windowID: 101, pid: PID_EDIT, raise: false,
                  "没有编辑态时必须照常切换（不许误伤核心功能）")
    }

    test("3.5 步：未在编辑 → 仍然正常走 dwell 计时（不提前 act）", steps: [STEP_35]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 101, pid: PID_EDIT)
        s.probe.foregroundTextEditor = false
        expectPending(s.handle(at: 0), windowID: 101, remaining: 0.5, "先计时")
        expectAct(s.handle(at: 0.5), windowID: 101, pid: PID_EDIT, raise: false, "到点照常动作")
    }

    // ── 3. 必须 clearPending：这条最关键
    test("3.5 步：命中时必须清零 dwell 计时（否则编辑结束后会立刻误切）", steps: [STEP_35]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 102, pid: PID_EDIT)

        // t=0 在窗口上建立计时
        expectPending(s.handle(at: 0), windowID: 102, remaining: 0.5, "开始在窗口上计时")
        // t=0.2 用户开始行内重命名 → 守卫命中
        s.probe.foregroundTextEditor = true
        expectIgnore(s.handle(at: 0.2), .textEditing, "编辑开始，守卫命中")
        // t=0.25 编辑结束：若计时没被清零，此刻 elapsed=0.25 会给出 pending(0.25)，
        // 再 0.25s 就会 act —— 也就是「刚编辑完就被切走」。
        // 清零后必须重新计满 0.5。
        s.probe.foregroundTextEditor = false
        expectPending(s.handle(at: 0.25), windowID: 102, remaining: 0.5,
                      "编辑期间计时必须归零：回到窗口要重新等满 dwell")
        // 反向确认：真正到点（t=0.75 = 0.25 + 0.5）才动
        expectAct(s.handle(at: 0.75), windowID: 102, pid: PID_EDIT, raise: false, "重新攒满后才动")
    }

    // ── 4. 顺序契约：3.5 必须在第 4、5 步之前
    test("3.5 优先于第 4 步：编辑中 + 指针在菜单栏 → .textEditing", steps: [STEP_35]) {
        guard menuBarIsTestable() else {
            skipTest("本机菜单栏被自动隐藏，构造不出菜单栏坐标")
            return
        }
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = makeWindow(id: 103, pid: PID_EDIT)
        s.probe.foregroundTextEditor = true
        expectIgnore(s.handle(at: 0, point: menuBarPoint()), .textEditing,
                     "第 3.5 步必须先于第 4 步（菜单栏）")
    }

    test("3.5 优先于第 5 步：编辑中 + 指针下没有窗口 → .textEditing", steps: [STEP_35]) {
        let s = Scenario(settings: settings(dwell: 0))
        s.probe.windowAtPoint = nil
        s.probe.foregroundTextEditor = true
        expectIgnore(s.handle(at: 0), .textEditing, "第 3.5 步必须先于第 5 步（noWindow）")
    }

    // ── 5. 顺序契约：第 1/2/3 步必须仍在 3.5 之前
    test("第 1/2/3 步仍优先于 3.5：禁用 / 拖拽 / 修饰键都不因编辑态而改变结论", steps: [STEP_35, 1, 2, 3]) {
        let sDisabled = Scenario(settings: settings(enabled: false, dwell: 0))
        sDisabled.probe.windowAtPoint = makeWindow(id: 104, pid: PID_EDIT)
        sDisabled.probe.foregroundTextEditor = true
        expectIgnore(sDisabled.handle(at: 0), .disabled, "第 1 步优先于 3.5")

        let sDragging = Scenario(settings: settings(dwell: 0))
        sDragging.probe.windowAtPoint = makeWindow(id: 104, pid: PID_EDIT)
        sDragging.probe.foregroundTextEditor = true
        expectIgnore(sDragging.handle(at: 0, dragging: true), .dragging, "第 2 步优先于 3.5")

        let sModifiers = Scenario(settings: settings(dwell: 0))
        sModifiers.probe.windowAtPoint = makeWindow(id: 104, pid: PID_EDIT)
        sModifiers.probe.foregroundTextEditor = true
        expectIgnore(sModifiers.handle(at: 0, modifiers: .maskCommand), .modifiersHeld,
                     "第 3 步优先于 3.5")
    }

    // ── 6. 跨窗口场景：编辑态属于「前台 App」，与指针下的窗口无关
    test("3.5 步：编辑态判定与「指针下是哪个窗口」无关（只要前台在编辑就守）", steps: [STEP_35]) {
        let s = Scenario(settings: settings(dwell: 0))
        // 指针停在别的 App 的窗口上（即使那个窗口完全正常、可聚焦）
        s.probe.windowAtPoint = makeWindow(id: 105, pid: PID_OTHER)
        s.probe.foregroundTextEditor = true
        expectIgnore(s.handle(at: 0), .textEditing,
                     "前台正在重命名时，悬停到任何窗口都不许抢焦点")
    }

    // ── 7. tick 也要守（鼠标静止时由定时器驱动）
    test("3.5 步：tick 期间进入编辑态 → 也不许动作", steps: [STEP_35]) {
        let s = Scenario(settings: settings(dwell: 0.5))
        s.probe.windowAtPoint = makeWindow(id: 106, pid: PID_EDIT)
        expectPending(s.handle(at: 0), windowID: 106, remaining: 0.5, "先开始计时")
        s.probe.foregroundTextEditor = true
        expectNotAct(s.tick(at: 0.6), "编辑态下 tick 到点也不许动作")
        expectIgnore(s.tick(at: 0.6), .textEditing, "tick 也要给出 textEditing")
    }
}
