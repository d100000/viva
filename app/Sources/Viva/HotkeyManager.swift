import Foundation
import AppKit

/// 「按住说话」热键。支持两种形态：
///
/// 1. **单修饰键**（右⌘ / 右⌥ / Fn…）—— 只能靠 CGEventTap 监听 `flagsChanged`，
///    因为 Carbon 的 `RegisterEventHotKey` 要求组合里必须有非修饰主键，
///    而 `NSEvent.addGlobalMonitorForEvents` 只能观察、拿不到按下/抬起时序。
/// 2. **组合键**（如 ⌃⌥Space）—— 监听 `keyDown`/`keyUp`，并吞掉事件，
///    否则按下时会往目标 App 里输入字符。
///
/// 为什么默认是右 Command 而不是 Fn：Fn 已被微信输入法和豆包输入法抢占，
/// 且大量第三方键盘根本不上报 Fn 的 flagsChanged。
final class HotkeyManager {

    /// 修饰键的「左右区分」掩码（IOKit 的 NX_DEVICE*KEYMASK）
    static let deviceMasks: [Int64: UInt64] = [
        54: 0x0000_0010,   // 右 Command
        55: 0x0000_0008,   // 左 Command
        58: 0x0000_0020,   // 左 Option
        61: 0x0000_0040,   // 右 Option
        59: 0x0000_0001,   // 左 Control
        62: 0x0000_2000,   // 右 Control
        56: 0x0000_0002,   // 左 Shift
        60: 0x0000_0004,   // 右 Shift
        63: 0x0080_0000,   // Fn（= maskSecondaryFn，不区分左右）
    ]

    /// 参与匹配的修饰键位（忽略 capsLock、numericPad 等噪声位）
    static let significantFlags: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?

    private let keyCode: Int64
    private let modifierOnly: Bool
    private let requiredModifiers: UInt64
    private let deviceMask: UInt64
    private let holdThreshold: TimeInterval

    private var isDown = false
    private var downAt: Date?
    /// onPress 是否已经发出去了。短按（未到 holdThreshold）不发 onPress，
    /// 因此也不能发 onRelease —— 否则轻点一下右⌘就会白开一次识别会话（真实计费）。
    private var pressDelivered = false
    private var holdTimer: DispatchWorkItem?

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onHealthChanged: ((Bool) -> Void)?

    init(keyCode: Int64, modifierOnly: Bool, modifiers: UInt64, holdThresholdMs: Int) {
        self.keyCode = keyCode
        self.modifierOnly = modifierOnly
        self.requiredModifiers = modifiers & Self.significantFlags
        self.deviceMask = Self.deviceMasks[keyCode] ?? 0x0000_0010
        self.holdThreshold = Double(holdThresholdMs) / 1000.0
    }

