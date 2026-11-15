import Foundation

/// A global shortcut: a Carbon virtual key code plus Carbon modifier flags.
/// Foundation-only (numeric Carbon constants) so the parser is unit-tested without AppKit.
struct HotKeySpec: Equatable {
    static let defaultString = "option+shift+space"

    // Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    static let cmdKey: UInt32 = 256
    static let shiftKey: UInt32 = 512
    static let optionKey: UInt32 = 2048
    static let controlKey: UInt32 = 4096

    let keyCode: UInt32
    let modifiers: UInt32

    /// ANSI virtual key codes (kVK_ANSI_*), plus kVK_Space.
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49,
    ]

    private static let modifierTokens: [String: UInt32] = [
        "cmd": cmdKey, "command": cmdKey,
        "ctrl": controlKey, "control": controlKey,
        "option": optionKey, "opt": optionKey, "alt": optionKey,
        "shift": shiftKey,
    ]

    /// `"option+shift+space"`, `"Cmd+K"`: modifiers plus exactly one key; needs at least one modifier.
    static func parse(_ string: String) -> HotKeySpec? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for raw in string.split(separator: "+", omittingEmptySubsequences: false) {
            let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if token.isEmpty { return nil }
            if let flag = modifierTokens[token] {
                modifiers |= flag
            } else if let code = keyCodes[token] {
                if key != nil { return nil }
                key = code
            } else {
                return nil
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return HotKeySpec(keyCode: key, modifiers: modifiers)
    }

    /// The character an NSMenuItem shows for this key.
    var keyEquivalent: String {
        if keyCode == 49 { return " " }
        for (name, code) in Self.keyCodes where code == keyCode && name != "space" { return name }
        return ""
    }
}
