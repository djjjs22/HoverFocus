//  HoverFocus — 菜单栏图标状态映射回归测试（6 个 IconState 分支）
//  ─────────────────────────────────────────────────────────────────────────
//  防的是什么回归：
//   1. `StatusIcon.state(...)` 的**判定顺序**被改动。它同时承载 5 个信号
//      （权限 / 输入监控 / 总开关 / driverError / 模式），顺序一错用户就会看到
//      「明明关了却显示已开启」或「明明异常却显示正常」。
//   2. `IconState.rawValue` 漂移。它被 `--selftest` 的 `iconState` 字段直接输出，
//      是外部脚本（含我的 `verify-permissions.sh`）解析的契约面。
//   3. `symbolName` 映射丢分支 —— 自绘图标靠它选形状/颜色，漏一个分支就画错。
//
//  说明：这些类型在 Sources/HoverFocus/（App 层），通过 Scripts/test.sh 的
//       APP_STATE_SRC 额外编入测试单元（只加编译路径，不改任何逻辑）。
// ─────────────────────────────────────────────────────────────────────────

import Foundation

/// 6 个分支的显式清单。
/// 不用 `IconState.allCases`：IconState 是 App 层类型，目前没有 conform CaseIterable，
/// 而本任务的写作用域不允许改 Sources。用显式清单反而有个好处 ——
/// 谁新增了分支却忘了在这里列出来，「6 个分支」这条断言就会立刻红。
private let allIconStates: [IconState] = [
    .on, .onRaise, .off, .permissionMissing, .inputMonitoringMissing, .error
]

private func s(enabled: Bool = true, mode: ActivationMode = .focusOnly) -> Settings {
    settings(enabled: enabled, mode: mode)
}

