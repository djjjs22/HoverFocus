//  HoverFocus — 首次启动 3 步引导（app-shell 所有，task-6 新增）
//
//  ══ 为什么需要这个 ═════════════════════════════════════════════════════
//  用户是**日常使用者**，不是开发者。今晚发生过的真实摩擦：他一度以为是我们把系统搞坏了。
//  根因是「装完不知道它到底生效了没、也不知道它做了什么」。
//  所以这个引导的第一句必须立刻建立正确预期：
//      **现在就能用 · 不需要任何权限 · 不会改变窗口叠放**
//  而不是让用户自己去猜、去系统设置里翻。
//
//  ⚠️ 引导里只能写**已经存在的功能**：
//     全局快捷键 ⌃⌥H 已实现（task-8）→ 第 3 步同时给出快捷键与菜单两条路径。
//
//  显示时机：UserDefaults 没有 HoverFocusUI.didShowFirstRun 时，在
//  applicationDidFinishLaunching 末尾自动弹一次；菜单里也有「重新显示欢迎引导」。

import AppKit

final class FirstRunWindowController: NSWindowController, NSWindowDelegate {

    /// 是否已经引导过。bool(forKey:) 在键不存在时返回 false → 默认「没引导过」。
    static let didShowKey = "HoverFocusUI.didShowFirstRun"

