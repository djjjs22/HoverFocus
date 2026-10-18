//  hf-target — HoverFocus 端到端测试用的最小目标 App（verifier 所有）
//  ─────────────────────────────────────────────────────────────────────────
//  为什么需要它：端到端验证要「把指针停到一个非前台窗口上」，但不能拿用户
//  正在用的 App 做实验（会真的抢焦点、还可能改坏用户的窗口布局）。
//  所以起两个自己的窗口 App，一左一右，用它们当靶子。
//
//  构建：由 Scripts/e2e-hover-test.sh 组装成 build/hf-target.app 并复制成 A/B 两个。
//  位置由环境变量给（Quartz 坐标，原点左上）：
//    HF_TARGET_TITLE / HF_TARGET_X / HF_TARGET_Y / HF_TARGET_W / HF_TARGET_H
//  ─────────────────────────────────────────────────────────────────────────

import AppKit
import Foundation

final class TargetDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let x = Double(env["HF_TARGET_X"] ?? "120") ?? 120
        let y = Double(env["HF_TARGET_Y"] ?? "160") ?? 160
        let w = Double(env["HF_TARGET_W"] ?? "560") ?? 560
        let h = Double(env["HF_TARGET_H"] ?? "460") ?? 460
        let title = env["HF_TARGET_TITLE"] ?? "HoverFocus 测试目标"

        // NSWindow 用 Cocoa 坐标（左下原点），环境变量给的是 Quartz（左上原点）
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        let rect = NSRect(x: x, y: screenHeight - y - h, width: w, height: h)

        let win = NSWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered,
                           defer: false)
        win.title = title
        win.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 26)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: h / 2 - 20, width: w, height: 40)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        win.contentView?.addSubview(label)

        win.makeKeyAndOrderFront(nil)
        window = win

        NSApp.activate(ignoringOtherApps: true)

        // 让脚本知道窗口真的建好了，以及窗口号（用 CGWindowID 需要另查，这里只给 NSWindowNumber）
        print("HF_TARGET_READY title=\(title) pid=\(getpid()) windowNumber=\(win.windowNumber)")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = TargetDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