    convenience init(config: Config) {
        self.init(keyCode: config.hotkeyKeyCode,
                  modifierOnly: config.hotkeyIsModifierOnly,
                  modifiers: config.hotkeyModifiers,
                  holdThresholdMs: config.holdThresholdMs)
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: -

    func start() -> Bool {
        stop()

        // 单修饰键只需要 flagsChanged；组合键还要 keyDown/keyUp
        var mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if !modifierOnly {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
            mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        }

        // 用 .defaultTap（而不是 .listenOnly）：defaultTap 走「辅助功能」权限，
        // 而注入文本本来就需要辅助功能 —— 只要一个权限，少劝退一批用户。
        // 单修饰键一律放行不吞；组合键必须吞，否则会往目标 App 输入字符。
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("创建 CGEventTap 失败 —— 缺少「辅助功能」权限")
            return false
        }

        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        guard CGEvent.tapIsEnabled(tap: t) else {
            Log.error("CGEventTap 创建后未能启用")
            stop()
            return false
        }

        // ⭐「non-nil tap is not a healthy tap」——系统会静默禁用 tap，
        //   必须周期性校验，否则「用了一阵子热键就不灵了」。
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                Log.warn("CGEventTap 被系统禁用，自动重新启用")
                CGEvent.tapEnable(tap: tap, enable: true)
                self.onHealthChanged?(CGEvent.tapIsEnabled(tap: tap))
            }
        }

        Log.info("热键已注册：\(Self.describe(keyCode: keyCode, modifierOnly: modifierOnly, modifiers: requiredModifiers))")
        return true
    }

    func stop() {
        healthTimer?.invalidate(); healthTimer = nil
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil
        // tap 被拆掉时如果还「按着」，要补一次抬起，否则状态会永久卡在按下
        if isDown { fireRelease() }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统禁用 tap 时会投递这两种事件，必须立刻重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("收到 tapDisabled，重新启用")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            // 期间可能漏掉了抬起事件，补一次，避免卡在「按下」状态
            if isDown { fireRelease() }
            return nil
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if modifierOnly {
            guard type == .flagsChanged, code == keyCode else {
                return Unmanaged.passUnretained(event)
            }
            let down = (event.flags.rawValue & deviceMask) != 0
            Log.info("收到热键 flagsChanged：keyCode=\(code) down=\(down) flags=0x\(String(event.flags.rawValue, radix: 16))")
            if down, !isDown { firePress() } else if !down, isDown { fireRelease() }
            return Unmanaged.passUnretained(event)   // 单修饰键不吞
        }

        // ── 组合键 ──
        switch type {
        case .keyDown:
            guard code == keyCode else { return Unmanaged.passUnretained(event) }
            let flags = event.flags.rawValue & Self.significantFlags
            guard flags == requiredModifiers else { return Unmanaged.passUnretained(event) }
            // 长按会连续投递 keyDown，只认第一次
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            if !isDown { firePress() }
            return nil                                // 吞掉，别让主键输入到目标 App

        case .keyUp:
            // ⚠️ 只吞「与我们自己那次 keyDown 配对」的抬起。
            //    原来只比对 keyCode 就无条件 return nil，等于把别人的按键也吃掉 ——
            //    微信输入法劫持 Fn 被骂惨就是这个问题（别的 App 快捷键集体失灵）。
            //    isDown 只在 firePress 里置位，而 firePress 只在 keyCode 与修饰键
            //    都匹配时才调用，正好是精确的配对凭据。
            guard code == keyCode, isDown else { return Unmanaged.passUnretained(event) }
            fireRelease()
            return nil

        case .flagsChanged:
            // 主键还按着但修饰键先松了 → 当作抬起，否则会一直录下去
            if isDown {
                let flags = event.flags.rawValue & Self.significantFlags
                if flags & requiredModifiers != requiredModifiers { fireRelease() }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func firePress() {
        isDown = true
        downAt = Date()
        pressDelivered = false
        holdTimer?.cancel()
        Log.info("热键按下，等待 \(Int(holdThreshold * 1000))ms 长按阈值")

        // 按住超过阈值才真正开始录音。这样用右⌘按系统快捷键（右⌘+C 等）
        // 或手滑碰一下，都不会建 WebSocket、不会产生请求和计费。
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDown, !self.pressDelivered else { return }
            self.pressDelivered = true
            Log.info("热键长按生效")
            self.onPress?()
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func fireRelease() {
        isDown = false
        let held = downAt.map { Date().timeIntervalSince($0) } ?? 0
        downAt = nil
        holdTimer?.cancel(); holdTimer = nil

        guard pressDelivered else {
            Log.info("热键短按（\(Int(held * 1000))ms），未达 \(Int(holdThreshold * 1000))ms 阈值，忽略")
            return
        }
        pressDelivered = false
        Log.info("热键松开，持续 \(Int(held * 1000))ms")
        DispatchQueue.main.async { self.onRelease?() }
    }

    // MARK: - 展示

    /// 把热键渲染成人看得懂的样子，如「右⌘」「⌃⌥Space」
    static func describe(keyCode: Int64, modifierOnly: Bool, modifiers: UInt64) -> String {
        if modifierOnly { return modifierKeyName(keyCode) }
        var s = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        if modifiers & CGEventFlags.maskSecondaryFn.rawValue != 0 { s = "Fn" + s }
        return s + keyName(keyCode)
    }

    static func describe(_ c: Config) -> String {
        describe(keyCode: c.hotkeyKeyCode,
                 modifierOnly: c.hotkeyIsModifierOnly,
                 modifiers: c.hotkeyModifiers)
    }

    static func modifierKeyName(_ code: Int64) -> String {
        switch code {
        case 54: return "右⌘"
        case 55: return "左⌘"
        case 58: return "左⌥"
        case 61: return "右⌥"
        case 59: return "左⌃"
        case 62: return "右⌃"
        case 56: return "左⇧"
        case 60: return "右⇧"
        case 63: return "Fn"
        default: return "keyCode \(code)"
        }
    }

    /// 主键名（只覆盖常见键，其余回落到 keyCode）
    static func keyName(_ code: Int64) -> String {
        let map: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
            28: "8", 29: "0",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return map[code] ?? "键\(code)"
    }

    /// 该 keyCode 是不是修饰键
    static func isModifierKeyCode(_ code: Int64) -> Bool { deviceMasks[code] != nil }
}
