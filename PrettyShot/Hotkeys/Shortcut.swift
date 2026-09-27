import AppKit
import Carbon.HIToolbox

/// A global shortcut: Carbon virtual key code + Carbon modifier mask.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    init(keyCode: Int, modifiers: UInt32) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbonModifiers(from: event.modifierFlags))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= command }
        if flags.contains(.shift) { result |= shift }
        if flags.contains(.option) { result |= option }
        if flags.contains(.control) { result |= control }
        return result
    }

    var hasCommandOptionOrControl: Bool {
        modifiers & (Shortcut.command | Shortcut.option | Shortcut.control) != 0
    }

    var isFunctionKey: Bool { Shortcut.functionKeys.contains(Int(keyCode)) }

    /// macOS system screenshot shortcuts: ⌘⇧3, ⌘⇧4, ⌘⇧5, ⌘⇧6 (and their ⌃ clipboard variants).
    /// PrettyShot must never claim these.
    var isSystemScreenshotShortcut: Bool {
        let keys: Set<Int> = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        return keys.contains(Int(keyCode))
            && modifiers & Shortcut.command != 0
            && modifiers & Shortcut.shift != 0
            && modifiers & Shortcut.option == 0
    }

    /// Human readable, in the standard macOS order: ⌃⌥⇧⌘ + key (e.g. "⌥⌘1").
    var displayString: String {
        var s = ""
        if modifiers & Shortcut.control != 0 { s += "⌃" }
        if modifiers & Shortcut.option != 0 { s += "⌥" }
        if modifiers & Shortcut.shift != 0 { s += "⇧" }
        if modifiers & Shortcut.command != 0 { s += "⌘" }
        return s + Shortcut.keyName(for: Int(keyCode))
    }

    static func keyName(for keyCode: Int) -> String {
        keyNames[keyCode] ?? "Key\(keyCode)"
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19",
    ]
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case captureRegion, captureWindow, captureFullscreen, openHistory, pinLatest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureRegion: return "捕获区域"
        case .captureWindow: return "捕获窗口"
        case .captureFullscreen: return "捕获全屏"
        case .openHistory: return "打开历史"
        case .pinLatest: return "Pin 最近一张"
        }
    }

    /// Defaults from DESIGN §6: ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘H / ⌥⌘P.
    var defaultShortcut: Shortcut {
        let mods = Shortcut.option | Shortcut.command
        switch self {
        case .captureRegion: return Shortcut(keyCode: kVK_ANSI_1, modifiers: mods)
        case .captureWindow: return Shortcut(keyCode: kVK_ANSI_2, modifiers: mods)
        case .captureFullscreen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: mods)
        case .openHistory: return Shortcut(keyCode: kVK_ANSI_H, modifiers: mods)
        case .pinLatest: return Shortcut(keyCode: kVK_ANSI_P, modifiers: mods)
        }
    }
}

enum ShortcutValidationError: Error, Equatable, LocalizedError {
    case needsModifier
    case reservedBySystem
    case duplicate(HotkeyAction)

    var errorDescription: String? {
        switch self {
        case .needsModifier:
            return "请至少包含 ⌘、⌥ 或 ⌃ 之一"
        case .reservedBySystem:
            return "⌘⇧3 / ⌘⇧4 / ⌘⇧5 / ⌘⇧6 是系统截图快捷键，PrettyShot 不会占用"
        case .duplicate(let action):
            return "已被「\(action.title)」使用"
        }
    }
}

enum ShortcutValidator {
    static func validate(
        _ shortcut: Shortcut,
        for action: HotkeyAction,
        existing: [HotkeyAction: Shortcut]
    ) -> ShortcutValidationError? {
        if shortcut.isSystemScreenshotShortcut { return .reservedBySystem }
        if !shortcut.hasCommandOptionOrControl && !shortcut.isFunctionKey { return .needsModifier }
        if let other = existing.first(where: { $0.key != action && $0.value == shortcut })?.key {
            return .duplicate(other)
        }
        return nil
    }
}
