import Foundation

/// Pure rules for the Quick Ask panel's History menu: which of a bot's chats to list, how to page
/// the agent directory, how to label them and which pick does what. Foundation only.
enum QuickAskHistory {
    static let limit = 15
    static let pageSize = 200
    static let maxPages = 4
    static let timeout: TimeInterval = 5
    static let reopenTailLimit = 500
    static let requestIdPrefix = "history-"

    private static let botLabel = "paseo-bots.bot"

    struct Entry: Equatable {
        let agentId: String
        /// Raw agent title; may be empty (see `displayTitle`).
        let title: String
        let updatedAt: Date
    }

    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return fractionalDates.date(from: string) ?? plainDates.date(from: string)
    }

    /// The bot's chats from a `fetch_agents_response` `entries` array, newest first, at most `limit`.
    static func entries(from directory: [[String: Any]], botId: String, limit: Int = limit) -> [Entry] {
        var result: [Entry] = []
        for item in directory {
            guard let agent = item["agent"] as? [String: Any],
                  let id = agent["id"] as? String, !id.isEmpty,
                  let updatedAt = parseDate(agent["updatedAt"]) else { continue }
            let labels = agent["labels"] as? [String: Any] ?? [:]
            guard labels[botLabel] as? String == botId else { continue }
            if labels["paseo-bots.routine"] != nil || labels["paseo-bots.asked-by"] != nil { continue }
            if let parent = labels["paseo.parent-agent-id"] as? String, !parent.isEmpty { continue }
            if let archived = agent["archivedAt"], !(archived is NSNull) { continue }
            result.append(Entry(agentId: id, title: agent["title"] as? String ?? "", updatedAt: updatedAt))
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return Array(result.prefix(max(0, limit)))
    }

    /// The cursor for the next directory page, or nil when the list is full, the directory has no
    /// more pages or the page budget is spent.
    static func nextPageCursor(collected: Int, nextCursor: String?, pagesFetched: Int) -> String? {
        guard collected < limit, let nextCursor, !nextCursor.isEmpty, pagesFetched < maxPages else { return nil }
        return nextCursor
    }

    static func request(requestId: String, botId: String, cursor: String?) -> [String: Any] {
        var page: [String: Any] = ["limit": pageSize]
        if let cursor { page["cursor"] = cursor }
        return [
            "type": "fetch_agents_request",
            "requestId": requestId,
            "includeBackground": true,
            "filter": [
                "includeBackground": true,
                "labels": [botLabel: botId],
                "includeArchived": false,
            ] as [String: Any],
            "sort": [["key": "updated_at", "direction": "desc"]],
            "page": page,
        ]
    }

    static func displayTitle(_ raw: String, maxLength: Int = 60) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L("Untitled chat", "未命名对话") }
        if trimmed.count > maxLength { return String(trimmed.prefix(maxLength - 1)) + "…" }
        return trimmed
    }

    static func relativeTime(from date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("now", "刚刚") }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return L("yesterday", "昨天") }
        if days < 7 { return "\(days)d" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    /// History applies to a bot target only, and not while a message is being sent.
    static func isAvailable(targetId: String?, isSending: Bool) -> Bool {
        guard let targetId, !isSending else { return false }
        return targetId.hasPrefix(QuickAskTargets.botId(""))
    }

    /// The raw bot id (the `paseo-bots.bot` label value) of a bot picker id; nil for any other target.
    static func rawBotId(fromTargetId targetId: String?) -> String? {
        let prefix = QuickAskTargets.botId("")
        guard let targetId, targetId.hasPrefix(prefix) else { return nil }
        let raw = String(targetId.dropFirst(prefix.count))
        return raw.isEmpty ? nil : raw
    }

    enum PickAction: Equatable {
        case none
        case focus(Int)
        case reopen
    }

    static func pickAction(agentId: String, currentChatAgentId: String?, otherPanelChats: [String?]) -> PickAction {
        if currentChatAgentId == agentId { return .none }
        if let index = otherPanelChats.firstIndex(where: { $0 == agentId }) { return .focus(index) }
        return .reopen
    }

    /// Per-panel "latest request wins" counter, like `BotsFetchGate` without the in-flight rule.
    struct HistoryFetchToken {
        private var generation = 0

        mutating func start() -> Int {
            generation += 1
            return generation
        }

        func isCurrent(_ token: Int) -> Bool { token == generation }

        mutating func invalidate() { generation += 1 }
    }
}

typealias HistoryFetchToken = QuickAskHistory.HistoryFetchToken