func runIconStateTests() {
    TestHarness.shared.beginSuite("菜单栏图标状态映射（StatusIcon）")

    // ── 6 个分支各一条
    test("IconState：on / onRaise 由模式决定", steps: []) {
        expectEq(StatusIcon.state(settings: s(mode: .focusOnly), axTrusted: true), .on,
                 "focusOnly + 已授权 + 有输入监控 + 无错误 → .on")
        expectEq(StatusIcon.state(settings: s(mode: .focusAndRaise), axTrusted: true), .onRaise,
                 "focusAndRaise → .onRaise")
    }

    test("IconState：off 由总开关决定", steps: []) {
        expectEq(StatusIcon.state(settings: s(enabled: false), axTrusted: true), .off,
                 "enabled=false → .off")
    }

    test("IconState：permissionMissing（未授权辅助功能）", steps: []) {
        expectEq(StatusIcon.state(settings: s(), axTrusted: false), .permissionMissing,
                 "requiresAccessibility(默认 true) + axTrusted=false → .permissionMissing")
    }

    test("IconState：inputMonitoringMissing（已授权但收不到鼠标事件）", steps: []) {
        expectEq(StatusIcon.state(settings: s(), axTrusted: true, inputMonitoringMissing: true),
                 .inputMonitoringMissing,
                 "已授权但输入监控缺失 → .inputMonitoringMissing")
    }

    test("IconState：error（driverError 非 nil）", steps: []) {
        expectEq(StatusIcon.state(settings: s(), axTrusted: true, driverError: "模拟失败"), .error,
                 "driverError 非 nil → .error")
    }

    // ── 判定顺序的两个硬性断言（明确要求）
    test("IconState 顺序：权限态优先于开关态（未授权 + 已关闭 → permissionMissing）", steps: []) {
        // 用户看到的应该是「去授权」，而不是「你把它关了」——否则他找不到问题。
        expectEq(StatusIcon.state(settings: s(enabled: false), axTrusted: false), .permissionMissing,
                 "权限态必须先于开关态判")
    }

    test("IconState 顺序：off 优先于 error（已关闭 + 有错误 → off）", steps: []) {
        // 用户主动关掉时不该看到红色告警，否则会以为出故障了。
        expectEq(StatusIcon.state(settings: s(enabled: false), axTrusted: true, driverError: "模拟失败"),
                 .off, "总开关关闭时不该显示 error")
    }

    test("IconState 顺序：零权限事件源下跳过权限判定（requiresAccessibility=false）", steps: []) {
        // MousePoller 是零权限事件源：此时 axTrusted=false 不代表「缺权限」，
        // 如果仍然报 permissionMissing，用户会被引导去授权一个根本不需要的权限。
        expectEq(StatusIcon.state(settings: s(), axTrusted: false, requiresAccessibility: false),
                 .on, "不需要权限的事件源，未授权也应显示正常开启")
        expectEq(StatusIcon.state(settings: s(enabled: false), axTrusted: false, requiresAccessibility: false),
                 .off, "不需要权限时，开关态照常生效")
        expectEq(StatusIcon.state(settings: s(), axTrusted: false, requiresAccessibility: false,
                                  inputMonitoringMissing: true),
                 .on, "不需要权限时，inputMonitoring 这个信号也应被跳过")
    }

    test("IconState 顺序：error 优先于模式（有错误时不显示 onRaise）", steps: []) {
        expectEq(StatusIcon.state(settings: s(mode: .focusAndRaise), axTrusted: true, driverError: "x"),
                 .error, "先报错误，再说模式")
    }

    // ── rawValue 稳定性（--selftest 的 iconState 字段是外部契约面）
    test("IconState.rawValue 稳定（--selftest iconState 字段 / 诊断面板直接展示）", steps: []) {
        let expected: [IconState: String] = [
            .on: "on",
            .onRaise: "onRaise",
            .off: "off",
            .permissionMissing: "permissionMissing",
            .inputMonitoringMissing: "inputMonitoringMissing",
            .error: "error"
        ]
        for (state, raw) in expected {
            expectEq(state.rawValue, raw, "\(raw) 的 rawValue 不许漂移")
        }
        expectEq(allIconStates.count, 6, "IconState 应当正好 6 个分支")
    }

    test("IconState.displayName：6 个分支都有中文文案且互不相同", steps: []) {
        let names = allIconStates.map { $0.displayName }
        expectEq(names.count, 6, "6 个分支")
        expectEq(Set(names).count, 6, "6 个文案互不相同（否则用户分不清状态）")
        for (state, name) in zip(allIconStates, names) {
            expectTrue(!name.isEmpty, "\(state.rawValue) 的文案不许为空")
        }
        // 关键文案回归：开关态必须能一眼看出「开 / 关」
        expectTrue(IconState.on.displayName.contains("已开启"), "on 文案要含「已开启」")
        expectTrue(IconState.off.displayName.contains("已关闭"), "off 文案要含「已关闭」")
        expectTrue(IconState.permissionMissing.displayName.contains("权限"), "权限态文案要提到权限")
    }

    // ── symbolName 映射（自绘图标的标识，供 --selftest / 诊断面板）
    test("StatusIcon.symbolName：5→3 组映射不丢分支", steps: []) {
        expectEq(StatusIcon.symbolName(for: .on), "custom.badge.cursor", "on")
        expectEq(StatusIcon.symbolName(for: .onRaise), "custom.badge.cursor", "onRaise 与 on 共用光标徽标")
        expectEq(StatusIcon.symbolName(for: .off), "custom.badge.cursor.dim", "off 用淡出版本")
        expectEq(StatusIcon.symbolName(for: .permissionMissing), "custom.badge.warning", "权限缺失用警告徽标")
        expectEq(StatusIcon.symbolName(for: .inputMonitoringMissing), "custom.badge.warning",
                 "输入监控缺失用警告徽标")
        expectEq(StatusIcon.symbolName(for: .error), "custom.badge.error", "错误用错误徽标")
    }

    test("StatusIcon.symbolName：正常态与异常态**不许**共用一个标识", steps: []) {
        // 防回归：如果哪天有人把 error 也映射到 cursor，用户就再也看不出「出事了」。
        let normal = Set([StatusIcon.symbolName(for: .on), StatusIcon.symbolName(for: .onRaise),
                          StatusIcon.symbolName(for: .off)])
        let abnormal = Set([StatusIcon.symbolName(for: .permissionMissing),
                            StatusIcon.symbolName(for: .inputMonitoringMissing),
                            StatusIcon.symbolName(for: .error)])
        expectEq(normal.isDisjoint(with: abnormal), true,
                 "正常态（on/onRaise/off）与异常态（权限/输入监控/错误）的图标标识必须不重叠")
        expectEq(StatusIcon.symbolName(for: .permissionMissing),
                 StatusIcon.symbolName(for: .inputMonitoringMissing),
                 "两种权限异常可以共用同一个警告标识")
    }
}
