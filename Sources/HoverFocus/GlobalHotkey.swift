//  GlobalHotkey — 全局快捷键（Lead 所有）
//
//  为什么用 Carbon `RegisterEventHotKey` 而不是 NSEvent：
//    - `NSEvent.addGlobalMonitorForEvents` **需要辅助功能权限**，而且拿不到「消费掉这个按键」
//      的能力（只能旁观）。用它做暂停开关，等于「为了关掉一个功能还得先授权」。
//    - Carbon 的 RegisterEventHotKey **零权限**，对 LSUIElement（无 Dock 图标）应用同样有效，
//      而且系统会把按键从当前前台 App 手里截走 —— 这正是「全局快捷键」该有的语义。
//      Carbon 虽然在淘汰中，但这个 API 是当前唯一零权限的全局热键方案，且 macOS 27 仍然可用
//      （本机实测通过）。
//
//  失败语义：注册失败（例如快捷键已被别的 App 占用）必须 fail-soft —— 返回 false、
//  由调用方在菜单里如实告诉用户，**绝不静默**。用户按了没反应却没有任何解释，是最糟的体验。

import AppKit
import Carbon.HIToolbox

final class GlobalHotkey {

    /// 四个字符的签名，用于区分我们自己的热键事件
    private static let signature: OSType = 0x48464B59   // 'HFKY'

    /// InstallEventHandler 的 C 回调不能捕获上下文，所以用静态弱引用找回实例。
    /// 只有一个全局热键，够用；要支持多个再改成注册表。
    private static weak var active: GlobalHotkey?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    private(set) var isRegistered = false

    /// 注册一个全局热键。重复调用会先注销旧的（幂等）。
    /// - Returns: 成功 true；失败 false（调用方必须把这个结果告诉用户）
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        onFire = handler
        Self.active = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                GlobalHotkey.active?.onFire?()
                return noErr
            },
            1, &eventType, nil, &eventHandlerRef)

        guard installStatus == noErr else {
            cleanupAfterFailure()
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            cleanupAfterFailure()
            return false
        }

        isRegistered = true
        return true
    }

    /// 注销。幂等，未注册时调用安全。
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onFire = nil
        isRegistered = false
    }

    /// 注册中途失败：别留半截状态（handler 装了但热键没注册上，会留下一个空转的事件处理器）
    private func cleanupAfterFailure() {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onFire = nil
        if Self.active === self { Self.active = nil }
        isRegistered = false
    }

    deinit { unregister() }
}
