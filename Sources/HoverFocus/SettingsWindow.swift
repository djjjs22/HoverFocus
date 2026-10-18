//  HoverFocus — 设置窗口
//
//  验收标准第 3 条。用 AppKit 手写而不是 SwiftUI，理由：
//    - 本机没有 Xcode，SwiftUI 的预览/调试全用不上，收益为零
//    - AppKit 布局完全可控，不会出现「窗口尺寸对不上、控件被裁掉」这类看不见的问题
//    - 本机看不到屏幕截图，能确定的布局比「好看的布局」重要
//
//  ══ 分层设计══════════════════════════════════════════════════
//  用户是**日常使用者**，不是开发者。所以窗口分两层：
//    · 常用区（默认可见）：总开关 / 激活模式 / 悬停延时 / 排除名单 —— 这四项覆盖 95% 的日常需求
//    · 高级区（默认折叠）：监听方式 / 冷却 / 三个守卫 / 命中精度 / 恢复出厂
//  设计意图就是用户的原话：「专业的人想看自己会去看」。
//  折叠状态持久化（HoverFocusUI.settingsAdvancedExpanded，默认 false），重启后保持。
//
//  ⚠️ 现有 12 个设置项一个都没丢，只是位置变了；所有 action / tooltip / 无障碍标签保留。
//
//  关键约束：所有写操作都走 SettingsEditing → SettingsStore。
//  本窗口**不保存任何自己的副本**，每次显示都从 store.settings 重新读，
//  保证菜单改的和窗口显示的一定一致。

