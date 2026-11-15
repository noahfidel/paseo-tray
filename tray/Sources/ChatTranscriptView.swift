import AppKit
import Foundation

/// Scrolling list of chat rows. `update(rows:)` diffs by row id, so streaming text only
/// reconfigures the row it lands in, and it follows the bottom only when already there.
/// `.unsupported` rows are not drawn (the panel's banner covers them).
final class ChatTranscriptView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = TranscriptDocumentView()
    private let stack = NSStackView()
    private var rowViews: [String: TranscriptRowView] = [:]
    private var rowsById: [String: ChatRow] = [:]
    private var order: [String] = []

    private static let inset: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(rows: [ChatRow]) {
        let followBottom = isAtBottom
        var newOrder: [String] = []
        var newViews: [String: TranscriptRowView] = [:]
        var newRows: [String: ChatRow] = [:]

        for row in rows {
            if case .unsupported = row { continue }
            var key = Self.key(row)
            while newRows[key] != nil { key += "+" }
            let view: TranscriptRowView
            if let existing = rowViews[key], existing.accepts(row) {
                view = existing
                if rowsById[key] != row { view.configure(row) }
            } else {
                view = TranscriptRowView.make(for: row)
                view.configure(row)
            }
            newOrder.append(key)
            newViews[key] = view
            newRows[key] = row
        }

        let unchangedPrefix = newOrder.count >= order.count
            && Array(newOrder.prefix(order.count)) == order
            && order.allSatisfy { rowViews[$0] === newViews[$0] }
        if unchangedPrefix {
            for key in newOrder.dropFirst(order.count) { attach(newViews[key]!) }
        } else {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for key in newOrder { attach(newViews[key]!) }
        }

        rowViews = newViews
        rowsById = newRows
        order = newOrder

        if followBottom { scrollToBottom() }
    }

    func scrollToBottom() {
        layoutSubtreeIfNeeded()
        scrollDocumentToBottom()
        // Text views settle their height after the first pass at the final width.
        DispatchQueue.main.async { [weak self] in
            self?.layoutSubtreeIfNeeded()
            self?.scrollDocumentToBottom()
        }
    }

    // MARK: - Internals

    private static func key(_ row: ChatRow) -> String {
        switch row {
        case .user(let id, _): return "u:\(id)"
        case .assistant(let id, _): return "a:\(id)"
        case .tool(let callId, _, _, _): return "t:\(callId)"
        case .error(let id, _): return "e:\(id)"
        case .notice(let id, _): return "n:\(id)"
        case .unsupported(let id, _): return "x:\(id)"
        }
    }

    private var isAtBottom: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= documentView.frame.height - 24
    }

    private func scrollDocumentToBottom() {
        let clip = scrollView.contentView
        let y = max(0, documentView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func attach(_ view: TranscriptRowView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
    }

    private func build() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        documentView.addSubview(stack)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: clip.topAnchor),
            documentView.widthAnchor.constraint(equalTo: clip.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }
}

/// Flipped so rows stack from the top.
private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Text

