import AppKit
import Carbon.HIToolbox

/// 「粘贴上一段」的全局快捷键 ⌃⌥⌘V。
///
/// 用 Carbon 的 RegisterEventHotKey 而不是复用 HotkeyManager 的 CGEventTap ——
/// 普通组合热键这条老 API 完全够用，**不需要任何权限**（连辅助功能都不用），
/// 而且系统层面保证吞键，绝不会把 V 漏进当前 App。
/// （HotkeyManager 用 .defaultTap 是为了单修饰键 + 按住/松开时序，这里用不上。）
///
/// 快捷键选 ⌃⌥⌘V：三修饰键组合几乎没有 App 占用，
/// 又和「粘贴」的肌肉记忆（⌘V）同一个主键，好记。
@MainActor
final class PasteLastHotkey {
    static let shared = PasteLastHotkey()
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // C 回调不能捕获上下文，userData 里带 self 回来
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<PasteLastHotkey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in me.onTrigger?() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x56495641) /* 'VIVA' */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V),
                                         UInt32(controlKey | optionKey | cmdKey),
                                         hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status != noErr {
            // 撞车（被其它 App 占了）不致命：菜单栏入口仍然可用
            Log.warn("注册粘贴快捷键 ⌃⌥⌘V 失败（OSStatus \(status)），可能被其它应用占用")
        } else {
            Log.info("已注册全局快捷键 ⌃⌥⌘V：粘贴上一段")
        }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}
