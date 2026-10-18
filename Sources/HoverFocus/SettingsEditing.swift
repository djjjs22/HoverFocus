//  HoverFocus — 设置的唯一写入口
//
//  验收标准第 3 条要求「改完立刻生效并持久化（走 的 SettingsStore，别自己另存一份）」。
//  菜单和设置窗口两条 UI 路径都从这里改设置，保证：
//    - 只写 store.settings（的实现负责持久化 + 通知观察者）
//    - 每次写入都过 Settings.sanitized()
//    - 排除名单的增删规则只有一份实现（菜单和窗口行为不会不一致）

import Foundation

enum SettingsEditing {

    // MARK: - 总开关 / 模式

    static func setEnabled(_ store: SettingsStore, _ enabled: Bool) {
        var s = store.settings
        s.enabled = enabled
        write(store, s)
    }

    static func setMode(_ store: SettingsStore, _ mode: ActivationMode) {
        var s = store.settings
        s.mode = mode
        write(store, s)
    }

    // MARK: - 数值

    static func setDwellDelay(_ store: SettingsStore, _ seconds: TimeInterval) {
        var s = store.settings
        s.dwellDelay = seconds
        write(store, s)
    }

    static func setCooldown(_ store: SettingsStore, _ seconds: TimeInterval) {
        var s = store.settings
        s.cooldown = seconds
        write(store, s)
    }

    // MARK: - 守卫开关

    static func setRequireNoModifiers(_ store: SettingsStore, _ on: Bool) {
        var s = store.settings
        s.requireNoModifiers = on
        write(store, s)
    }

    static func setSuppressWhileDragging(_ store: SettingsStore, _ on: Bool) {
        var s = store.settings
        s.suppressWhileDragging = on
        write(store, s)
    }

    static func setRespectFullScreen(_ store: SettingsStore, _ on: Bool) {
        var s = store.settings
        s.respectFullScreen = on
        write(store, s)
    }

    static func resetToDefaults(_ store: SettingsStore) {
        write(store, Settings.default)
    }

    // MARK: - 排除名单

    static func isExcluded(_ settings: Settings, bundleID: String?, name: String?) -> Bool {
        if let bundleID, !bundleID.isEmpty, settings.excludedBundleIDs.contains(bundleID) { return true }
        if let name, !name.isEmpty, settings.excludedAppNames.contains(name) { return true }
        return false
    }

    /// 加一项。Bundle ID 是契约里的主键（优先），显示名是兜底。
    /// 两个都填时**只加 Bundle ID**：显示名会因为 App 改名/本地化而失效，
    /// 而且两个都加会让「移除」语义变模糊。
    @discardableResult
    static func addExclusion(_ store: SettingsStore, bundleID: String?, name: String?) -> Bool {
        var s = store.settings
        let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nm = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let bid, !bid.isEmpty {
            s.excludedBundleIDs.insert(bid)
        } else if let nm, !nm.isEmpty {
            s.excludedAppNames.insert(nm)
        } else {
            return false
        }
        write(store, s)
        return true
    }

    /// 移除一项：把该 Bundle ID 和该显示名**都**清掉，避免「移除了还在名单里」的错觉
    /// （用户可能先后用两种方式加过同一个 App）。
    @discardableResult
    static func removeExclusion(_ store: SettingsStore, bundleID: String?, name: String?) -> Bool {
        var s = store.settings
        var changed = false
        if let bundleID, s.excludedBundleIDs.remove(bundleID) != nil { changed = true }
        if let name, s.excludedAppNames.remove(name) != nil { changed = true }
        guard changed else { return false }
        write(store, s)
        return true
    }

    /// 菜单里的「排除当前 App / 取消排除当前 App」
    @discardableResult
    static func toggleExclusion(_ store: SettingsStore, bundleID: String?, name: String?) -> Bool {
        if isExcluded(store.settings, bundleID: bundleID, name: name) {
            removeExclusion(store, bundleID: bundleID, name: name)
            return false
        } else {
            addExclusion(store, bundleID: bundleID, name: name)
            return true
        }
    }

    // MARK: - 唯一写点

    /// 所有写操作都过这里：钳制非法值 + 一次性写回 store。
    private static func write(_ store: SettingsStore, _ settings: Settings) {
        let clean = settings.sanitized()
        store.settings = clean
        Log.info("设置已更新：enabled=\(clean.enabled) mode=\(clean.mode.rawValue) "
                 + "dwell=\(String(format: "%.3f", clean.dwellDelay)) "
                 + "cooldown=\(String(format: "%.3f", clean.cooldown)) "
                 + "排除=\(clean.excludedBundleIDs.count)个bundleID/\(clean.excludedAppNames.count)个名称")
    }
}
