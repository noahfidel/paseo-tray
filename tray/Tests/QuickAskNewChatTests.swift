import Foundation

func runQuickAskNewChatTests() {
    typealias N = QuickAskNewChat
    expect(N.isAvailable(inChat: true, hasDraft: false, isSending: false), "newchat: available in a chat")
    expect(N.isAvailable(inChat: false, hasDraft: true, isSending: false), "newchat: available with a draft")
    expect(!N.isAvailable(inChat: false, hasDraft: false, isSending: false), "newchat: hidden on an empty pre-chat panel")
    expect(!N.isAvailable(inChat: true, hasDraft: false, isSending: true), "newchat: unavailable while sending (chat)")
    expect(!N.isAvailable(inChat: false, hasDraft: true, isSending: true), "newchat: unavailable while sending (draft)")

    expect(N.preselectTarget(chatTargetId: "bot:a", selectedTargetId: "bot:b") == "bot:a", "newchat: chat target wins")
    expect(N.preselectTarget(chatTargetId: nil, selectedTargetId: "bot:b") == "bot:b", "newchat: picker selection without a chat")
    expect(N.preselectTarget(chatTargetId: nil, selectedTargetId: nil) == nil, "newchat: nothing to preselect")

    expect(N.isShortcut(characters: "n", command: true, shift: false, option: false, control: false), "newchat: Cmd+N")
    expect(!N.isShortcut(characters: "n", command: false, shift: false, option: false, control: false), "newchat: plain n")
    expect(!N.isShortcut(characters: "n", command: true, shift: true, option: false, control: false), "newchat: Cmd+Shift+N")
    expect(!N.isShortcut(characters: "n", command: true, shift: false, option: true, control: false), "newchat: Cmd+Option+N")
    expect(!N.isShortcut(characters: "n", command: true, shift: false, option: false, control: true), "newchat: Cmd+Ctrl+N")
    expect(!N.isShortcut(characters: "N", command: true, shift: false, option: false, control: false), "newchat: uppercase N")
    expect(!N.isShortcut(characters: "m", command: true, shift: false, option: false, control: false), "newchat: Cmd+M")
    expect(!N.isShortcut(characters: nil, command: true, shift: false, option: false, control: false), "newchat: no characters")
}
