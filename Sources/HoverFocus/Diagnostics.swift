//  HoverFocus — 诊断记账（app-shell 所有）
//
//  本机看不到屏幕，用户说「怎么没生效」时唯一的排查手段就是这里：
//  把每次判定的原因、最近一次动作的结果、驱动状态、Tap 被禁次数全部记下来，
//  菜单里能直接看到，也能一键复制成文本发给别人。
//
//  契约里 FocusIgnoreReason 的 rawValue 是英文枚举名，这里补一份中文解释 ——
//  中文用户看 "fullScreenBlocked" 不如看「前台 App 全屏中」。

import Foundation
import CoreGraphics

final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    private init() {}

    private(set) var decisionCount = 0
    private(set) var lastDecisionText = "—"
    private(set) var lastDecisionAt: Date?
    private(set) var lastActionText = "—"
    private(set) var lastActionAt: Date?
    private(set) var lastWarning: String?
    private(set) var lastWarningAt: Date?
    /// 最近 8 次真实动作（只有 .act 才记，避免被 ignore 淹没）
    private(set) var recentActions: [String] = []

    /// 契约里 16 步判定的中文解释
    static let reasonNames: [String: String] = [
        "disabled":          "总开关关闭",
        "dragging":          "正在拖拽",
        "modifiersHeld":     "按住修饰键",
        "inMenuBar":         "指针在菜单栏",
        "noWindow":          "指针下没有窗口",
        "ownApp":            "HoverFocus 自己的窗口",
        "systemUI":          "系统 UI（Dock/控制中心等）",
        "appHidden":         "目标 App 被隐藏（cmd-H）",
        "nonNormalWindow":   "非普通窗口（浮层/提示条）",
        "excludedApp":       "命中排除名单",
        "sameWindow":        "已经是当前焦点窗口",
        "cooldown":          "冷却中",
        "fullScreenBlocked": "前台 App 全屏中",
        "notOnScreen":       "窗口不在当前 Space",
    ]

    static func reasonName(_ raw: String) -> String {
        reasonNames[raw] ?? raw
    }

    // MARK: - 记录

    func record(decision: FocusDecision, outcome: FocusOutcome?) {
        decisionCount += 1
        lastDecisionAt = Date()

        switch decision {
        case .ignore(let reason):
            lastDecisionText = "忽略：\(Self.reasonName(reason.rawValue))（\(reason.rawValue)）"
        case .pending(let windowID, let remaining):
            lastDecisionText = String(format: "计时中：window=%u 还差 %.0fms",
                                      windowID, max(0, remaining) * 1000)
        case .act(let action):
            lastDecisionText = "动作：window=\(action.windowID) pid=\(action.pid) raise=\(action.raise)"
        }

        guard let outcome else { return }

        // 只有真的动手了才有 outcome 值得记
        if case .act = decision {
            let line = Self.describe(outcome: outcome)
            lastActionText = line
            lastActionAt = Date()
            recentActions.insert(line, at: 0)
            if recentActions.count > 8 { recentActions.removeLast() }
            Log.action("动作结果：\(line)")
        }
    }

    func recordWarning(_ message: String) {
        lastWarning = message
        lastWarningAt = Date()
        Log.warn(message)
    }

    static func describe(outcome: FocusOutcome) -> String {
        let app = outcome.window.appName ?? outcome.window.bundleID ?? "pid \(outcome.window.pid)"
        var parts: [String] = []
        parts.append("目标=\(app)")
        parts.append("策略=\(outcome.strategy.rawValue)")
        parts.append("成为前台=\(outcome.didActivate ? "是" : "否")")
        parts.append("置顶了=\(outcome.didRaise ? "是" : "否")")
        if let err = outcome.error { parts.append("错误=\(err)") }
        return parts.joined(separator: " ")
    }

    // MARK: - 文本报告

    /// 菜单里显示的短摘要
    func summaryLines(stats: EngineStats, settings: Settings, axTrusted: Bool,
                      driverRunning: Bool, driverError: String?) -> [String] {
        var lines: [String] = []
        lines.append("版本：\(AppInfo.versionLine)")
        lines.append("辅助功能权限：\(axTrusted ? "已授予" : "未授予")")
        lines.append("鼠标监听：\(driverRunning ? "运行中" : "已停止")")
        if let driverError { lines.append("驱动错误：\(driverError)") }
        lines.append("总开关：\(settings.enabled ? "开" : "关")；模式：\(settings.mode.displayName)")
        lines.append(String(format: "dwell %.0fms；冷却 %.0fms",
                            settings.dwellDelay * 1000, settings.cooldown * 1000))
        lines.append("采样：\(stats.samples) 次；动作：\(stats.actions) 次")
        lines.append("最近判定：\(lastDecisionText)")
        lines.append("最近动作：\(lastActionText)")
        if let w = lastWarning {
            lines.append("最近警告：\(w)")
        }
        return lines
    }

    /// 「复制诊断信息」用的完整报告。
    /// extra 由 AppDelegate 传入一些只有它知道的信号（命中测试模式、SkyLight 可用性等），
    /// 这样诊断层不需要反过来依赖 AppEnvironment。
    func fullReport(stats: EngineStats, settings: Settings, axTrusted: Bool,
                    driverRunning: Bool, driverError: String?, monitor: MouseEventSource?,
                    extra: [String] = []) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var out: [String] = []
        out.append("HoverFocus 诊断报告")
        out.append("生成时间：\(df.string(from: Date()))")
        out.append("版本：\(AppInfo.versionLine)")
        out.append("bundle id：\(AppInfo.bundleID)")
        out.append("可执行文件：\(AppInfo.executablePath)")
        out.append("")
        out.append("== 权限 / 监听 ==")
        out.append("AXIsProcessTrusted：\(axTrusted)")
        out.append("鼠标监听运行中：\(driverRunning)")
        if let driverError { out.append("驱动错误：\(driverError)") }
        if let mm = monitor as? MouseMonitor {
            out.append("CGEventTap 被系统禁用次数：\(mm.tapDisableCount)")
            out.append("CGEventTap 当前可用：\(mm.isTapEnabled)")
            for (k, v) in MouseMonitor.permissionDiagnosis().sorted(by: { $0.key < $1.key }) {
                out.append("  \(k) = \(v)")
            }
        }
        for line in extra {
            out.append(line)
        }
        out.append("")
        out.append("== 当前设置 ==")
        out.append("enabled=\(settings.enabled)")
        out.append("mode=\(settings.mode.rawValue)（\(settings.mode.displayName)）")
        out.append(String(format: "dwellDelay=%.3fs", settings.dwellDelay))
        out.append(String(format: "cooldown=%.3fs", settings.cooldown))
        out.append("requireNoModifiers=\(settings.requireNoModifiers)")
        out.append("suppressWhileDragging=\(settings.suppressWhileDragging)")
        out.append("respectFullScreen=\(settings.respectFullScreen)")
        out.append("excludedBundleIDs=\(settings.excludedBundleIDs.sorted())")
        out.append("excludedAppNames=\(settings.excludedAppNames.sorted())")
        out.append("")
        out.append("== 运行统计 ==")
        out.append("采样次数：\(stats.samples)")
        out.append("动作次数：\(stats.actions)")
        out.append("决策回调次数：\(decisionCount)")
        out.append("最近判定：\(lastDecisionText)")
        out.append("最近动作：\(lastActionText)")
        if let t = lastActionAt { out.append("最近动作时间：\(df.string(from: t))") }
        if let w = lastWarning { out.append("最近警告：\(w)") }
        out.append("")
        out.append("== 忽略原因计数（为什么没生效）==")
        let counts = stats.ignoreCounts.sorted { $0.value > $1.value }
        if counts.isEmpty {
            out.append("（无）")
        } else {
            for (raw, n) in counts {
                out.append("  \(Self.reasonName(raw))（\(raw)）：\(n)")
            }
        }
        out.append("")
        out.append("== 最近动作 ==")
        if recentActions.isEmpty { out.append("（无）") } else {
            for a in recentActions { out.append("  \(a)") }
        }
        return out.joined(separator: "\n")
    }
}
