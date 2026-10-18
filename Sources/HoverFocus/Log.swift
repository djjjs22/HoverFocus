//  HoverFocus — 日志
//
//  为什么同时用 os_log 和 NSLog：
//    实测发现用 `open build/HoverFocus.app` 启动时，NSLog 的输出**进不了 unified log**
//    （`log show --predicate 'process == "HoverFocus"'` 搜不到那几行关键状态），
//    而直接跑二进制却能看到。于是「用户双击启动后到底什么状态」就变得不可诊断 ——
//    尤其这个 App 曾经会因为 AppKit Automatic Termination 静默消失，
//    没有日志根本查不出「它怎么又没了」。
//
//    所以这里显式写 os_log（带自己的 subsystem，方便精确过滤）：
//      log show --last 5m --predicate 'subsystem == "com.lunasama.HoverFocus"' --style compact
//    NSLog 保留一份，方便直接跑二进制时在终端看。

import Foundation
import os

enum Log {
    /// 显式 subsystem：比按进程名过滤可靠（进程名在日志里会被截断成 anon<HoverFocus>）
    static let subsystem = "com.lunasama.HoverFocus"

    private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    private static let decision = Logger(subsystem: subsystem, category: "decision")

    /// 统一前缀，方便在终端里人眼定位
    private static let prefix = "[HoverFocus]"

    /// 注意用 notice 而不是 info：
    /// os_log 的 info 级别**默认不被 `log show` 显示**（要加 --info 才看得到），
    /// 而 notice 映射到 OS_LOG_TYPE_DEFAULT，默认就可见。
    /// 生命周期事件的意义就是「用户双击启动后到底怎么了」，看不到等于没写。
    static func info(_ message: String) {
        lifecycle.notice("\(message, privacy: .public)")
        NSLog("\(prefix) \(message)")
    }

    /// 需要用户关注的问题。不许静默失败 —— 这里必须落日志。
    static func warn(_ message: String) {
        lifecycle.warning("\(message, privacy: .public)")
        NSLog("\(prefix)[警告] \(message)")
    }

    static func error(_ message: String) {
        lifecycle.error("\(message, privacy: .public)")
        NSLog("\(prefix)[错误] \(message)")
    }

    /// 判定/动作相关单独一个 category，和生命周期事件分开看
    static func action(_ message: String) {
        decision.notice("\(message, privacy: .public)")
        NSLog("\(prefix)[动作] \(message)")
    }
}
