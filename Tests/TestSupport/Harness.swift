//  HoverFocus — 手写测试 harness
//  ─────────────────────────────────────────────────────────────────────────
//  为什么不用 XCTest：本机只有 Command Line Tools，没有可用的 XCTest；
//  且 SwiftPM 已损坏（swift test 链接失败）。所以这里是一个零依赖的极简运行器：
//
//    - test(...)  注册并立即执行一个用例，用 steps:[...] 标注它覆盖契约的哪几步
//    - expectXxx  断言；失败只记数、不抛异常，跑完统一打印失败清单
//    - 退出码：有失败 exit 1；另外「16 步里任何一步没有用例」也算失败（验收硬性要求）
//
//  设计取舍：断言失败**不中断**当前用例（不用 fatalError），这样一次运行能看到全部问题。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

struct TestFailure {
    let suite: String
    let test: String
    let message: String
    let file: String
    let line: Int
}

final class TestHarness {
    static let shared = TestHarness()

    private(set) var failures: [TestFailure] = []
    private(set) var checks = 0
    private(set) var testsRun = 0
    private(set) var testsSkipped = 0
    private(set) var skippedReasons: [String] = []

    private var suiteName = "(未命名 suite)"
    private var testName = "(未命名用例)"
    private var currentSteps: [Int] = []
    private var testSkipped = false

    /// 覆盖矩阵：契约步骤号 → 用例数 / 断言数（跳过的不计入）
    private(set) var stepTests: [Int: Int] = [:]
    private(set) var stepChecks: [Int: Int] = [:]

    /// 契约步号 1–16，外加 17 = 契约里的「第 3.5 步」文本编辑守卫。
    /// 3.5 不是整数步号，这里用 17 代表它，保证它同样受覆盖门约束（缺用例即 exit 1）。
    static let textEditingStep = 17
    private let contractSteps = Array(1...16) + [17]

    private init() {}

    // MARK: - 生命周期

    func beginSuite(_ name: String) {
        suiteName = name
        print("\n\u{001B}[1m── \(name) ──\u{001B}[0m")
    }

    func beginTest(_ name: String, steps: [Int]) {
        testName = name
        currentSteps = steps
        testSkipped = false
        testsRun += 1
    }

    func endTest() {
        if testSkipped {
            testsSkipped += 1
            print("  \u{001B}[33m⊘\u{001B}[0m \(testName)  [已跳过]")
            return
        }
        for s in currentSteps { stepTests[s, default: 0] += 1 }
        print("  \u{001B}[32m✓\u{001B}[0m \(testName)")
    }

    /// 环境不满足（例如本机菜单栏自动隐藏），把整个用例标为跳过 —— 跳过不计入通过。
    func skipTest(_ reason: String) {
        guard !testSkipped else { return }
        testSkipped = true
        skippedReasons.append("\(suiteName) / \(testName)：\(reason)")
        print("  \u{001B}[33m⊘\u{001B}[0m \(testName) — \(reason)")
    }

    var isCurrentTestSkipped: Bool { testSkipped }

    // MARK: - 断言

    func check(_ ok: Bool, _ message: String, file: String, line: Int) {
        guard !testSkipped else { return }
        checks += 1
        for s in currentSteps { stepChecks[s, default: 0] += 1 }
        if !ok {
            let f = TestFailure(suite: suiteName, test: testName, message: message, file: file, line: line)
            failures.append(f)
            print("    \u{001B}[31m✗\u{001B}[0m \(message)")
            print("      @ \(shortPath(file)):\(line)")
        }
    }

    // MARK: - 报告

    private func shortPath(_ p: String) -> String {
        guard let r = p.range(of: "/Tests/") else { return p }
        return "Tests/" + p[r.upperBound...]
    }

    /// 返回进程退出码
    func finishAndExitCode() -> Int32 {
        var hardFailures = failures

        // 覆盖门：契约 16 步，每一步必须至少有一个用例
        for s in contractSteps where (stepTests[s] ?? 0) == 0 {
            hardFailures.append(TestFailure(
                suite: "覆盖门",
                test: "契约步骤覆盖",
                message: "步骤 \(s) 没有任何测试用例（16 步每一步都要求至少 1 个用例）",
                file: "Tests/TestRunner", line: 0))
        }

        print("\n\u{001B}[1m═══ 覆盖矩阵（契约 16 步）═══\u{001B}[0m")
        for s in contractSteps {
            let t = stepTests[s] ?? 0
            let c = stepChecks[s] ?? 0
            let mark = t > 0 ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m"
            let name = StepNames.name(s)
            print(String(format: "  %@ 步骤 %2d  %-34@  用例 %2d  断言 %3d", mark, s, name as NSString, t, c))
        }

        print("\n\u{001B}[1m═══ 结果 ═══\u{001B}[0m")
        print("  用例：\(testsRun) 个（跳过 \(testsSkipped) 个）")
        print("  断言：\(checks) 次")
        print("  失败：\(failures.count) 处")

        if !skippedReasons.isEmpty {
            print("\n  \u{001B}[33m跳过清单（未验证，不算通过）：\u{001B}[0m")
            for r in skippedReasons { print("    - \(r)") }
        }

        if !hardFailures.isEmpty {
            print("\n\u{001B}[31m\u{001B}[1m失败清单：\u{001B}[0m")
            var lastSuite = ""
            for (i, f) in hardFailures.enumerated() {
                if f.suite != lastSuite { print("  【\(f.suite)】"); lastSuite = f.suite }
                print("   \(i + 1). \(f.test)")
                print("      \(f.message)")
                if f.line > 0 { print("      @ \(shortPath(f.file)):\(f.line)") }
            }
            print("\n\u{001B}[31m测试失败\u{001B}[0m")
            return 1
        }

        print("\n\u{001B}[32m\u{001B}[1m全部通过\u{001B}[0m")
        return 0
    }
}

