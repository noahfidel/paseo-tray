import AppKit
import Foundation

/// Floating panel for talking to a paseo-bots bot from the tray.
/// Prompt mode: type a first message, send it, and the caller opens the new chat in Paseo.
/// Quick Ask mode: pick a bot, ask, and the reply streams into the panel; follow-ups continue
/// that chat. The panel never opens Paseo itself; only "Open in Paseo" asks the caller to.
/// Something Quick Ask can message: a paseo-bots bot (new chat) or a Flowly dispatcher (its existing chat).
enum QuickAskTarget: Equatable {
    case bot(TrayBot)
    case dispatcher(TrayDispatcher)
}

final class QuickAskPanel: NSPanel, NSTextViewDelegate {
    enum Mode {
        case prompt(bot: TrayBot)
        case quickAsk
    }

    static let maxPromptLength = 20_000

    /// Prompt mode: called with the bot and the validated (trimmed, 1...20,000 UTF-16 units) prompt.
    var onSubmit: ((TrayBot, String) -> Void)?
    /// Quick Ask: first question to the picked bot or dispatcher (validated like `onSubmit`).
    var onAsk: ((QuickAskTarget, String) -> Void)?
    /// Quick Ask: a follow-up in the chat `chatStarted` or `chatReopened` opened. Call `clearFollowUp` once sent.
    var onFollowUp: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onOpenInPaseo: (() -> Void)?
    /// The panel closed or was reset for a new mode; any chat it showed is over.
    var onClose: (() -> Void)?
    /// The panel stopped showing its chat (New chat): the owner stops watching it. Unlike `onClose`, the panel stays.
    var onChatEnded: (() -> Void)?
    /// Quick Ask: the user picked a target in the picker; return false to refuse it (another panel
    /// owns it) and the picker goes back to its previous selection.
    var onPickTarget: ((String) -> Bool)?
    /// History clicked: fetch the chats of the bot with this raw id, then answer with `showHistory`
    /// or `historyFailed` and the same token (may be called back synchronously).
    var onHistory: ((_ botId: String, _ token: Int) -> Void)?
    /// A History menu row was picked (its agent id).
    var onPickHistory: ((String) -> Void)?
    /// Supplies bot avatars (header, picker).
    var avatarProvider: ((TrayBot) -> NSImage)?

    private(set) var mode: Mode?
    private(set) var isSending = false
    /// Changes whenever the panel is reset or closed, so a late reply for an older send is ignored.
    private(set) var session = 0
    /// The agent whose chat Quick Ask is showing.
    private(set) var chatAgentId: String?
    /// The picker id (`QuickAskTargets`) of the target the chat was started with.
    private(set) var chatTargetId: String?

    /// Quick Ask's target: the chat's target once a chat started, else the picker selection (or the
    /// target asked for before the picker had it).
    var targetId: String? {
        guard case .quickAsk? = mode else { return nil }
        if chatAgentId != nil { return chatTargetId }
        return pendingTargetId ?? selectedTargetId
    }

    /// True while Quick Ask is on screen (whether or not a chat has started).
    var isQuickAskVisible: Bool {
        if case .quickAsk? = mode { return isVisible }
        return false
    }

