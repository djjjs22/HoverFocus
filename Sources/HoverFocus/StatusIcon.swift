//  HoverFocus — 菜单栏图标三态
//
//  验收标准第 1 条：图标状态要能看出「开 / 关 / 权限缺失」三态。
//  本机 macOS 26+ 的菜单栏图标由 MenuBarAgent 合成，不是独立窗口、也截不到图，
//  所以「三态」必须同时体现在：图标符号 + contentTintColor + tooltip + 菜单首行文字。
//  只看图标是不够的（用户分不清图标细微差别），文字兜底。
//
//  ⚠️ 图标是**自绘的彩色小徽标**，不是 SF Symbol。
//
//  为什么放弃 SF Symbol：用户实际菜单栏里其他 App 都是有颜色、有辨识度的图标
//  （Stats 的数字、各种彩色 logo），SF Symbol 只能画单色线条，放在一排彩色图标里
//  既没辨识度也「没意思」。而且之前 on/onRaise 两态分别用 arrow.up.forward.app 和
//  arrow.up.forward.square —— 在 18pt 下几乎一模一样，用户反馈「没变」。
//
//  ⚠️ 关键：普通状态用**模板图（template image）**，颜色交给系统。
//
//  第一版我画了「蓝紫渐变 + 白光标」的彩色徽标，结果在用户那张蓝色壁纸的菜单栏里
//  糊成一片 —— 硬编码的颜色**不可能适配所有壁纸**。macOS 的标准解法是模板图：
//  我们只画 alpha 形状，系统按菜单栏/壁纸的明暗自动染成白色或黑色。
//
//  但纯模板图会失去「异常要醒目」这个诉求，所以分成两类：
//
//    on / onRaise   模板图：圆角徽标**描边** + 光标（形状是我们自己的，颜色跟系统走）
//    off            同上，但整体 alpha 降到 0.42 = 淡出，一眼看出「没启用」
//    permissionMissing / inputMonitoringMissing
//                   彩色：橙色实心徽标 + 白色感叹号（需要用户去授权，必须跳出来）
//    error          彩色：红色实心徽标 + 白色感叹号（红 = 出错，必须跳出来）
//
//  即：**正常状态融入系统外观，异常状态用颜色抢注意力**。这是菜单栏 App 的通行做法
//  （录屏的红色圆点、电池的黄色低电量都是这个逻辑）。
//
//  自绘的好处：NSImage(size:flipped:drawingHandler:) 分辨率无关，Retina 自动重绘，
//  不用维护 @2x 资源；模板图模式下系统还会自动处理深浅色切换，不用监听 appearance 变化。

import AppKit

enum IconState: String {
    case on
    case onRaise
    case off
    case permissionMissing
    case inputMonitoringMissing
    case error

    /// 给 --selftest 与诊断面板用的中文名
    var displayName: String {
        switch self {
        case .on:                      return "已开启（只切焦点，不置顶）"
        case .onRaise:                 return "已开启（切焦点并置顶）"
        case .off:                     return "已关闭"
        case .permissionMissing:       return "缺少辅助功能权限"
        case .inputMonitoringMissing:  return "已授权但收不到鼠标事件"
        case .error:                   return "异常"
        }
    }
}

enum StatusIcon {
    /// 状态判定。
    ///
    /// 关键前提（实测 + 产品定位）：**权限是可选的精度增强，不是使用前提**。
    /// 默认的轮询事件源（MousePoller）零权限可用，未授权时只是命中测试退化为
    /// 「窗口列表」模式（分屏够用，窗口重叠/圆角可能判错）—— 那是正常状态，不是异常。
    /// 所以只有**当前事件源自己声明需要权限**（CGEventTap 低延迟模式）时，
    /// 「缺权限」才该报警。
    ///
    /// inputMonitoringMissing 这一态同样来自实测：未授权时 CGEvent.tapCreate **会成功**，
    /// 但系统立刻把 tap 禁用（tapIsEnabled == false）、收到 0 个事件。
    /// 只看 AXIsProcessTrusted 会漏掉「勾了辅助功能、没勾输入监控」这种情况，
    /// 用户会看到图标正常但怎么悬停都没反应。
    static func state(settings: Settings,
                      axTrusted: Bool,
                      requiresAccessibility: Bool = true,
                      inputMonitoringMissing: Bool = false,
                      driverError: String? = nil) -> IconState {
        if requiresAccessibility {
            if !axTrusted { return .permissionMissing }
            if inputMonitoringMissing { return .inputMonitoringMissing }
        }
        if !settings.enabled { return .off }
        if driverError != nil { return .error }
        return settings.mode == .focusAndRaise ? .onRaise : .on
    }

