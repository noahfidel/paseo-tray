import AppKit
import Foundation

/// Floating panel for talking to a paseo-bots bot from the tray.
/// Prompt mode: type a first message, send it, and the caller opens the new chat in Paseo.
/// More modes (Quick Ask) are added as `Mode` cases.
final class QuickAskPanel: NSPanel, NSTextViewDelegate {
    enum Mode {
        case prompt(bot: TrayBot)
        case quickAsk
    }

    static let maxPromptLength = 20_000

    /// Called with the bot and the validated (trimmed, 1...20,000 characters) prompt.
    var onSubmit: ((TrayBot, String) -> Void)?
    /// Supplies the avatar shown in the header.
    var avatarProvider: ((TrayBot) -> NSImage)?

    private(set) var mode: Mode?
    private(set) var isSending = false

    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private var currentBot: TrayBot?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        buildContent()
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    // MARK: - Presenting

    func present(mode: Mode) {
        // Don't clobber a send that is still in flight.
        if isSending { orderFront(nil); return }
        self.mode = mode
        switch mode {
        case .prompt(let bot):
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
        case .quickAsk:
            // Not presented yet; added with the Quick Ask task.
            return
        }
        positionNearTop()
        // The panel can become key without making the tray the active app, but a tray
        // (accessory) app often won't route typing to it unless it is active. Activating
        // the tray itself does not bring Paseo forward.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        resizeForError()
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        sendButton.isEnabled = !sending
        textView.isEditable = !sending
        if sending {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
    }

    // MARK: - Layout

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 230))
        contentView = content

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

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

    /// Grows the panel so a wrapped error stays fully visible.
    private func resizeForError() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let baseHeight: CGFloat = 230
        let height = max(baseHeight, fitting.height)
        let frame = self.frame
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: height)
        let newFrame = frameRect(forContentRect: contentRect)
        setFrame(
            NSRect(x: frame.minX, y: frame.maxY - newFrame.height, width: newFrame.width, height: newFrame.height),
            display: true
        )
    }

    private func positionNearTop() {
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: 230)
        let size = frameRect(forContentRect: contentRect).size
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

    private func submit() {
        guard !isSending, case .prompt(let bot)? = mode else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if text.count > Self.maxPromptLength {
            showError(L("Prompt is too long (max 20,000 characters)", "提示过长（最多 20,000 个字符）"))
            return
        }
        onSubmit?(bot, text)
    }

    // MARK: - NSTextViewDelegate

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