    // Prompt mode
    private let promptContent = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 230))
    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private var currentBot: TrayBot?

    // Quick Ask mode
    private let quickContent = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 250))
    private let botPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headerOpenButton = NSButton(title: "", target: nil, action: nil)
    private let headerNewChatButton = NSButton(title: "", target: nil, action: nil)
    private let headerHistoryButton = NSButton(title: "", target: nil, action: nil)
    /// New chat, History, Open in Paseo; hidden buttons drop out of the row.
    private let headerStack = NSStackView()
    /// "Earlier messages are in Paseo" above the transcript of a chat with older entries.
    private let olderNote = NSStackView()
    private let olderLabel = NSTextField(labelWithString: "")
    private let olderButton = NSButton(title: "", target: nil, action: nil)
    private let transcript = ChatTranscriptView(frame: .zero)
    private let banner = NSBox()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let bannerButton = NSButton(title: "", target: nil, action: nil)
    private let inputTextView = NSTextView()
    private let inputScroll = NSScrollView()
    private let quickErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let quickHintLabel = NSTextField(labelWithString: "")
    private let quickSendButton = NSButton(title: "", target: nil, action: nil)
    private let stopButton = NSButton(title: "", target: nil, action: nil)
    private(set) var bots: [TrayBot] = []
    /// The bots fetch finished (loaded or failed): a pending target missing by now never arrives.
    private var botsSettled = false
    private var botsFetch = BotsFetchGate()
    private(set) var dispatchers: [TrayDispatcher] = []
    private var turnRunning = false
    /// A target asked for before the picker had it (bots load asynchronously); applied by the next rebuild.
    private var pendingTargetId: String?
    /// The selection was chosen by the user or the menu (kept across rebuilds), not defaulted to the first entry.
    private var selectionIsExplicit = false
    /// The picker selection last accepted, to go back to when `onPickTarget` refuses a pick.
    private var selectedTargetId: String?
    /// A follow-up was sent and no render has confirmed the real turn state yet.
    private var followUpPending = false
    /// Only the latest History request may open the menu.
    private var historyToken = HistoryFetchToken()
    /// The History request in flight (its token and the target it was asked for); the button is disabled meanwhile.
    private var historyRequest: (token: Int, targetId: String)?
    /// The error line shows a History failure (cleared by the next History click).
    private var historyErrorShown = false
    private var olderShownConstraints: [NSLayoutConstraint] = []
    private var olderHiddenConstraints: [NSLayoutConstraint] = []
    private var preChatConstraints: [NSLayoutConstraint] = []
    private var chatConstraints: [NSLayoutConstraint] = []
    private var bannerShownConstraints: [NSLayoutConstraint] = []
    private var bannerHiddenConstraints: [NSLayoutConstraint] = []
    private var errorShownConstraints: [NSLayoutConstraint] = []
    private var errorHiddenConstraints: [NSLayoutConstraint] = []

    private static let promptStyle: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .utilityWindow]
    private static let quickAskStyle: NSWindow.StyleMask = promptStyle.union(.resizable)
    private static let quickAskSize = NSSize(width: 520, height: 250)
    private static let quickChatSize = NSSize(width: 520, height: 560)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
            styleMask: Self.promptStyle,
            backing: .buffered,
            defer: true
        )
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        buildPromptContent()
        buildQuickContent()
        contentView = promptContent
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        session += 1
        botsFetch.reset()
        invalidateHistory()
        isSending = false
        chatAgentId = nil
        chatTargetId = nil
        onClose?()
    }

    // MARK: - Presenting

    /// `cascadeFrom`: the frame of the last panel opened, so a new one is offset from it instead of
    /// covering it exactly.
    func present(mode: Mode, cascadeFrom: NSRect? = nil) {
        // Quick Ask already on screen: bring it forward as it is (keeps a chat in progress).
        if case .quickAsk = mode, isQuickAskVisible {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            makeFirstResponder(inputTextView)
            return
        }
        // Any earlier send (even one still in flight) belongs to the old session now.
        session += 1
        invalidateHistory()
        if chatAgentId != nil {
            chatAgentId = nil
            chatTargetId = nil
            onClose?()
        }
        self.mode = mode
        switch mode {
        case .prompt(let bot):
            styleMask = Self.promptStyle
            contentView = promptContent
            currentBot = bot
            title = L("New chat", "新建对话")
            nameLabel.stringValue = bot.name
            avatarView.image = avatarProvider?(bot)
            textView.string = ""
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            sendButton.title = L("Send", "发送")
            hintLabel.stringValue = L("Enter to send, Shift-Enter for a new line", "回车发送，Shift-回车换行")
            setSending(false)
            positionNearTop(contentSize: NSSize(width: 480, height: 230))
        case .quickAsk:
            styleMask = Self.quickAskStyle
            contentView = quickContent
            title = L("Quick Ask", "快速提问")
            resetQuickAsk()
            positionNearTop(contentSize: Self.quickAskSize, cascadeFrom: cascadeFrom)
        }
        // The panel can become key without making the tray the active app, but a tray
        // (accessory) app often won't route typing to it unless it is active. Activating
        // the tray itself does not bring Paseo forward.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if case .quickAsk = mode {
            makeFirstResponder(inputTextView)
        } else {
            makeFirstResponder(textView)
        }
    }

    func showError(_ message: String) {
        if case .quickAsk? = mode {
            historyErrorShown = false
            quickErrorLabel.stringValue = message
            setQuickErrorVisible(true)
            return
        }
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        resizeForError()
    }

    func clearError() {
        if case .quickAsk? = mode {
            historyErrorShown = false
            quickErrorLabel.stringValue = ""
            setQuickErrorVisible(false)
            return
        }
        guard !errorLabel.isHidden else { return }
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        resizeForError()
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        if sending {
            clearError()
            // A History answer must not open a menu over a send.
            invalidateHistory()
        }
        if case .quickAsk? = mode {
            updateQuickControls()
            return
        }
        sendButton.isEnabled = !sending
        textView.isEditable = !sending
    }

    // MARK: - Quick Ask

    /// Starts a bots fetch (or a refetch after a failure): targets asked for now stay pending until
    /// it ends. Returns its token, or nil when a fetch is already running in this panel (that one
    /// will settle the picker).
    func botsFetchStarted() -> Int? {
        guard let token = botsFetch.start() else { return nil }
        botsSettled = false
        return token
    }

    /// The fetch with `token` finished: true when it is still the latest one, so its result may be
    /// applied (`setBots`, `showError`); a stale result must be dropped.
    func botsFetchFinished(_ token: Int) -> Bool {
        botsFetch.finish(token)
    }

    /// Fills the bot part of the picker (API order; recents decide the display order).
    func setBots(_ bots: [TrayBot]) {
        self.bots = bots
        botsSettled = true
        rebuildPicker()
    }

    /// Fills the dispatcher part of the picker (store order).
    func setDispatchers(_ dispatchers: [TrayDispatcher]) {
        self.dispatchers = dispatchers
        rebuildPicker()
    }

    private func rebuildPicker() {
        // A pending target survives rebuilds that don't contain it yet (dispatchers arrive before bots).
        let previous = botPopup.selectedItem?.representedObject as? String
        botPopup.removeAllItems()
        let entries = QuickAskTargets.items(
            bots: bots.map { (id: $0.id, title: $0.name) },
            dispatchers: dispatchers.map { (id: $0.agentId, groupId: $0.groupId, title: $0.menuTitle) },
            recent: BotRecents.recentIds())
        if entries.isEmpty {
            botPopup.addItem(withTitle: L("No bots", "没有机器人"))
            botPopup.lastItem?.isEnabled = false
        } else {
            for entry in entries {
                switch entry {
                case .separator:
                    botPopup.menu?.addItem(.separator())
                case .header(let title):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    botPopup.menu?.addItem(item)
                case .item(let id, let title):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.representedObject = id
                    if let bot = bots.first(where: { QuickAskTargets.botId($0.id) == id }) {
                        item.image = avatarProvider?(bot)
                        if !bot.title.isEmpty { item.toolTip = bot.title }
                    }
                    botPopup.menu?.addItem(item)
                }
            }
            let ids = botPopup.itemArray.compactMap { $0.representedObject as? String }
            let choice = QuickAskTargets.selection(ids: ids, current: previous,
                                                   currentIsExplicit: selectionIsExplicit, pending: pendingTargetId,
                                                   pendingMayArrive: !botsSettled)
            if let id = choice.id, let index = botPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
                botPopup.selectItem(at: index)
            }
            selectionIsExplicit = choice.explicit
            if choice.pendingCleared { pendingTargetId = nil }
        }
        // Nothing to pick and the bots fetch is over: a pending target isn't coming.
        if entries.isEmpty, botsSettled { pendingTargetId = nil }
        selectedTargetId = botPopup.selectedItem?.representedObject as? String
        updateQuickControls()
    }

    /// Re-reads avatars, for when a remote avatar image finished loading.
    func refreshAvatars() {
        if let currentBot, case .prompt? = mode { avatarView.image = avatarProvider?(currentBot) }
        for item in botPopup.itemArray {
            guard let id = item.representedObject as? String, let bot = bots.first(where: { QuickAskTargets.botId($0.id) == id }) else { continue }
            item.image = avatarProvider?(bot)
        }
    }

    /// The first question started a chat: switch to the transcript and follow-up box.
    /// `targetId` is the picker id of the bot or dispatcher asked; it stays the panel's target.
    func chatStarted(agentId: String, targetId: String) {
        guard case .quickAsk? = mode else { return }
        chatAgentId = agentId
        chatTargetId = targetId
        inputTextView.string = ""
        // The first turn is already running; the first render corrects this.
        turnRunning = true
        showChatLayout()
    }

    /// A chat picked from History: the chat layout like `chatStarted`, but nothing is assumed about
    /// its turn (the first render sets Stop/Send), the typed text stays as the follow-up draft, and
    /// `session` is left alone so an in-flight bots fetch still lands. Works pre-chat and from
    /// another chat (the owner releases that chat's watch first).
    func chatReopened(agentId: String, targetId: String) {
        guard case .quickAsk? = mode else { return }
        invalidateHistory()
        clearError()
        // From another chat the panel keeps its size (the user may have resized it).
        let wasInChat = chatAgentId != nil
        chatAgentId = agentId
        chatTargetId = targetId
        turnRunning = false
        followUpPending = false
        showChatLayout(resize: !wasInChat)
    }

    private func showChatLayout(resize: Bool = true) {
        transcript.update(rows: [])
        setOlderNoteVisible(false)
        NSLayoutConstraint.deactivate(preChatConstraints)
        NSLayoutConstraint.activate(chatConstraints)
        transcript.isHidden = false
        headerOpenButton.isHidden = false
        botPopup.isEnabled = false
        setBannerVisible(false)
        contentMinSize = NSSize(width: 420, height: 380)
        if resize { resizeKeepingTop(contentSize: Self.quickChatSize) }
        updateQuickControls()
        makeFirstResponder(inputTextView)
    }

    func render(_ state: TimelineState) {
        guard case .quickAsk? = mode, chatAgentId != nil else { return }
        transcript.update(rows: state.rows)
        setOlderNoteVisible(state.hasOlder)
        let hasUnsupported = state.rows.contains { if case .unsupported = $0 { return true } else { return false } }
        if state.pendingPermission {
            bannerLabel.stringValue = L("Waiting for your approval", "等待你的批准")
        } else if hasUnsupported {
            bannerLabel.stringValue = L("Some items can only be shown in Paseo", "部分内容只能在 Paseo 中查看")
        }
        setBannerVisible(state.pendingPermission || hasUnsupported)
        turnRunning = state.turn == .running
        followUpPending = false
        updateQuickControls()
    }

    /// The follow-up went out; empty the box and treat the turn as running until
    /// the next render shows the real state (blocks a second send before turn_started).
    func clearFollowUp() {
        inputTextView.string = ""
        turnRunning = true
        followUpPending = true
        updateQuickControls()
    }

    /// A send that never left: put the typed text back and let the user try again.
    func restoreInput(_ text: String) {
        guard chatAgentId != nil else { return }
        inputTextView.string = text
        turnRunning = false
        followUpPending = false
        updateQuickControls()
    }

    /// The daemon rejected the follow-up: undo the optimistic running state so the panel isn't stuck.
    func followUpFailed() {
        guard followUpPending else { return }
        followUpPending = false
        turnRunning = false
        updateQuickControls()
    }

    private func resetQuickAsk() {
        pendingTargetId = nil
        selectionIsExplicit = false
        selectedTargetId = nil
        bots = []
        botsSettled = false
        botsFetch.reset()
        dispatchers = []
        botPopup.removeAllItems()
        botPopup.addItem(withTitle: L("Loading bots…", "正在加载机器人…"))
        botPopup.lastItem?.isEnabled = false
        resetQuickAskUI()
    }

    /// Back to the empty pre-chat layout; the picker contents are left as they are.
    private func resetQuickAskUI() {
        invalidateHistory()
        chatAgentId = nil
        chatTargetId = nil
        turnRunning = false
        followUpPending = false
        botPopup.isEnabled = true
        inputTextView.string = ""
        transcript.update(rows: [])
        transcript.isHidden = true
        setOlderNoteVisible(false)
        headerOpenButton.isHidden = true
        NSLayoutConstraint.deactivate(chatConstraints)
        NSLayoutConstraint.activate(preChatConstraints)
        setBannerVisible(false)
        quickErrorLabel.stringValue = ""
        setQuickErrorVisible(false)
        quickHintLabel.stringValue = L("Enter to send, Shift-Enter for a new line", "回车发送，Shift-回车换行")
        quickSendButton.title = L("Ask", "提问")
        contentMinSize = NSSize(width: 420, height: 200)
        isSending = false
        updateQuickControls()
    }

    /// Whether "New chat" (the header button and Cmd+N) can be used now.
    private var isNewChatAvailable: Bool {
        guard case .quickAsk? = mode else { return false }
        return QuickAskNewChat.isAvailable(inChat: chatAgentId != nil, hasDraft: hasDraft, isSending: isSending)
    }

    /// Leaves the current chat (or draft) for a fresh one without closing the panel. Nothing is
    /// cancelled or deleted in Paseo: a running turn keeps running, the panel just stops watching.
    func startNewChat() {
        // Never while the first question is sending, so no send result can land in the fresh panel.
        // `session` stays: bumping it would drop an in-flight bots fetch and strand the picker.
        guard isNewChatAvailable else { return }
        let target = QuickAskNewChat.preselectTarget(chatTargetId: chatTargetId, selectedTargetId: selectedTargetId)
        let wasInChat = chatAgentId != nil
        resetQuickAskUI()
        if wasInChat { onChatEnded?() }
        resizeKeepingTop(contentSize: Self.quickAskSize)
        if let target { selectTarget(id: target) }
        makeFirstResponder(inputTextView)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if case .quickAsk? = mode, isNewChatAvailable,
           QuickAskNewChat.isShortcut(characters: event.charactersIgnoringModifiers,
                                      command: flags.contains(.command), shift: flags.contains(.shift),
                                      option: flags.contains(.option), control: flags.contains(.control)) {
            startNewChat()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Text typed before a chat started (a retarget would move it to another target).
    var hasDraft: Bool {
        chatAgentId == nil && !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedTarget: QuickAskTarget? {
        guard let id = botPopup.selectedItem?.representedObject as? String else { return nil }
        if let bot = bots.first(where: { QuickAskTargets.botId($0.id) == id }) { return .bot(bot) }
        if let dispatcher = dispatchers.first(where: { QuickAskTargets.dispatcherId($0.agentId) == id }) {
            return .dispatcher(dispatcher)
        }
        return nil
    }

    /// Selects a picker target by its QuickAskTargets id; when it isn't in the picker yet, the next rebuild selects it.
    func selectTarget(id: String) {
        guard let index = botPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) else {
            // Wait for it only while the bots are still loading; after that it isn't coming.
            if !botsSettled { pendingTargetId = id }
            return
        }
        pendingTargetId = nil
        selectionIsExplicit = true
        botPopup.selectItem(at: index)
        if id != selectedTargetId { invalidateHistory() }
        selectedTargetId = id
        updateQuickControls()
    }

    private func updateQuickControls() {
        let inChat = chatAgentId != nil
        quickSendButton.title = inChat ? L("Send", "发送") : L("Ask", "提问")
        let showStop = inChat && turnRunning
        stopButton.isHidden = !showStop
        quickSendButton.isHidden = showStop
        quickSendButton.isEnabled = !isSending && (inChat || selectedTarget != nil)
        inputTextView.isEditable = !isSending
        botPopup.isEnabled = !inChat && !isSending && !(bots.isEmpty && dispatchers.isEmpty)
        headerNewChatButton.isHidden = !isNewChatAvailable
        headerHistoryButton.isHidden = !isHistoryAvailable
        headerHistoryButton.isEnabled = historyRequest == nil
    }

    // MARK: - History

    /// Quick Ask on a bot (in a chat or picked pre-chat), not while the first question is sending.
    private var isHistoryAvailable: Bool {
        guard case .quickAsk? = mode else { return false }
        return QuickAskHistory.isAvailable(targetId: targetId, isSending: isSending)
    }

    /// Drops the History request in flight: its answer opens no menu and shows no error.
    private func invalidateHistory() {
        historyToken.invalidate()
        guard historyRequest != nil else { return }
        historyRequest = nil
        updateQuickControls()
    }

    /// The answer for `token` may still be used: ends the request (re-enabling the button) and
    /// returns true when the panel is still on the target it was asked for, visible and not sending.
    private func finishHistoryRequest(_ token: Int) -> Bool {
        guard let request = historyRequest, request.token == token, historyToken.isCurrent(token) else { return false }
        historyRequest = nil
        updateQuickControls()
        return isVisible && !isSending && targetId == request.targetId && isHistoryAvailable
    }

    /// The bot's chats arrived: pops the History menu under the button.
    func showHistory(_ entries: [QuickAskHistory.Entry], token: Int) {
        guard finishHistoryRequest(token) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if entries.isEmpty {
            let item = NSMenuItem(title: L("No earlier chats", "没有更早的对话"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let now = Date()
            for entry in entries {
                let title = QuickAskHistory.displayTitle(entry.title)
                let time = QuickAskHistory.relativeTime(from: entry.updatedAt, now: now)
                let item = NSMenuItem(title: "\(title) — \(time)", action: #selector(historyRowPicked(_:)), keyEquivalent: "")
                let row = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                row.append(NSAttributedString(string: "  \(time)", attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = row
                item.target = self
                item.representedObject = entry.agentId
                item.state = entry.agentId == chatAgentId ? .on : .off
                menu.addItem(item)
            }
        }
        let button = headerHistoryButton
        let below = button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: below), in: button)
    }

    /// The History request failed: shows the error line, no menu.
    func historyFailed(_ message: String, token: Int) {
        guard finishHistoryRequest(token) else { return }
        showError(message)
        historyErrorShown = true
    }

    @objc private func historyTapped() {
        guard isHistoryAvailable, historyRequest == nil, let target = targetId,
              let botId = QuickAskHistory.rawBotId(fromTargetId: target) else { return }
        if historyErrorShown { clearError() }
        let token = historyToken.start()
        historyRequest = (token, target)
        updateQuickControls()
        onHistory?(botId, token)
    }

    @objc private func historyRowPicked(_ sender: NSMenuItem) {
        guard let agentId = sender.representedObject as? String else { return }
        onPickHistory?(agentId)
    }

    private func setOlderNoteVisible(_ visible: Bool) {
        guard olderNote.isHidden == visible else { return }
        olderNote.isHidden = !visible
        NSLayoutConstraint.deactivate(visible ? olderHiddenConstraints : olderShownConstraints)
        NSLayoutConstraint.activate(visible ? olderShownConstraints : olderHiddenConstraints)
    }

    private func setBannerVisible(_ visible: Bool) {
        banner.isHidden = !visible
        NSLayoutConstraint.deactivate(visible ? bannerHiddenConstraints : bannerShownConstraints)
        NSLayoutConstraint.activate(visible ? bannerShownConstraints : bannerHiddenConstraints)
    }

    private func setQuickErrorVisible(_ visible: Bool) {
        quickErrorLabel.isHidden = !visible
        NSLayoutConstraint.deactivate(visible ? errorHiddenConstraints : errorShownConstraints)
        NSLayoutConstraint.activate(visible ? errorShownConstraints : errorHiddenConstraints)
    }

    // MARK: - Layout

    private func buildPromptContent() {
        let content = promptContent

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        configureInput(textView, in: scrollView)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: 12)
        errorLabel.isHidden = true
        errorLabel.preferredMaxLayoutWidth = 440

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendTapped)

        for view in [avatarView, nameLabel, scrollView, errorLabel, hintLabel, sendButton] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            avatarView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 28),
            avatarView.heightAnchor.constraint(equalToConstant: 28),

            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nameLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 12),
            scrollView.heightAnchor.constraint(equalToConstant: 100),

            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            errorLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),

            hintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hintLabel.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            sendButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            sendButton.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 8),
        ])
    }

    private func configureInput(_ textView: NSTextView, in scrollView: NSScrollView) {
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    private func buildQuickContent() {
        let content = quickContent

        botPopup.translatesAutoresizingMaskIntoConstraints = false
        botPopup.target = self
        botPopup.action = #selector(botChanged)
        // Keep the "Dispatchers" header (and "No bots") disabled: auto-enabling would make them selectable.
        botPopup.autoenablesItems = false

        headerOpenButton.translatesAutoresizingMaskIntoConstraints = false
        headerOpenButton.title = L("Open in Paseo", "在 Paseo 中打开")
        headerOpenButton.isBordered = false
        headerOpenButton.contentTintColor = .linkColor
        headerOpenButton.font = NSFont.systemFont(ofSize: 12)
        headerOpenButton.target = self
        headerOpenButton.action = #selector(openInPaseoTapped)
        headerOpenButton.isHidden = true
        headerOpenButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerNewChatButton.translatesAutoresizingMaskIntoConstraints = false
        headerNewChatButton.title = L("New chat", "新建对话")
        headerNewChatButton.toolTip = L("New chat (⌘N)", "新建对话 (⌘N)")
        headerNewChatButton.isBordered = false
        headerNewChatButton.contentTintColor = .linkColor
        headerNewChatButton.font = NSFont.systemFont(ofSize: 12)
        headerNewChatButton.target = self
        headerNewChatButton.action = #selector(newChatTapped)
        headerNewChatButton.isHidden = true
        headerNewChatButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerHistoryButton.translatesAutoresizingMaskIntoConstraints = false
        headerHistoryButton.title = L("History", "历史记录")
        headerHistoryButton.toolTip = L("Earlier chats with this bot", "与该机器人的较早对话")
        headerHistoryButton.isBordered = false
        headerHistoryButton.contentTintColor = .linkColor
        headerHistoryButton.font = NSFont.systemFont(ofSize: 12)
        headerHistoryButton.target = self
        headerHistoryButton.action = #selector(historyTapped)
        headerHistoryButton.isHidden = true
        headerHistoryButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.spacing = 12
        headerStack.detachesHiddenViews = true
        for button in [headerNewChatButton, headerHistoryButton, headerOpenButton] {
            headerStack.addArrangedSubview(button)
        }

        olderLabel.stringValue = L("Earlier messages are in Paseo", "更早的消息在 Paseo 中")
        olderLabel.font = NSFont.systemFont(ofSize: 11)
        olderLabel.textColor = .secondaryLabelColor
        olderLabel.lineBreakMode = .byTruncatingTail
        olderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        olderButton.title = L("Open in Paseo", "在 Paseo 中打开")
        olderButton.isBordered = false
        olderButton.contentTintColor = .linkColor
        olderButton.font = NSFont.systemFont(ofSize: 11)
        olderButton.target = self
        olderButton.action = #selector(openInPaseoTapped)
        olderButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        olderNote.translatesAutoresizingMaskIntoConstraints = false
        olderNote.orientation = .horizontal
        olderNote.spacing = 6
        olderNote.addArrangedSubview(olderLabel)
        olderNote.addArrangedSubview(olderButton)
        olderNote.isHidden = true

        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.isHidden = true

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.boxType = .custom
        banner.titlePosition = .noTitle
        banner.cornerRadius = 6
        banner.borderWidth = 1
        banner.borderColor = NSColor.systemYellow
        banner.fillColor = NSColor.systemYellow.withAlphaComponent(0.2)
        banner.contentViewMargins = NSSize(width: 10, height: 6)
        banner.isHidden = true
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.font = NSFont.systemFont(ofSize: 12)
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerButton.translatesAutoresizingMaskIntoConstraints = false
        bannerButton.title = L("Open in Paseo", "在 Paseo 中打开")
        bannerButton.bezelStyle = .rounded
        bannerButton.controlSize = .small
        bannerButton.target = self
        bannerButton.action = #selector(openInPaseoTapped)
        if let bannerContent = banner.contentView {
            bannerContent.addSubview(bannerLabel)
            bannerContent.addSubview(bannerButton)
            NSLayoutConstraint.activate([
                bannerLabel.leadingAnchor.constraint(equalTo: bannerContent.leadingAnchor),
                bannerLabel.centerYAnchor.constraint(equalTo: bannerContent.centerYAnchor),
                bannerButton.leadingAnchor.constraint(greaterThanOrEqualTo: bannerLabel.trailingAnchor, constant: 8),
                bannerButton.trailingAnchor.constraint(equalTo: bannerContent.trailingAnchor),
                bannerButton.topAnchor.constraint(equalTo: bannerContent.topAnchor),
                bannerButton.bottomAnchor.constraint(equalTo: bannerContent.bottomAnchor),
            ])
        }

        configureInput(inputTextView, in: inputScroll)

        quickErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        quickErrorLabel.textColor = .systemRed
        quickErrorLabel.font = NSFont.systemFont(ofSize: 12)
        quickErrorLabel.isHidden = true
        quickErrorLabel.preferredMaxLayoutWidth = 480

        quickHintLabel.translatesAutoresizingMaskIntoConstraints = false
        quickHintLabel.font = NSFont.systemFont(ofSize: 11)
        quickHintLabel.textColor = .secondaryLabelColor
        quickHintLabel.lineBreakMode = .byTruncatingTail
        quickHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        quickSendButton.translatesAutoresizingMaskIntoConstraints = false
        quickSendButton.bezelStyle = .rounded
        quickSendButton.keyEquivalent = ""
        quickSendButton.target = self
        quickSendButton.action = #selector(sendTapped)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.title = L("Stop", "停止")
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.isHidden = true

        for view in [botPopup, headerStack, olderNote, transcript, banner, inputScroll, quickErrorLabel,
                     quickHintLabel, quickSendButton, stopButton] as [NSView] {
            content.addSubview(view)
        }

        let margin: CGFloat = 16
        NSLayoutConstraint.activate([
            botPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            botPopup.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            botPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            botPopup.trailingAnchor.constraint(lessThanOrEqualTo: headerStack.leadingAnchor, constant: -8),

            headerStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            headerStack.centerYAnchor.constraint(equalTo: botPopup.centerYAnchor),

            olderNote.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            olderNote.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -margin),

            transcript.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            transcript.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            inputScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            inputScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            quickErrorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            quickErrorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            quickHintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            quickHintLabel.centerYAnchor.constraint(equalTo: quickSendButton.centerYAnchor),
            quickHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -8),

            quickSendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            quickSendButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            stopButton.centerYAnchor.constraint(equalTo: quickSendButton.centerYAnchor),
        ])

        // Before the first question the transcript collapses and the prompt box fills the panel;
        // in a chat the transcript fills it and the follow-up box is a fixed strip.
        // The header row (New chat, History, Open in Paseo) is right-aligned; hidden buttons drop out.
        preChatConstraints = [
            transcript.heightAnchor.constraint(equalToConstant: 0),
        ]
        chatConstraints = [
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            inputScroll.heightAnchor.constraint(equalToConstant: 56),
        ]
        // The older-messages note sits between the header and the transcript only when shown.
        olderShownConstraints = [
            olderNote.topAnchor.constraint(equalTo: botPopup.bottomAnchor, constant: 8),
            transcript.topAnchor.constraint(equalTo: olderNote.bottomAnchor, constant: 6),
        ]
        olderHiddenConstraints = [
            transcript.topAnchor.constraint(equalTo: botPopup.bottomAnchor, constant: 10),
            olderNote.topAnchor.constraint(equalTo: transcript.topAnchor),
        ]
        bannerShownConstraints = [
            banner.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 8),
            inputScroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
        ]
        bannerHiddenConstraints = [
            inputScroll.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 8),
            banner.topAnchor.constraint(equalTo: inputScroll.topAnchor),
        ]
        errorShownConstraints = [
            quickErrorLabel.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 6),
            quickSendButton.topAnchor.constraint(equalTo: quickErrorLabel.bottomAnchor, constant: 8),
        ]
        errorHiddenConstraints = [
            quickSendButton.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 10),
            quickErrorLabel.topAnchor.constraint(equalTo: quickSendButton.topAnchor),
        ]
        NSLayoutConstraint.activate(preChatConstraints + olderHiddenConstraints + bannerHiddenConstraints
                                    + errorHiddenConstraints)
    }

    /// Grows the prompt-mode panel so a wrapped error stays fully visible, and shrinks it back once cleared.
    private func resizeForError() {
        guard case .prompt? = mode, let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(230, content.fittingSize.height)
        resizeKeepingTop(contentSize: NSSize(width: 480, height: height))
    }

    private func resizeKeepingTop(contentSize: NSSize) {
        let frame = self.frame
        let newFrame = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        setFrame(
            NSRect(x: frame.minX, y: frame.maxY - newFrame.height, width: newFrame.width, height: newFrame.height),
            display: true
        )
    }

    private static let cascadeOffset: CGFloat = 28

    private func positionNearTop(contentSize: NSSize, cascadeFrom: NSRect? = nil) {
        let size = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        if let from = cascadeFrom,
           let visible = (NSScreen.screens.first { $0.frame.intersects(from) } ?? NSScreen.main)?.visibleFrame {
            // Down and right of the last panel; back near the top when that would leave the screen.
            let x = from.minX + Self.cascadeOffset
            let y = from.maxY - Self.cascadeOffset - size.height
            if x + size.width <= visible.maxX, y >= visible.minY {
                setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.18
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
    }

    // MARK: - Sending

    @objc private func sendTapped() {
        submit()
    }

    @objc private func stopTapped() {
        onStop?()
    }

    @objc private func newChatTapped() {
        startNewChat()
    }

    @objc private func openInPaseoTapped() {
        onOpenInPaseo?()
    }

    @objc private func botChanged() {
        let id = botPopup.selectedItem?.representedObject as? String
        if let id, id != selectedTargetId, onPickTarget?(id) == false {
            // Another panel owns that target (and was brought forward): keep this one as it was.
            if let previous = selectedTargetId,
               let index = botPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == previous }) {
                botPopup.selectItem(at: index)
            }
            updateQuickControls()
            return
        }
        pendingTargetId = nil
        selectionIsExplicit = true
        if id != selectedTargetId { invalidateHistory() }
        selectedTargetId = id
        updateQuickControls()
    }

    /// Trimmed text if it is 1...20,000 UTF-16 units; shows the length error otherwise.
    private func validated(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.utf16.count > Self.maxPromptLength {
            showError(L("Prompt is too long (max 20,000 characters)", "提示过长（最多 20,000 个字符）"))
            return nil
        }
        return text
    }

    private func submit() {
        guard !isSending, let mode else { return }
        switch mode {
        case .prompt(let bot):
            guard let text = validated(textView.string) else { return }
            onSubmit?(bot, text)
        case .quickAsk:
            if chatAgentId != nil {
                // One turn at a time: Enter does nothing while the bot is answering.
                guard !turnRunning, let text = validated(inputTextView.string) else { return }
                onFollowUp?(text)
            } else {
                guard let target = selectedTarget, let text = validated(inputTextView.string) else { return }
                onAsk?(target, text)
            }
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        // The draft decides whether "New chat" shows.
        if case .quickAsk? = mode, (notification.object as? NSTextView) === inputTextView { updateQuickControls() }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift-Enter falls through to the default newline.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}
