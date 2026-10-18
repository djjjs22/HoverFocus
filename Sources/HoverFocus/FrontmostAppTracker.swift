//  HoverFocus — 「当前前台 App」追踪
//
//  为什么需要这个：菜单里的「排除当前 App」和设置窗口里的「添加当前前台 App」
//  都要知道「用户此刻在用的 App」。但一旦 HoverFocus 自己的设置窗口成为 key window，
//  NSWorkspace.frontmostApplication 就变成 HoverFocus 自己了 —— 直接用它会把
//  「HoverFocus」加进排除名单，这是个很难发现的 bug。
//
//  所以这里记住「最后一个不是自己的前台 App」。刷新时如果前台就是自己，就保留旧值。

import AppKit

final class FrontmostAppTracker {
    static let shared = FrontmostAppTracker()

    private(set) var bundleID: String?
    private(set) var name: String?
    private(set) var pid: pid_t?

    private var observing = false

    private init() {}

    func start() {
        guard !observing else { refresh(); return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        refresh()
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            refresh()
            return
        }
        adopt(app)
    }

    /// 主动刷新一次。前台是自己时保留旧值（见文件头说明）。
    func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        adopt(app)
    }

    private func adopt(_ app: NSRunningApplication) {
        guard app.processIdentifier != getpid() else { return }
        guard app.bundleIdentifier != AppInfo.bundleID else { return }
        // 系统 UI 进程（Dock / 控制中心等）不算「用户的 App」，排除名单加它们没意义
        if app.bundleIdentifier == "com.apple.dock" { return }
        bundleID = app.bundleIdentifier
        name = app.localizedName
        pid = app.processIdentifier
    }

    /// 菜单项标题用："Safari" / "com.apple.Safari" / nil
    var displayName: String? {
        if let name, !name.isEmpty { return name }
        return bundleID
    }

    /// 拿不到任何外部前台 App 时的可读原因
    var unavailableReason: String? {
        guard displayName == nil else { return nil }
        return "还没检测到外部 App"
    }
}