    /// 图标标识（自绘徽标没有 SF Symbol 名，这里给个稳定的 id 供 --selftest / 诊断面板显示）
    static func symbolName(for state: IconState) -> String {
        switch state {
        case .on, .onRaise:            return "custom.badge.cursor"
        case .off:                     return "custom.badge.cursor.dim"
        case .permissionMissing,
             .inputMonitoringMissing:  return "custom.badge.warning"
        case .error:                   return "custom.badge.error"
        }
    }

    // MARK: - 自绘图标

    private static let badgeGradient = NSGradient(colors: [
        NSColor(srgbRed: 0.30, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.52, green: 0.25, blue: 0.94, alpha: 1)
    ])

    /// 画一个 18×18 的徽标（分辨率无关，Retina 自动重绘）
    ///
    /// 普通状态 → **模板图**（isTemplate = true），系统自动按菜单栏/壁纸明暗染色；
    /// 告警状态 → 彩色图，主动抢注意力。
    static func makeImage(for state: IconState) -> NSImage {
        switch state {
        case .on, .onRaise:
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                drawTemplateBadge(in: rect, alpha: 1.0)
                return true
            }
            image.isTemplate = true      // ← 关键：颜色由系统决定，跟随壁纸/菜单栏
            return image
        case .off:
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                drawTemplateBadge(in: rect, alpha: 0.42)   // 淡出 = 未启用
                return true
            }
            image.isTemplate = true
            return image
        case .permissionMissing, .inputMonitoringMissing, .error:
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                drawBadge(in: rect, state: state)
                return true
            }
            image.isTemplate = false     // 彩色：异常必须醒目
            return image
        }
    }

    /// 模板图版本：只画 alpha 形状，颜色全部交给系统
    private static func drawTemplateBadge(in rect: NSRect, alpha: CGFloat) {
        let c = NSColor.black.withAlphaComponent(alpha)   // 模板图里颜色无所谓，只看 alpha
        // 圆角徽标描边
        let body = rect.insetBy(dx: 1.15, dy: 1.15)
        let outline = NSBezierPath(roundedRect: body, xRadius: 4.2, yRadius: 4.2)
        outline.lineWidth = 1.5
        c.setStroke()
        outline.stroke()
        // 光标（实心），和 App 图标同一造型
        drawCursor(in: rect, alpha: alpha, scale: 8.6)
    }

    private static func drawBadge(in rect: NSRect, state: IconState) {
        // 徽标本体（留 0.75pt 边距，避免贴边被菜单栏裁掉）
        let body = rect.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: body, xRadius: 4.6, yRadius: 4.6)

        switch state {
        case .on, .onRaise:
            badgeGradient?.draw(in: path, angle: -65)
        case .off:
            NSColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1).setFill()
            path.fill()
        case .permissionMissing, .inputMonitoringMissing:
            NSGradient(colors: [NSColor(srgbRed: 1.00, green: 0.66, blue: 0.15, alpha: 1),
                                NSColor(srgbRed: 0.95, green: 0.42, blue: 0.05, alpha: 1)])?
                .draw(in: path, angle: -65)
        case .error:
            NSGradient(colors: [NSColor(srgbRed: 1.00, green: 0.32, blue: 0.26, alpha: 1),
                                NSColor(srgbRed: 0.78, green: 0.10, blue: 0.10, alpha: 1)])?
                .draw(in: path, angle: -65)
        }

        // 顶部一层很淡的高光，让徽标有立体感（18pt 下几乎看不出，但 Retina 上有质感）
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: body.insetBy(dx: 1.1, dy: 1.1), xRadius: 3.6, yRadius: 3.6).fill()

        switch state {
        case .on, .onRaise:
            drawCursor(in: rect, alpha: 1.0)
        case .off:
            drawCursor(in: rect, alpha: 0.42)      // 灰底 + 暗淡光标 = 未启用
        case .permissionMissing, .inputMonitoringMissing, .error:
            drawBang(in: rect)
        }
    }

    /// 白色光标箭头（和 App 图标同一个造型，按 18pt 缩放）
    private static func drawCursor(in rect: NSRect, alpha: CGFloat, scale: CGFloat = 10.2) {
        // 归一化造型来自 App 图标；AppKit 非翻转坐标系 y 向上，所以要 1-y
        let shape: [(CGFloat, CGFloat)] = [
            (0.00, 0.00), (0.00, 0.735), (0.168, 0.572), (0.302, 0.868),
            (0.432, 0.808), (0.298, 0.512), (0.496, 0.512)
        ]
        let w = 0.496 * scale, h = 0.868 * scale
        let ox = rect.midX - w / 2 + 0.35
        let oy = rect.midY - h / 2

        let p = NSBezierPath()
        for (i, (px, py)) in shape.enumerated() {
            let pt = NSPoint(x: ox + px * scale, y: oy + (1 - py) * scale)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        p.fill()
        // 细描边让它在渐变上更「立」得住
        NSColor.black.withAlphaComponent(0.18 * alpha).setStroke()
        p.lineWidth = 0.7
        p.stroke()
    }

    /// 白色感叹号（权限问题 / 异常）
    private static func drawBang(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .heavy),
            .foregroundColor: NSColor.white
        ]
        let str = "!" as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                 withAttributes: attrs)
    }

    /// SF Symbol 拿不到时的兜底标题（绝不能让按钮宽度变成 0，那样图标就真的不见了）
    static func fallbackTitle(for state: IconState) -> String {
        switch state {
        case .on:                      return "HF"
        case .onRaise:                 return "HF↑"
        case .off:                     return "HF⏸"
        case .permissionMissing:       return "HF!"
        case .inputMonitoringMissing:  return "HF⌨"
        case .error:                   return "HF✗"
        }
    }

    static func tintColor(for state: IconState) -> NSColor? {
        switch state {
        case .permissionMissing:       return .systemOrange
        case .inputMonitoringMissing:  return .systemOrange
        case .error:                   return .systemRed
        case .off:                     return .secondaryLabelColor
        case .on, .onRaise:            return nil   // nil = 跟随菜单栏外观自适应
        }
    }

    /// 菜单栏首行 + tooltip 用的完整状态说明。必须说人话。
    static func summary(state: IconState, settings: Settings, axTrusted: Bool,
                        driverRunning: Bool, driverError: String?,
                        hotkeyAvailable: Bool = true) -> String {
        switch state {
        case .permissionMissing:
            return "当前选的是「低延迟 CGEventTap」监听方式，它需要「辅助功能」权限；"
                + "未授权时系统会静默丢弃所有鼠标事件，所以功能不会生效。"
                + "可以改回零权限的轮询模式（菜单 → 监听方式），或去授予权限。"
        case .inputMonitoringMissing:
            return "「辅助功能」已授权，但系统没给「输入监控」权限，CGEventTap 收不到鼠标事件。"
                + "请到「系统设置 → 隐私与安全性 → 输入监控」里勾选 HoverFocus，或改回轮询模式。"
        case .off:
            // 快捷键注册失败时不能再广告它 —— 否则用户按了没反应，而这里没有任何解释。
            return hotkeyAvailable
                ? "已关闭：悬停不会切换焦点。按 ⌃⌥H，或菜单里勾选「启用悬停切换焦点」即可打开。"
                : "已关闭：悬停不会切换焦点。菜单里勾选「启用悬停切换焦点」即可打开。"
        case .error:
            return "驱动启动失败：\(driverError ?? "未知原因")"
        case .on, .onRaise:
            var s = "已开启：\(settings.mode.displayName)"
            s += "；dwell \(Int((settings.dwellDelay * 1000).rounded()))ms"
            s += "，冷却 \(Int((settings.cooldown * 1000).rounded()))ms"
            s += "，排除名单 \(settings.excludedBundleIDs.count + settings.excludedAppNames.count) 项"
            if !driverRunning { s += "（警告：鼠标监听未在运行）" }
            return s
        }
    }

    static func tooltip(state: IconState, settings: Settings, axTrusted: Bool,
                        driverRunning: Bool, driverError: String?,
                        hotkeyAvailable: Bool = true) -> String {
        let summary = self.summary(state: state, settings: settings, axTrusted: axTrusted,
                                  driverRunning: driverRunning, driverError: driverError,
                                  hotkeyAvailable: hotkeyAvailable)
        return "\(AppInfo.versionLine)\n状态：\(state.displayName)\n\(summary)"
    }

    /// 把状态画到 NSStatusItem 的 button 上
    static func apply(to button: NSButton, state: IconState, tooltip: String) {
        let image = makeImage(for: state)
        image.accessibilityDescription = "HoverFocus \(state.displayName)"
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        // 自绘彩色图不走模板染色，所以 contentTintColor 留空（否则某些系统版本会把彩色图压成单色）
        button.contentTintColor = nil
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }
}
