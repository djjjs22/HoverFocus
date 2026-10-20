//  HoverFocus — 手写测试运行器入口
//  ─────────────────────────────────────────────────────────────────────────
//  顶层代码只允许写在名为 main.swift 的文件里 —— 所以入口在这里，
//  用例分散在 TestRunner/ 的其它文件、替身在 TestSupport/。
//
//  为什么不用 XCTest / swift test：见 Scripts/test.sh 顶部说明（本机 SwiftPM 损坏）。
//  退出码：0 = 全绿；1 = 有失败或契约 16 步有遗漏。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import Darwin

print("HoverFocus 单元测试（手写运行器；不依赖 XCTest、不依赖辅助功能权限）")
print("系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
print("AXIsProcessTrusted = \(Permissions.isAccessibilityTrusted)"
      + "（本机为 false；下列用例全部是纯逻辑，不该受它影响）")

runContractTests()
runSettingsStoreTests()
runControllerTests()
runStepTests()
runTextEditingGuardTests()
runIconStateTests()
runDriverTests()
runTickGateTests()
runNotificationGuardTests()

exit(TestHarness.shared.finishAndExitCode())