import AppKit

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - 折叠状态持久化

    /// 高级区是否展开。默认 false（折叠）—— bool(forKey:) 在键不存在时就是 false。
    static let advancedExpandedKey = "HoverFocusUI.settingsAdvancedExpanded"

    private var advancedExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.advancedExpandedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.advancedExpandedKey) }
    }

    // MARK: - 依赖

    private let store: SettingsStore
    /// 切换事件源的出口（事件源不是 Settings 的字段，改它要重建 driver，只能回调给 AppDelegate）
    private let onMonitorModeChange: (MonitorMode) -> Void
    private var monitorMode: MonitorMode

    // MARK: - 布局容器

    private var rootStack: NSStackView!
    private var commonStack: NSStackView!
    private var advancedStack: NSStackView!

    // MARK: - 控件

    // 常用区
    private let enabledCheckbox = NSButton(checkboxWithTitle: "启用悬停切换焦点（总开关）", target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dwellSlider = NSSlider()
    private let dwellValueLabel = NSTextField(labelWithString: "—")
    private let tableView = NSTableView()
    private let addCurrentButton = NSButton(title: "添加当前前台 App", target: nil, action: nil)
    private let addManualButton = NSButton(title: "手动添加…", target: nil, action: nil)
    private let removeButton = NSButton(title: "移除选中", target: nil, action: nil)
    private let exclusionCountLabel = NSTextField(labelWithString: "")

    // 高级区
    private let advancedToggleButton = NSButton(title: "", target: nil, action: nil)
    private let pollingRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let lowLatencyRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let monitorHintLabel = NSTextField(labelWithString: "")
    private let cooldownSlider = NSSlider()
    private let cooldownValueLabel = NSTextField(labelWithString: "—")
    private let modifiersCheckbox = NSButton(checkboxWithTitle: "按住修饰键（⌘/⌥/⌃/⇧）时不动焦点", target: nil, action: nil)
    private let draggingCheckbox = NSButton(checkboxWithTitle: "拖拽窗口 / 拖选文字时不动焦点", target: nil, action: nil)
    private let fullScreenCheckbox = NSButton(checkboxWithTitle: "前台 App 全屏时绝不抢焦点", target: nil, action: nil)
    private let hitTestModeLabel = NSTextField(labelWithString: "—")

    private var rows: [ExclusionRow] = []

    private struct ExclusionRow {
        enum Kind {
            case bundleID
            case appName

            var label: String {
                switch self {
                case .bundleID: return "Bundle ID"
                case .appName:  return "App 名称"
                }
            }
        }

        var kind: Kind
        var value: String
        var display: String { "\(value)    （\(kind.label)）" }
    }

    // MARK: - 初始化

    init(store: SettingsStore,
         monitorMode: MonitorMode,
         onMonitorModeChange: @escaping (MonitorMode) -> Void) {
        self.store = store
        self.monitorMode = monitorMode
        self.onMonitorModeChange = onMonitorModeChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "HoverFocus 设置"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        buildUI()

        // 设置变了就刷新控件显示（菜单里改了模式、别的路径改了排除名单，窗口要跟着动）
        store.addObserver { [weak self] settings in
            let apply: () -> Void = { self?.apply(settings) }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        apply(store.settings)

        // 按持久化的折叠状态初始化布局（首次默认折叠）
        setAdvancedExpanded(advancedExpanded, persist: false, animated: false)
    }

    /// 菜单里切换了事件源 → 窗口里的单选框要跟着动。
    /// 签名保持不变（AppDelegate 在用）。
    func updateMonitorMode(_ mode: MonitorMode) {
        monitorMode = mode
        applyMonitorModeToUI()
    }

    /// 命中精度只读说明的文案由 AppDelegate 提供（它才知道 WindowProbe 的实时模式）。
    func updateHitTestMode(_ text: String?) {
        hitTestModeLabel.stringValue = text ?? "未知"
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController 不支持从 xib/storyboard 加载")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        apply(store.settings)
        // 窗口可能在另一块屏幕上显示，重新按那块屏的 visibleFrame 收一次高度
        updateWindowSize(animated: false)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 布局

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // 外层套一个 scroll view：展开高级区后总高可能超过屏幕，
        // 有了它就能「窗口不超出 NSScreen.visibleFrame，内容自己滚」。
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        rootStack = root
        scroll.documentView = root

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // 文档视图宽度固定 → 换行标签才能算出正确高度
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.widthAnchor.constraint(equalToConstant: 620),
        ])

        // ══════════════ 常用区（默认可见）══════════════
        let common = makeSectionStack()
        commonStack = common
        root.addArrangedSubview(common)

        // 1) 总开关
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged)
        enabledCheckbox.setAccessibilityLabel("启用悬停切换焦点，总开关")
        common.addArrangedSubview(enabledCheckbox)

        common.addArrangedSubview(makeSeparator())

        // 2) 激活模式
        common.addArrangedSubview(makeSectionTitle("激活模式"))
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        for mode in ActivationMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
            modePopup.lastItem?.representedObject = mode.rawValue
        }
        modePopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        modePopup.setAccessibilityLabel("激活模式：切焦点后是否置顶窗口")
        common.addArrangedSubview(modePopup)

        let modeHint = makeHint("「只切焦点，不置顶」= 键盘输入切过去，但窗口叠放顺序不变（默认，也是和 AutoFocus 最大的区别）。")
        modeHint.preferredMaxLayoutWidth = 560
        common.addArrangedSubview(modeHint)

        common.addArrangedSubview(makeSeparator())

        // 3) 悬停延时（防误抢的核心）
        common.addArrangedSubview(makeSectionTitle("防误抢"))
        configureSlider(dwellSlider, min: 0, max: 1.0, action: #selector(dwellChanged))
        common.addArrangedSubview(makeSliderRow(title: "悬停延时（dwell）", slider: dwellSlider, value: dwellValueLabel))

        let dwellHint = makeHint("指针要在同一个窗口上停住这么久才切焦点。调大更稳（不会手一抖焦点就飞），调小更跟手。默认 120ms。")
        dwellHint.preferredMaxLayoutWidth = 560
        common.addArrangedSubview(dwellHint)

        common.addArrangedSubview(makeSeparator())

        // 4) 排除名单
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.addArrangedSubview(makeSectionTitle("排除名单"))
        exclusionCountLabel.font = .systemFont(ofSize: 11)
        exclusionCountLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(exclusionCountLabel)
        common.addArrangedSubview(header)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("exclusion"))
        column.title = "排除的 App"
        column.width = 560
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("排除名单列表")

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        tableScroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        common.addArrangedSubview(tableScroll)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        addCurrentButton.target = self
        addCurrentButton.action = #selector(addCurrentApp)
        addManualButton.target = self
        addManualButton.action = #selector(addManual)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.isEnabled = false
        buttonRow.addArrangedSubview(addCurrentButton)
        buttonRow.addArrangedSubview(addManualButton)
        buttonRow.addArrangedSubview(removeButton)
        common.addArrangedSubview(buttonRow)

        let excludeHint = makeHint("名单里的 App 永远不会被悬停抢焦点（按 Bundle ID 匹配，显示名作为兜底）。想临时排除某个 App，也可以直接用菜单栏里的「排除当前 App」。")
        excludeHint.preferredMaxLayoutWidth = 560
        common.addArrangedSubview(excludeHint)

        // ══════════════ 高级区（默认折叠）══════════════
        root.addArrangedSubview(makeSeparator())

        advancedToggleButton.target = self
        advancedToggleButton.action = #selector(toggleAdvanced)
        advancedToggleButton.isBordered = false
        advancedToggleButton.font = .boldSystemFont(ofSize: 13)
        advancedToggleButton.contentTintColor = .controlAccentColor
        advancedToggleButton.setAccessibilityLabel("展开或收起高级设置")
        root.addArrangedSubview(advancedToggleButton)

        let advanced = makeSectionStack()
        advancedStack = advanced
        root.addArrangedSubview(advanced)

        // 监听方式（事件源）
        // 这一节很重要：默认的轮询模式**不需要任何权限**，是「装完就能用」的关键。
        advanced.addArrangedSubview(makeSectionTitle("监听方式（鼠标事件来源）"))

        pollingRadio.target = self
        pollingRadio.action = #selector(monitorModeChanged(_:))
        pollingRadio.tag = 0
        pollingRadio.setAccessibilityLabel("监听方式：轮询光标位置")
        advanced.addArrangedSubview(pollingRadio)

        // 推荐低延迟：事件驱动没有采样间隔，跟手最好；轮询是「不想授权」时的零权限退路。
        let pollingHint = makeHint("轮询光标位置：零权限即可用；按固定 60Hz 采样，最坏比实际移动晚约 16ms。不想授权、或只是偶尔用时选它。")
        pollingHint.preferredMaxLayoutWidth = 540
        advanced.addArrangedSubview(pollingHint)

        lowLatencyRadio.target = self
        lowLatencyRadio.action = #selector(monitorModeChanged(_:))
        lowLatencyRadio.tag = 1
        lowLatencyRadio.setAccessibilityLabel("监听方式：CGEventTap 低延迟")
        advanced.addArrangedSubview(lowLatencyRadio)

        let lowLatencyHint = makeHint("CGEventTap 低延迟：事件驱动，鼠标一动就收到通知，没有 16ms 采样间隔，跟手最好。推荐。需要「辅助功能」权限；未授权时系统会静默丢弃所有鼠标事件，功能不会生效。")
        lowLatencyHint.preferredMaxLayoutWidth = 540
        advanced.addArrangedSubview(lowLatencyHint)

        monitorHintLabel.font = .systemFont(ofSize: 11)
        monitorHintLabel.textColor = .secondaryLabelColor
        advanced.addArrangedSubview(monitorHintLabel)

        advanced.addArrangedSubview(makeSeparator())

        // 动作后冷却
        advanced.addArrangedSubview(makeSectionTitle("动作后冷却"))
        configureSlider(cooldownSlider, min: 0.06, max: 1.0, action: #selector(cooldownChanged))
        advanced.addArrangedSubview(makeSliderRow(title: "动作后冷却", slider: cooldownSlider, value: cooldownValueLabel))

        let cooldownHint = makeHint("一次动作之后这段时间内不再动作，防抖。下限 0.06s 是硬下限（低于它会因为窗口探测缓存出现重复聚焦）。")
        cooldownHint.preferredMaxLayoutWidth = 560
        advanced.addArrangedSubview(cooldownHint)

        advanced.addArrangedSubview(makeSeparator())

        // 守卫
        advanced.addArrangedSubview(makeSectionTitle("守卫"))
        modifiersCheckbox.target = self
        modifiersCheckbox.action = #selector(modifiersChanged)
        advanced.addArrangedSubview(modifiersCheckbox)

        draggingCheckbox.target = self
        draggingCheckbox.action = #selector(draggingChanged)
        advanced.addArrangedSubview(draggingCheckbox)

        fullScreenCheckbox.target = self
        fullScreenCheckbox.action = #selector(fullScreenChanged)
        advanced.addArrangedSubview(fullScreenCheckbox)

        advanced.addArrangedSubview(makeSeparator())

        // 命中精度（只读说明，文案由 AppDelegate 提供）
        advanced.addArrangedSubview(makeSectionTitle("命中精度"))
        hitTestModeLabel.font = .systemFont(ofSize: 11)
        hitTestModeLabel.textColor = .secondaryLabelColor
        hitTestModeLabel.lineBreakMode = .byWordWrapping
        hitTestModeLabel.preferredMaxLayoutWidth = 560
        advanced.addArrangedSubview(hitTestModeLabel)

        advanced.addArrangedSubview(makeSeparator())

        let pathLabel = NSTextField(wrappingLabelWithString: "设置保存在系统偏好里（UserDefaults，前缀 HoverFocus.），改完立刻生效。")
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.preferredMaxLayoutWidth = 560
        advanced.addArrangedSubview(pathLabel)

        // 恢复出厂设置：危险操作，放高级区**最底部**，保留二次确认
        let resetButton = NSButton(title: "恢复默认设置…", target: self, action: #selector(resetDefaults))
        resetButton.setAccessibilityLabel("恢复出厂设置，会清除所有设置和排除名单")
        advanced.addArrangedSubview(resetButton)
    }

    private func makeSectionStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func makeHint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return box
    }

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true          // 拖动过程中就生效，符合「改完立刻生效」
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func makeSliderRow(title: String, slider: NSSlider, value: NSTextField) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true

        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 76).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return row
    }

    // MARK: - 折叠 / 展开

    @objc private func toggleAdvanced() {
        setAdvancedExpanded(!advancedExpanded, persist: true, animated: true)
    }

    private func setAdvancedExpanded(_ expanded: Bool, persist: Bool, animated: Bool) {
        if persist { advancedExpanded = expanded }
        advancedStack?.isHidden = !expanded
        advancedToggleButton.title = expanded
            ? "▾ 高级设置"
            : "▸ 高级设置（冷却、守卫、监听方式等）"
        advancedToggleButton.toolTip = expanded ? "收起高级设置" : "展开高级设置"
        updateWindowSize(animated: animated)
    }

    /// 窗口高度跟着折叠状态走：
    ///   · 折叠 → 刚好容纳常用区
    ///   · 展开 → 完整内容高度，但**不超过屏幕 visibleFrame**（超出部分由 scroll view 滚动）
    ///   · 左上角位置固定（收缩时是「往下收」，不是「往下掉」）
    private func updateWindowSize(animated: Bool) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()

        let chrome = max(0, window.frame.height - content.frame.height)   // 标题栏高度
        let fitting = rootStack?.fittingSize.height ?? content.frame.height

        let screen = window.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 900) - chrome - 24
        let targetContentHeight = min(fitting, max(240, available))

        var frame = window.frame
        let topEdge = frame.maxY                       // 顶边固定
        let newHeight = targetContentHeight + chrome
        frame.size.height = newHeight
        frame.origin.y = topEdge - newHeight           // 往下收
        window.setFrame(frame, display: true, animate: animated)
    }

    // MARK: - 探针接口（只读，供 --selftest-ui / 调试用，不参与业务逻辑）

    struct LayoutSnapshot {
        var advancedExpanded: Bool
        var advancedHidden: Bool
        var windowHeight: CGFloat
        var commonHeight: CGFloat
        var advancedHeight: CGFloat
        var commonControls: Int
        var advancedControls: Int
        var windowFitsOnScreen: Bool
    }

    func layoutSnapshot() -> LayoutSnapshot {
        guard let window, let content = window.contentView else {
            return LayoutSnapshot(advancedExpanded: false, advancedHidden: true, windowHeight: 0,
                                  commonHeight: 0, advancedHeight: 0, commonControls: 0,
                                  advancedControls: 0, windowFitsOnScreen: false)
        }
        content.layoutSubtreeIfNeeded()
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 0
        return LayoutSnapshot(
            advancedExpanded: advancedExpanded,
            advancedHidden: advancedStack?.isHidden ?? true,
            windowHeight: window.frame.height,
            commonHeight: commonStack?.fittingSize.height ?? 0,
            advancedHeight: advancedStack?.fittingSize.height ?? 0,
            commonControls: countControls(in: commonStack),
            advancedControls: countControls(in: advancedStack),
            windowFitsOnScreen: visible == 0 || window.frame.height <= visible)
    }

    /// 供探针切换折叠状态（等价于点标题按钮，但不走动画）
    func setAdvancedExpandedForProbe(_ expanded: Bool) {
        setAdvancedExpanded(expanded, persist: true, animated: false)
    }

    private func countControls(in view: NSView?) -> Int {
        guard let view else { return 0 }
        var total = 0
        for sub in view.subviews {
            if sub is NSControl { total += 1 }
            total += countControls(in: sub)
        }
        return total
    }

    // MARK: - store → UI

    private func apply(_ settings: Settings) {
        enabledCheckbox.state = settings.enabled ? .on : .off

        let modeIndex = ActivationMode.allCases.firstIndex(of: settings.mode) ?? 0
        modePopup.selectItem(at: modeIndex)

        // 注意：这些是程序赋值，不会触发 action，所以不会形成「写 → 回调 → 写」的死循环
        dwellSlider.doubleValue = settings.dwellDelay
        cooldownSlider.doubleValue = settings.cooldown
        dwellValueLabel.stringValue = "\(Int((settings.dwellDelay * 1000).rounded())) ms"
        cooldownValueLabel.stringValue = "\(Int((settings.cooldown * 1000).rounded())) ms"

        modifiersCheckbox.state = settings.requireNoModifiers ? .on : .off
        draggingCheckbox.state = settings.suppressWhileDragging ? .on : .off
        fullScreenCheckbox.state = settings.respectFullScreen ? .on : .off

        applyMonitorModeToUI()

        rebuildRows(settings)
        tableView.reloadData()
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty

        let total = settings.excludedBundleIDs.count + settings.excludedAppNames.count
        exclusionCountLabel.stringValue = total == 0 ? "（空）" : "共 \(total) 项"

        let name = FrontmostAppTracker.shared.displayName
        addCurrentButton.title = name.map { "添加当前前台 App（\($0)）" } ?? "添加当前前台 App"
        addCurrentButton.isEnabled = name != nil
    }

    /// 事件源单选框 + 说明。权限状态直接读系统，如实显示当前能不能用。
    private func applyMonitorModeToUI() {
        pollingRadio.title = MonitorMode.polling.displayName
        lowLatencyRadio.title = MonitorMode.lowLatency.displayName
        pollingRadio.state = (monitorMode == .polling) ? .on : .off
        lowLatencyRadio.state = (monitorMode == .lowLatency) ? .on : .off

        let trusted = Permissions.isAccessibilityTrusted
        switch monitorMode {
        case .polling:
            monitorHintLabel.stringValue = trusted
                ? "当前：轮询 + 精确命中测试（已授予辅助功能）"
                : "当前：轮询 + 降级命中测试（零权限可用；窗口重叠/圆角处可能判错，分屏场景精确）"
            monitorHintLabel.textColor = .secondaryLabelColor
        case .lowLatency:
            monitorHintLabel.stringValue = trusted
                ? "当前：CGEventTap 低延迟（已授予辅助功能）"
                : "⚠️ 当前缺少辅助功能权限，CGEventTap 收不到任何鼠标事件 —— 建议先用轮询模式"
            monitorHintLabel.textColor = trusted ? .secondaryLabelColor : .systemOrange
        }
    }

    private func rebuildRows(_ settings: Settings) {
        var out: [ExclusionRow] = []
        for b in settings.excludedBundleIDs.sorted() {
            out.append(ExclusionRow(kind: .bundleID, value: b))
        }
        for n in settings.excludedAppNames.sorted() {
            out.append(ExclusionRow(kind: .appName, value: n))
        }
        rows = out
    }

    // MARK: - UI → store

    @objc private func enabledChanged() {
        SettingsEditing.setEnabled(store, enabledCheckbox.state == .on)
    }

    @objc private func modeChanged() {
        let index = modePopup.indexOfSelectedItem
        guard index >= 0, index < ActivationMode.allCases.count else { return }
        SettingsEditing.setMode(store, ActivationMode.allCases[index])
    }

    @objc private func monitorModeChanged(_ sender: NSButton) {
        let target: MonitorMode = (sender.tag == 1) ? .lowLatency : .polling
        monitorMode = target
        onMonitorModeChange(target)     // 交给 AppDelegate 重建 driver
        applyMonitorModeToUI()
    }

    @objc private func dwellChanged() {
        SettingsEditing.setDwellDelay(store, dwellSlider.doubleValue)
    }

    @objc private func cooldownChanged() {
        SettingsEditing.setCooldown(store, cooldownSlider.doubleValue)
    }

    @objc private func modifiersChanged() {
        SettingsEditing.setRequireNoModifiers(store, modifiersCheckbox.state == .on)
    }

    @objc private func draggingChanged() {
        SettingsEditing.setSuppressWhileDragging(store, draggingCheckbox.state == .on)
    }

    @objc private func fullScreenChanged() {
        SettingsEditing.setRespectFullScreen(store, fullScreenCheckbox.state == .on)
    }

    @objc private func addCurrentApp() {
        FrontmostAppTracker.shared.refresh()
        let bid = FrontmostAppTracker.shared.bundleID
        let name = FrontmostAppTracker.shared.name
        guard bid != nil || name != nil else {
            NSSound.beep()
            return
        }
        SettingsEditing.addExclusion(store, bundleID: bid, name: name)
        apply(store.settings)
    }

    @objc private func addManual() {
        let alert = NSAlert()
        alert.messageText = "手动添加排除项"
        alert.informativeText = "推荐填 Bundle ID（如 com.apple.Safari），它不会因为 App 改名或系统语言变化而失效。两个都填时以 Bundle ID 为准。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let bundleField = NSTextField(frame: NSRect(x: 0, y: 30, width: 340, height: 24))
        bundleField.placeholderString = "Bundle ID（如 com.apple.Safari）"
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        nameField.placeholderString = "App 显示名（如 Safari）"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        accessory.addSubview(bundleField)
        accessory.addSubview(nameField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = bundleField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let bid = bundleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty || !name.isEmpty else {
            NSSound.beep()
            return
        }
        SettingsEditing.addExclusion(store, bundleID: bid.isEmpty ? nil : bid, name: name.isEmpty ? nil : name)
        apply(store.settings)
    }

    @objc private func removeSelected() {
        let indexes = tableView.selectedRowIndexes
        guard !indexes.isEmpty else { return }

        var toRemove: [ExclusionRow] = []
        for i in indexes where i < rows.count { toRemove.append(rows[i]) }

        for row in toRemove {
            switch row.kind {
            case .bundleID:
                SettingsEditing.removeExclusion(store, bundleID: row.value, name: nil)
            case .appName:
                SettingsEditing.removeExclusion(store, bundleID: nil, name: row.value)
            }
        }
        apply(store.settings)
    }

    @objc private func resetDefaults() {
        let alert = NSAlert()
        alert.messageText = "恢复默认设置？"
        alert.informativeText = "会把所有设置（含排除名单）恢复成出厂默认值。这个操作不能撤销。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsEditing.resetToDefaults(store)
        apply(store.settings)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("exclusionCell")

        var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
        if cell == nil {
            let newCell = NSTableCellView()
            newCell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            newCell.addSubview(textField)
            newCell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
            ])
            cell = newCell
        }
        cell?.textField?.stringValue = rows[row].display
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }
}
