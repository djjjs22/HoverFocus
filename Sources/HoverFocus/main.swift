//  HoverFocus — 应用入口（app-shell 所有）
//
//  两种运行模式：
//    HoverFocus              常驻菜单栏模式（LSUIElement，无 Dock 图标）
//    HoverFocus --selftest   自检模式：建 status item → 等 1s → 打印单行 JSON → exit 0
//                            （本机看不到屏幕，这是唯一「图标真的出来了」的验证手段）
//
//  构建方式提醒：本机 SwiftPM 已损坏，全部源码用一条 swiftc 命令编进**同一个模块**，
//  所以这里绝对不要写 `import HoverFocusCore` —— 那样会编译失败。
//
//  顶层可执行代码只允许出现在 main.swift（Swift 的规则），其他文件只能有声明。

import AppKit
import Foundation

private func printUsage() {
    print("""
    HoverFocus \(AppInfo.fallbackVersion) — 鼠标悬停即切换键盘焦点的 macOS 菜单栏工具

    用法：
      HoverFocus               启动菜单栏 App（常驻）
      HoverFocus --selftest    自检模式：创建菜单栏图标 → 等 1 秒 → 输出单行 JSON → 退出 0
      HoverFocus --version     打印版本号
      HoverFocus --help        显示本帮助

    自检模式输出字段（单行 JSON）：
      statusItemCreated / buttonWindowVisible / buttonWindowFrame /
      axTrusted / version / driverStarted / error
    """)
}

let cliArguments = CommandLine.arguments

if cliArguments.contains("--help") || cliArguments.contains("-h") {
    printUsage()
    exit(0)
}

if cliArguments.contains("--version") {
    print(AppInfo.version)
    exit(0)
}

if cliArguments.contains("--selftest") || cliArguments.contains("--selftest-ui") {
    // 自检模式：不进入常驻菜单栏模式，内部自行 exit。
    // --selftest-ui 额外把「完整菜单 + 设置窗口」的构造路径也真跑一遍
    // （本机截不了屏、也没法自动点击，这是唯一能验证这两块不闪退的办法）。
    SelfTest.run()
}

// 常驻菜单栏模式
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// LSUIElement=true 已经写进 Info.plist；这里再设一次，保证裸二进制运行时也没有 Dock 图标
app.setActivationPolicy(.accessory)
app.run()