enum StepNames {
    static func name(_ s: Int) -> String {
        switch s {
        case 1:  return "!enabled → .disabled"
        case 2:  return "拖拽 → .dragging"
        case 3:  return "修饰键 → .modifiersHeld"
        case 4:  return "菜单栏 → .inMenuBar"
        case 5:  return "无窗口 → .noWindow"
        case 6:  return "非普通窗口 / 不在当前 Space"
        case 7:  return "ownApp → .ownApp"
        case 8:  return "系统 UI → .systemUI"
        case 9:  return "隐藏 App → .appHidden"
        case 10: return "排除名单 → .excludedApp"
        case 11: return "全屏守卫 → .fullScreenBlocked"
        case 12: return "同一窗口 → .sameWindow"
        case 13: return "冷却 → .cooldown"
        case 14: return "换目标 → 重置计时 .pending"
        case 15: return "dwell 未到点 → .pending"
        case 16: return "到点 → .act"
        case 17: return "3.5 文本编辑守卫 → .textEditing"
        default: return "?"
        }
    }
}

// MARK: - 全局断言入口

func test(_ name: String, steps: [Int] = [], _ body: () -> Void) {
    let h = TestHarness.shared
    h.beginTest(name, steps: steps)
    body()
    h.endTest()
}

func skipTest(_ reason: String) {
    TestHarness.shared.skipTest(reason)
}

func expectTrue(_ ok: Bool, _ message: String, file: String = #file, line: Int = #line) {
    TestHarness.shared.check(ok, message, file: file, line: line)
}

func expectEq<T: Equatable>(_ actual: T, _ expected: T, _ label: String,
                            file: String = #file, line: Int = #line) {
    let ok = actual == expected
    var msg = "\(label)：期望 \(expected)，实际 \(actual)"
    if ok { msg = "\(label)：\(actual)" }
    TestHarness.shared.check(ok, ok ? "\(label) ✓" : msg, file: file, line: line)
}

func expectApprox(_ actual: Double, _ expected: Double, _ tol: Double, _ label: String,
                  file: String = #file, line: Int = #line) {
    let ok = abs(actual - expected) <= tol
    TestHarness.shared.check(ok,
        ok ? "\(label) ✓"
           : "\(label)：期望 \(expected) ±\(tol)，实际 \(actual)（差 \(abs(actual - expected))）",
        file: file, line: line)
}

/// 断言决策是某个 ignore 原因
func expectIgnore(_ d: FocusDecision, _ reason: FocusIgnoreReason, _ label: String,
                  file: String = #file, line: Int = #line) {
    if case .ignore(let r) = d {
        TestHarness.shared.check(r == reason,
            r == reason ? "\(label) ✓" : "\(label)：期望 .ignore(.\(reason.rawValue))，实际 .ignore(.\(r.rawValue))",
            file: file, line: line)
    } else {
        TestHarness.shared.check(false, "\(label)：期望 .ignore(.\(reason.rawValue))，实际 \(describe(d))",
                                 file: file, line: line)
    }
}

func expectPending(_ d: FocusDecision, windowID: CGWindowID, remaining: Double, tol: Double = 1e-6,
                   _ label: String, file: String = #file, line: Int = #line) {
    guard case .pending(let wid, let rem) = d else {
        TestHarness.shared.check(false,
            "\(label)：期望 .pending(window \(windowID), remaining \(remaining))，实际 \(describe(d))",
            file: file, line: line)
        return
    }
    let okID = wid == windowID
    let okRem = abs(rem - remaining) <= tol
    if okID && okRem {
        TestHarness.shared.check(true, "\(label) ✓", file: file, line: line)
    } else {
        TestHarness.shared.check(false,
            "\(label)：期望 .pending(window \(windowID), remaining \(remaining)±\(tol))，"
            + "实际 .pending(window \(wid), remaining \(rem))",
            file: file, line: line)
    }
}

func expectPendingAny(_ d: FocusDecision, _ label: String,
                      file: String = #file, line: Int = #line) {
    if case .pending = d {
        TestHarness.shared.check(true, "\(label) ✓", file: file, line: line)
    } else {
        TestHarness.shared.check(false, "\(label)：期望 .pending(...)，实际 \(describe(d))",
                                 file: file, line: line)
    }
}

func expectAct(_ d: FocusDecision, windowID: CGWindowID, pid: pid_t, raise: Bool, _ label: String,
               file: String = #file, line: Int = #line) {
    guard case .act(let a) = d else {
        TestHarness.shared.check(false,
            "\(label)：期望 .act(window \(windowID), pid \(pid), raise \(raise))，实际 \(describe(d))",
            file: file, line: line)
        return
    }
    let expected = FocusAction(windowID: windowID, pid: pid, raise: raise)
    TestHarness.shared.check(a == expected,
        a == expected ? "\(label) ✓"
                      : "\(label)：期望 \(expected)，实际 \(a)",
        file: file, line: line)
}

func expectNotAct(_ d: FocusDecision, _ label: String, file: String = #file, line: Int = #line) {
    if case .act = d {
        TestHarness.shared.check(false, "\(label)：不许动作，实际 \(describe(d))", file: file, line: line)
    } else {
        TestHarness.shared.check(true, "\(label) ✓", file: file, line: line)
    }
}

func describe(_ d: FocusDecision) -> String {
    switch d {
    case .ignore(let r): return ".ignore(.\(r.rawValue))"
    case .pending(let w, let rem): return String(format: ".pending(window %u, remaining %.4f)", w, rem)
    case .act(let a): return ".act(window \(a.windowID), pid \(a.pid), raise \(a.raise))"
    }
}
