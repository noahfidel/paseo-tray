import Foundation

/// One block of an assistant message: plain markdown text or a fenced code block.
enum MarkdownBlock: Equatable {
    case text(String)
    case code(language: String?, text: String)
}

/// Splits assistant markdown into text and fenced code blocks. Foundation only.
enum ChatMarkdown {
    /// A fence opens with ``` or ~~~ (up to three spaces of indent) and closes with the same
    /// marker on a line of its own. An unclosed fence (a reply still streaming) runs to the end.
    static func split(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var fence: String?
        var language: String?

        func flushText() {
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.text(text)) }
            textLines = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let marker = fenceMarker(line)
            if let open = fence {
                if let marker, marker.hasPrefix(open), marker.rest.isEmpty {
                    blocks.append(.code(language: language, text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    fence = nil
                    language = nil
                } else {
                    codeLines.append(line)
                }
            } else if let marker, !marker.rest.contains("`") {
                flushText()
                fence = marker.fence
                language = marker.rest.isEmpty ? nil : marker.rest.split(separator: " ").first.map(String.init)
            } else {
                textLines.append(line)
            }
        }
        if fence != nil {
            blocks.append(.code(language: language, text: codeLines.joined(separator: "\n")))
        } else {
            flushText()
        }
        return blocks
    }

    private struct Marker {
        let fence: String
        let rest: String
        func hasPrefix(_ open: String) -> Bool {
            fence.first == open.first && fence.count >= open.count
        }
    }

    private static func fenceMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let body = line.dropFirst(indent)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let fence = body.prefix { $0 == first }
        guard fence.count >= 3 else { return nil }
        let rest = body.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
        return Marker(fence: String(fence), rest: rest)
    }
}
