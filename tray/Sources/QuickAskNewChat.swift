import Foundation

/// Pure rules for the Quick Ask panel's "New chat" action (Foundation-only so tray/test.sh covers them).
enum QuickAskNewChat {
    /// The button shows (and Cmd+N works) in a chat or with typed pre-chat text, but not while the
    /// first question is still being sent.
    static func isAvailable(inChat: Bool, hasDraft: Bool, isSending: Bool) -> Bool {
        (inChat || hasDraft) && !isSending
    }

    /// The target the fresh pre-chat panel should select: the one the chat was with, else the picker's.
    static func preselectTarget(chatTargetId: String?, selectedTargetId: String?) -> String? {
        chatTargetId ?? selectedTargetId
    }

    /// Cmd+N: a lowercase "n" with only Command held.
    static func isShortcut(characters: String?, command: Bool, shift: Bool, option: Bool, control: Bool) -> Bool {
        command && !shift && !option && !control && characters == "n"
    }
}