/// Read-only, selectable text view that reports its text height to Auto Layout.
final class TranscriptTextView: NSTextView {
    static func make(inset: NSSize = .zero) -> TranscriptTextView {
        let view = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = inset
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func setText(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height + textContainerInset.height * 2))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

enum TranscriptStyle {
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Only these link schemes are clickable; a reply can't link to file:// or app URLs.
    static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    static func plain(_ text: String, font: NSFont = bodyFont, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// Inline markdown (bold, italic, code, strikethrough, links); block syntax stays literal.
    static func inlineMarkdown(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return plain(text)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
            if let intent = run.inlinePresentationIntent {
                var font = bodyFont
                if intent.contains(.code) {
                    font = codeFont
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                attributes[.font] = font
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link, let scheme = link.scheme?.lowercased(), linkSchemes.contains(scheme) {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}

// MARK: - Rows

class TranscriptRowView: NSView {
    static func make(for row: ChatRow) -> TranscriptRowView {
        switch row {
        case .user: return UserRowView()
        case .assistant: return AssistantRowView()
        case .tool: return ToolRowView()
        case .error, .notice, .unsupported: return MessageRowView()
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func accepts(_ row: ChatRow) -> Bool { false }
    func configure(_ row: ChatRow) {}
}

/// The user's message: a right-aligned bubble.
private final class UserRowView: TranscriptRowView {
    private let bubble = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private static let minLeadingGap: CGFloat = 60
    private static let padding = NSSize(width: 10, height: 6)

    override init() {
        super.init()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = TranscriptStyle.bodyFont
        label.isSelectable = true
        addSubview(bubble)
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.minLeadingGap),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Self.padding.width),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Self.padding.width),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Self.padding.height),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Self.padding.height),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func accepts(_ row: ChatRow) -> Bool {
        if case .user = row { return true }
        return false
    }

    override func configure(_ row: ChatRow) {
        guard case .user(_, let text) = row else { return }
        label.stringValue = text
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        let maxWidth = max(40, bounds.width - Self.minLeadingGap - 2 * Self.padding.width)
        if label.preferredMaxLayoutWidth != maxWidth {
            label.preferredMaxLayoutWidth = maxWidth
            label.invalidateIntrinsicContentSize()
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bubble.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        }
        super.layout()
    }
}

/// An assistant reply: markdown text blocks and monospaced code blocks.
private final class AssistantRowView: TranscriptRowView {
    private let stack = NSStackView()
    private var blocks: [MarkdownBlock] = []
    private var blockViews: [NSView] = []

    override init() {
        super.init()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func accepts(_ row: ChatRow) -> Bool {
        if case .assistant = row { return true }
        return false
    }

    override func configure(_ row: ChatRow) {
        guard case .assistant(_, let text) = row else { return }
        let newBlocks = ChatMarkdown.split(text)
        for (index, block) in newBlocks.enumerated() {
            if index < blocks.count, blocks[index] == block { continue }
            if index < blockViews.count, Self.sameKind(blocks[index], block) {
                Self.fill(blockViews[index], with: block)
                continue
            }
            let view = Self.makeView(for: block)
            Self.fill(view, with: block)
            if index < blockViews.count {
                let old = blockViews[index]
                stack.removeArrangedSubview(old)
                old.removeFromSuperview()
                stack.insertArrangedSubview(view, at: index)
                blockViews[index] = view
            } else {
                stack.addArrangedSubview(view)
                blockViews.append(view)
            }
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        while blockViews.count > newBlocks.count {
            let old = blockViews.removeLast()
            stack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        blocks = newBlocks
    }

    private static func sameKind(_ a: MarkdownBlock, _ b: MarkdownBlock) -> Bool {
        switch (a, b) {
        case (.text, .text), (.code, .code): return true
        default: return false
        }
    }

    private static func makeView(for block: MarkdownBlock) -> NSView {
        switch block {
        case .text:
            return TranscriptTextView.make()
        case .code:
            return CodeBlockView()
        }
    }

    private static func fill(_ view: NSView, with block: MarkdownBlock) {
        switch block {
        case .text(let text):
            (view as? TranscriptTextView)?.setText(TranscriptStyle.inlineMarkdown(text))
        case .code(_, let text):
            (view as? CodeBlockView)?.setCode(text)
        }
    }
}

/// A fenced code block on a rounded background.
private final class CodeBlockView: NSView {
    private let textView = TranscriptTextView.make(inset: NSSize(width: 8, height: 6))

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setCode(_ code: String) {
        textView.setText(TranscriptStyle.plain(code, font: TranscriptStyle.codeFont))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1).cgColor
        }
        super.layout()
    }
}

/// One tool call: `▸ name — status` with a status symbol; click shows the error, if any.
private final class ToolRowView: TranscriptRowView {
    private let disclosure = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let errorText = TranscriptTextView.make()
    private var errorBottom: NSLayoutConstraint!
    private var titleBottom: NSLayoutConstraint!
    private var error: String?
    private var expanded = false

    override init() {
        super.init()
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.font = NSFont.systemFont(ofSize: 10)
        disclosure.textColor = .secondaryLabelColor
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorText.isHidden = true

        for view in [disclosure, spinner, icon, titleLabel, errorText] as [NSView] { addSubview(view) }
        errorBottom = errorText.bottomAnchor.constraint(equalTo: bottomAnchor)
        titleBottom = titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 10),
            disclosure.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleBottom,
            errorText.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorText.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorText.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func accepts(_ row: ChatRow) -> Bool {
        if case .tool = row { return true }
        return false
    }

    override func configure(_ row: ChatRow) {
        guard case .tool(_, let name, let status, let error) = row else { return }
        self.error = (error?.isEmpty == false) ? error : nil
        titleLabel.stringValue = "\(name) — \(Self.statusText(status))"
        if status == "running" {
            icon.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            icon.isHidden = false
            let (symbol, color) = Self.symbol(status)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: Self.statusText(status))
            icon.contentTintColor = color
        }
        if let error = self.error {
            errorText.setText(TranscriptStyle.plain(error, font: NSFont.systemFont(ofSize: 12), color: .systemRed))
        } else {
            expanded = false
        }
        applyExpanded()
    }

    @objc private func toggle() {
        guard error != nil else { return }
        expanded.toggle()
        applyExpanded()
    }

    private func applyExpanded() {
        let show = expanded && error != nil
        disclosure.stringValue = error == nil ? "" : (show ? "▾" : "▸")
        errorText.isHidden = !show
        titleBottom.isActive = !show
        errorBottom.isActive = show
    }

    private static func statusText(_ status: String) -> String {
        switch status {
        case "running": return L("running", "运行中")
        case "completed": return L("done", "完成")
        case "failed": return L("failed", "失败")
        case "canceled": return L("canceled", "已取消")
        default: return status
        }
    }

    private static func symbol(_ status: String) -> (String, NSColor) {
        switch status {
        case "completed": return ("checkmark", .secondaryLabelColor)
        case "failed": return ("xmark", .systemRed)
        case "canceled": return ("minus", .secondaryLabelColor)
        default: return ("circle", .secondaryLabelColor)
        }
    }
}

/// A turn error (red) or a notice (secondary).
private final class MessageRowView: TranscriptRowView {
    private let text = TranscriptTextView.make()

    override init() {
        super.init()
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func accepts(_ row: ChatRow) -> Bool {
        switch row {
        case .error, .notice: return true
        default: return false
        }
    }

    override func configure(_ row: ChatRow) {
        switch row {
        case .error(_, let message):
            text.setText(TranscriptStyle.plain(message, color: .systemRed))
        case .notice(_, let notice):
            text.setText(TranscriptStyle.plain(notice, font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor))
        default:
            break
        }
    }
}