    static var hasShown: Bool {
        UserDefaults.standard.bool(forKey: didShowKey)
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: didShowKey)
    }

    /// 仅供调试/测试：让引导下次启动时重新出现
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: didShowKey)
    }

    private let autostartButton = NSButton(title: "开启开机自启", target: nil, action: nil)
    private let autostartStatusLabel = NSTextField(labelWithString: "")

    /// ⌃⌥H 是否真的可用。注册失败时（被别的 App 占用）第 3 步必须**改口** ——
    /// 引导是新用户在打开菜单之前看到的内容，在这里承诺一个按了没反应的快捷键，
    /// 而且界面上没有任何解释，是最糟的体验。
    private let hotkeyAvailable: Bool

    // MARK: - 初始化

    init(hotkeyAvailable: Bool = true) {
        self.hotkeyAvailable = hotkeyAvailable
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "欢迎使用 HoverFocus"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.delegate = self
        buildUI()
        refreshAutostartState()
    }

    required init?(coder: NSCoder) {
        fatalError("FirstRunWindowController 不支持从 xib/storyboard 加载")
    }

    // MARK: - 显示

    func show() {
        // LSUIElement 应用不 activate 的话，窗口会藏在别的 App 后面 —— 用户根本看不到。
        NSApp.activate(ignoringOtherApps: true)
        refreshAutostartState()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关窗即视为「已引导」（不管是点「开始使用」还是点红叉）。
    /// 理由：用户关掉了就是看过了，下次启动再弹一次会变成骚扰。
    func windowWillClose(_ notification: Notification) {
        Self.markShown()
        Log.info("首次引导已关闭，写入 \(Self.didShowKey)=true")
    }

    // MARK: - 布局

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        // ── 标题 ───────────────────────────────────────────────
        let title = NSTextField(labelWithString: "欢迎使用 HoverFocus")
        title.font = .boldSystemFont(ofSize: 19)
        root.addArrangedSubview(title)

        // 第一句就把预期钉死：能用 / 不要权限 / 不置顶
        let lead = makeBody("鼠标停在哪个窗口上，键盘输入就跟着到哪个窗口 —— 不用点一下。\n"
                            + "现在就能用：不需要授予任何权限，也不会改变你窗口的叠放顺序。")
        root.addArrangedSubview(lead)

        root.addArrangedSubview(makeSeparator())

        // ── 第 1 步 ────────────────────────────────────────────
        root.addArrangedSubview(makeStepTitle("① 直接用就行"))
        root.addArrangedSubview(makeBody("把鼠标停在另一个窗口上大约 0.12 秒，键盘焦点就切过去了。\n"
                                         + "窗口不会跳到前面来 —— 布局保持原样，只是「键盘听谁的」变了。"))

        // ── 第 2 步 ────────────────────────────────────────────
        root.addArrangedSubview(makeStepTitle("② 建议开启开机自启"))
        root.addArrangedSubview(makeBody("开启后每次登录都自动就绪，不用记得手动打开它。"))

        autostartButton.target = self
        autostartButton.action = #selector(enableAutostart)
        autostartButton.bezelStyle = .rounded
        autostartButton.setAccessibilityLabel("开启开机自动启动")
        root.addArrangedSubview(autostartButton)

        autostartStatusLabel.font = .systemFont(ofSize: 11)
        autostartStatusLabel.textColor = .secondaryLabelColor
        autostartStatusLabel.lineBreakMode = .byWordWrapping
        autostartStatusLabel.preferredMaxLayoutWidth = 460
        root.addArrangedSubview(autostartStatusLabel)

        // ── 第 3 步 ────────────────────────────────────────────
        // 快捷键可用与否，文案必须跟着变：不可用时只讲菜单路径，并说明为什么没有快捷键。
        if hotkeyAvailable {
            root.addArrangedSubview(makeStepTitle("③ 想临时停一下就按 ⌃⌥H"))
            root.addArrangedSubview(makeBody("按 ⌃⌥H 立刻暂停（菜单栏图标会变成灰色），再按一次恢复。\n"
                                             + "也可以用菜单栏图标 → 取消勾选「启用悬停切换焦点」。都不用退出 App。"))
        } else {
            root.addArrangedSubview(makeStepTitle("③ 想临时停一下就点菜单栏图标"))
            root.addArrangedSubview(makeBody("菜单栏的 HoverFocus 图标 → 取消勾选「启用悬停切换焦点」，它就不抢焦点了；\n"
                                             + "想恢复再勾上即可。不用退出 App。\n"
                                             + "（快捷键 ⌃⌥H 已被其他 App 占用，暂时不可用。）"))
        }

        root.addArrangedSubview(makeSeparator())

        // ── 底部主按钮 ─────────────────────────────────────────
        let startButton = NSButton(title: "开始使用", target: self, action: #selector(startUsing))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"        // 回车即开始
        startButton.setAccessibilityLabel("开始使用，关闭引导")
        root.addArrangedSubview(startButton)

        let footer = NSTextField(labelWithString: "随时可以在菜单栏图标里重新打开这份引导。")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)
    }

    private func makeStepTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 14)
        return label
    }

    private func makeBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    // MARK: - 动作

    @objc private func enableAutostart() {
        let status = LaunchAtLogin.setEnabled(true)

        // 不许静默失败：成功要说清用的是哪种方式，失败要把原因摊开
        if status.isOn {
            autostartButton.title = "已开启 ✅"
            autostartButton.isEnabled = false
            autostartStatusLabel.textColor = .secondaryLabelColor
            autostartStatusLabel.stringValue = "当前方式：\(status.mechanism.displayName)"
        } else if status.needsApproval {
            autostartButton.title = "需要你在系统设置里批准"
            autostartStatusLabel.textColor = .systemOrange
            autostartStatusLabel.stringValue = status.detail
        } else {
            autostartButton.title = "开启失败，点这里重试"
            autostartStatusLabel.textColor = .systemRed
            autostartStatusLabel.stringValue = status.error ?? status.detail
        }
    }

    @objc private func startUsing() {
        // markShown 由 windowWillClose 统一负责（点红叉关窗也算看过）
        close()
    }

    /// 打开窗口时如果开机自启已经是开的，按钮直接显示「已开启 ✅」，别让用户重复点。
    private func refreshAutostartState() {
        let status = LaunchAtLogin.status()
        if status.isOn {
            autostartButton.title = "已开启 ✅"
            autostartButton.isEnabled = false
            autostartStatusLabel.textColor = .secondaryLabelColor
            autostartStatusLabel.stringValue = "当前方式：\(status.mechanism.displayName)"
        } else {
            autostartButton.title = "开启开机自启"
            autostartButton.isEnabled = true
            if status.needsApproval {
                autostartStatusLabel.textColor = .systemOrange
                autostartStatusLabel.stringValue = status.detail
            } else {
                autostartStatusLabel.textColor = .secondaryLabelColor
                autostartStatusLabel.stringValue = ""
            }
        }
    }
}
