//  SettingsStore — UserDefaults 持久化实现（core-engine 所有）
//
//  契约（Contracts.swift）：
//      protocol SettingsStore { var settings: Settings { get set }; func addObserver(...) }
//
//  三条硬性要求：
//   1. key 前缀固定 "HoverFocus."；
//   2. 读出来必须过 Settings.sanitized()，非法值不能进内存 ——
//      所以内存里的 current 永远是 sanitized 过的，UI 拿到的一定是安全值；
//   3. addObserver 支持多个观察者，变更时全部回调。
//
//  行为细节（已通知 app-shell / verifier）：
//   · 只有在 sanitize 后的值与当前值**不相等**时才回调观察者（重复写同一个值不触发）。
//   · 注册观察者时**不**立刻回调一次；UI 初始化请先读一次 store.settings。
//   · 契约里没有移除观察者的 API，所以观察者只增不减（进程级单例，够用）。
//   · Contracts.sanitized() 对 NaN / Inf 无效（min/max 会原样放行），这里兜底换成默认值。

import Foundation

final class UserDefaultsSettingsStore: SettingsStore {
    /// key 前缀。全工程统一，改这里等于改磁盘格式。
    static let keyPrefix = "HoverFocus."

    enum Key {
        static let enabled = keyPrefix + "enabled"
        static let mode = keyPrefix + "mode"
        static let dwellDelay = keyPrefix + "dwellDelay"
        static let cooldown = keyPrefix + "cooldown"
        static let requireNoModifiers = keyPrefix + "requireNoModifiers"
        static let suppressWhileDragging = keyPrefix + "suppressWhileDragging"
        static let respectFullScreen = keyPrefix + "respectFullScreen"
        static let excludedBundleIDs = keyPrefix + "excludedBundleIDs"
        static let excludedAppNames = keyPrefix + "excludedAppNames"
    }

    private let defaults: UserDefaults
    private var current: Settings
    private var observers: [(Settings) -> Void] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 先把内存置成默认值，再读磁盘覆盖 —— 保证任何一步出错都不会留下未初始化状态。
        self.current = Settings.default
        self.current = load()
    }

    // MARK: - SettingsStore

    var settings: Settings {
        get { current }
        set {
            let sanitized = UserDefaultsSettingsStore.sanitize(newValue)
            guard sanitized != current else { return }
            current = sanitized
            persist(sanitized)
            notify(sanitized)
        }
    }

    func addObserver(_ callback: @escaping (Settings) -> Void) {
        observers.append(callback)
    }

    // MARK: - 读写

    private func load() -> Settings {
        let fallback = Settings.default
        let loaded = Settings(
            enabled: bool(Key.enabled, fallback: fallback.enabled),
            mode: mode(Key.mode, fallback: fallback.mode),
            dwellDelay: double(Key.dwellDelay, fallback: fallback.dwellDelay),
            cooldown: double(Key.cooldown, fallback: fallback.cooldown),
            requireNoModifiers: bool(Key.requireNoModifiers, fallback: fallback.requireNoModifiers),
            suppressWhileDragging: bool(Key.suppressWhileDragging, fallback: fallback.suppressWhileDragging),
            respectFullScreen: bool(Key.respectFullScreen, fallback: fallback.respectFullScreen),
            excludedBundleIDs: stringSet(Key.excludedBundleIDs),
            excludedAppNames: stringSet(Key.excludedAppNames)
        )
        return UserDefaultsSettingsStore.sanitize(loaded)
    }

    private func persist(_ s: Settings) {
        defaults.set(s.enabled, forKey: Key.enabled)
        defaults.set(s.mode.rawValue, forKey: Key.mode)
        defaults.set(s.dwellDelay, forKey: Key.dwellDelay)
        defaults.set(s.cooldown, forKey: Key.cooldown)
        defaults.set(s.requireNoModifiers, forKey: Key.requireNoModifiers)
        defaults.set(s.suppressWhileDragging, forKey: Key.suppressWhileDragging)
        defaults.set(s.respectFullScreen, forKey: Key.respectFullScreen)
        // Set 存成排好序的数组，磁盘内容稳定、方便人工排查。
        defaults.set(Array(s.excludedBundleIDs).sorted(), forKey: Key.excludedBundleIDs)
        defaults.set(Array(s.excludedAppNames).sorted(), forKey: Key.excludedAppNames)
    }

    private func notify(_ s: Settings) {
        // 迭代快照：观察者回调里若又改了设置（重入），不会打乱本次遍历。
        for observer in observers {
            observer(s)
        }
    }

    // MARK: - 解析（脏数据一律退回默认值）

    private func bool(_ key: String, fallback: Bool) -> Bool {
        guard let object = defaults.object(forKey: key) else { return fallback }
        if let number = object as? NSNumber { return number.boolValue }
        if let value = object as? Bool { return value }
        if let text = object as? String { return (text as NSString).boolValue }
        return fallback
    }

    private func double(_ key: String, fallback: Double) -> Double {
        guard let object = defaults.object(forKey: key) else { return fallback }
        if let number = object as? NSNumber { return number.doubleValue }
        if let text = object as? String, let value = Double(text) { return value }
        return fallback
    }

    private func mode(_ key: String, fallback: ActivationMode) -> ActivationMode {
        guard let text = defaults.object(forKey: key) as? String,
              let parsed = ActivationMode(rawValue: text) else { return fallback }
        return parsed
    }

    private func stringSet(_ key: String) -> Set<String> {
        guard let array = defaults.object(forKey: key) as? [Any] else { return [] }
        return Set(array.compactMap { $0 as? String })
    }

    // MARK: - 钳制

    /// 过一遍契约的 sanitized()，并补上它对 NaN / Inf 无能为力的那部分。
    static func sanitize(_ s: Settings) -> Settings {
        var value = s
        if !value.dwellDelay.isFinite { value.dwellDelay = Settings.default.dwellDelay }
        if !value.cooldown.isFinite { value.cooldown = Settings.default.cooldown }
        return value.sanitized()
    }
}
