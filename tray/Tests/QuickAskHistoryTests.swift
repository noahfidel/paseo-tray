import Foundation

func runQuickAskHistoryTests() {
    typealias H = QuickAskHistory
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func item(_ id: String, bot: String = "a", updated: Date? = Date(timeIntervalSince1970: 1_000),
              extra: [String: Any] = [:], archivedAt: Any? = nil, title: String? = "t") -> [String: Any] {
        var labels: [String: Any] = ["paseo-bots.bot": bot]
        for (key, value) in extra { labels[key] = value }
        var agent: [String: Any] = ["id": id, "labels": labels]
        if let title { agent["title"] = title }
        if let updated { agent["updatedAt"] = iso.string(from: updated) }
        if let archivedAt { agent["archivedAt"] = archivedAt }
        return ["agent": agent, "project": NSNull()]
    }

    // entries
    let mixed = [
        item("mine"), item("other", bot: "b"),
        item("routine", extra: ["paseo-bots.routine": "r"]),
        item("asked", extra: ["paseo-bots.asked-by": "x"]),
        item("child", extra: ["paseo.parent-agent-id": "p"]),
        item("archived", archivedAt: "2026-11-01T00:00:00.000Z"),
    ]
    expect(H.entries(from: mixed, botId: "a").map(\.agentId) == ["mine"], "history: only the bot's plain chats")
    expect(H.entries(from: [item("e", extra: ["paseo.parent-agent-id": ""])], botId: "a").count == 1, "history: empty parent label kept")
    let ordered = (1...3).map { item("c\($0)", updated: Date(timeIntervalSince1970: Double($0) * 100)) }
    expect(H.entries(from: ordered, botId: "a").map(\.agentId) == ["c3", "c2", "c1"], "history: newest first from oldest-first input")
    let many = (1...20).map { item("c\($0)", updated: Date(timeIntervalSince1970: Double($0) * 100)) }
    let capped = H.entries(from: many, botId: "a")
    expect(capped.count == 15 && capped.first?.agentId == "c20" && capped.last?.agentId == "c6", "history: capped at 15 newest")
    expect(H.entries(from: [item("n", updated: nil)], botId: "a").isEmpty, "history: skips item without updatedAt")
    expect(H.entries(from: [["agent": ["labels": ["paseo-bots.bot": "a"], "updatedAt": "2026-11-01T00:00:00.000Z"]]], botId: "a").isEmpty, "history: skips item without id")
    expect(H.entries(from: [item("w", extra: ["other": 5])], botId: "a").count == 1, "history: non-string unrelated label tolerated")
    expect(H.entries(from: [item("w", extra: ["paseo-bots.bot": 5])], botId: "a").isEmpty, "history: non-string bot label not a match")
    expect(H.entries(from: [["agent": "junk"], ["nope": 1]], botId: "a").isEmpty, "history: malformed items skipped")
    expect(H.entries(from: [item("t", title: nil)], botId: "a").first?.title == "", "history: missing title is empty")

    // nextPageCursor
    expect(H.nextPageCursor(collected: 3, nextCursor: "c", pagesFetched: 1) == "c", "history: keeps paging while under limit")
    expect(H.nextPageCursor(collected: 15, nextCursor: "c", pagesFetched: 1) == nil, "history: stops at limit")
    expect(H.nextPageCursor(collected: 3, nextCursor: nil, pagesFetched: 1) == nil, "history: no cursor")
    expect(H.nextPageCursor(collected: 3, nextCursor: "", pagesFetched: 1) == nil, "history: empty cursor")
    expect(H.nextPageCursor(collected: 3, nextCursor: "c", pagesFetched: 4) == nil, "history: stops at page 4")
    expect(H.nextPageCursor(collected: 3, nextCursor: "c", pagesFetched: 3) == "c", "history: page 3 may continue")

    // request
    let req = H.request(requestId: "history-1", botId: "a", cursor: nil)
    let filter = req["filter"] as? [String: Any]
    let sort = (req["sort"] as? [[String: Any]])?.first
    let page = req["page"] as? [String: Any]
    expect(req["type"] as? String == "fetch_agents_request", "history request: type")
    expect(req["requestId"] as? String == "history-1", "history request: id")
    expect(req["includeBackground"] as? Bool == true && filter?["includeBackground"] as? Bool == true, "history request: includeBackground both levels")
    expect((filter?["labels"] as? [String: String]) == ["paseo-bots.bot": "a"], "history request: bot label")
    expect(filter?["includeArchived"] as? Bool == false, "history request: archived excluded")
    expect(sort?["key"] as? String == "updated_at" && sort?["direction"] as? String == "desc", "history request: sort")
    expect(page?["limit"] as? Int == 50, "history request: page limit")
    expect(page?["cursor"] == nil, "history request: no cursor by default")
    expect(req["scope"] == nil && req["subscribe"] == nil, "history request: no scope or subscribe")
    let req2 = H.request(requestId: "history-2", botId: "a", cursor: "cur")
    expect((req2["page"] as? [String: Any])?["cursor"] as? String == "cur", "history request: cursor when given")

    // displayTitle
    expect(H.displayTitle("") == L("Untitled chat", "未命名对话"), "history title: empty")
    expect(H.displayTitle("  ") == L("Untitled chat", "未命名对话"), "history title: blank")
    expect(H.displayTitle("  hi \n") == "hi", "history title: trimmed")
    let sixty = String(repeating: "a", count: 60)
    expect(H.displayTitle(sixty) == sixty, "history title: 60 unchanged")
    expect(H.displayTitle(sixty + "a") == String(repeating: "a", count: 59) + "…", "history title: 61 truncated")

    expect(H.displayTitle("abc", maxLength: 0) == "…", "history title: maxLength 0 does not trap")
    expect(H.displayTitle("abc", maxLength: -3) == "…", "history title: negative maxLength does not trap")

    // entries: stable order for equal updatedAt
    let tied = ["b", "c", "a"].map { item($0, updated: Date(timeIntervalSince1970: 500)) }
    expect(H.entries(from: tied, botId: "a").map(\.agentId) == ["a", "b", "c"], "history: equal updatedAt ordered by agent id")

    // relativeTime
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    cal.locale = Locale(identifier: "en_US_POSIX")
    let now = iso.date(from: "2026-11-18T12:00:00.000Z")!
    func rel(_ delta: TimeInterval) -> String { H.relativeTime(from: now.addingTimeInterval(delta), now: now, calendar: cal) }
    expect(rel(30) == L("now", "刚刚"), "history time: future is now")
    expect(rel(-30) == L("now", "刚刚"), "history time: 30s is now")
    expect(rel(-5 * 60) == "5m", "history time: minutes")
    expect(rel(-3 * 3600) == "3h", "history time: hours same day")
    expect(rel(-18 * 3600) == L("yesterday", "昨天"), "history time: previous day")
    expect(rel(-4 * 86_400) == "4d", "history time: days")
    expect(rel(-59 * 60) == "59m", "history time: 59 minutes")
    expect(rel(-60 * 60) == "1h", "history time: 60 minutes is an hour")
    expect(rel(-6 * 86_400) == "6d", "history time: 6 days")
    expect(rel(-7 * 86_400) == "Nov 11", "history time: 7 days shows date")
    expect(rel(-10 * 86_400) == "Nov 8", "history time: older shows month and day")

    // isAvailable
    expect(H.isAvailable(targetId: "bot:a", isSending: false), "history available: bot")
    expect(!H.isAvailable(targetId: "bot:a", isSending: true), "history available: not while sending")
    expect(!H.isAvailable(targetId: "dispatcher:d", isSending: false), "history available: not dispatcher")
    expect(!H.isAvailable(targetId: nil, isSending: false), "history available: not without target")
    expect(!H.isAvailable(targetId: "bot:", isSending: false), "history available: not a bare bot prefix")

    // keepsDraftOnReopen
    expect(H.keepsDraftOnReopen(wasInChat: false), "history draft: pre-chat text carries over")
    expect(!H.keepsDraftOnReopen(wasInChat: true), "history draft: in-chat follow-up is cleared")

    // rawBotId
    expect(H.rawBotId(fromTargetId: "bot:abc") == "abc", "history bot id: strips picker prefix")
    expect(H.rawBotId(fromTargetId: "dispatcher:d") == nil, "history bot id: not a dispatcher")
    expect(H.rawBotId(fromTargetId: "bot:") == nil, "history bot id: empty id")
    expect(H.rawBotId(fromTargetId: nil) == nil, "history bot id: no target")

    // pickAction
    expect(H.pickAction(agentId: "a", currentChatAgentId: "a", otherPanelChats: ["a"]) == .none, "history pick: current chat")
    expect(H.pickAction(agentId: "a", currentChatAgentId: nil, otherPanelChats: ["x", "a"]) == .focus(1), "history pick: focus other panel")
    expect(H.pickAction(agentId: "a", currentChatAgentId: "c", otherPanelChats: ["x"]) == .reopen, "history pick: reopen")
    expect(H.pickAction(agentId: "a", currentChatAgentId: nil, otherPanelChats: [nil, "a"]) == .focus(1), "history pick: nil entries ignored")

    // HistoryFetchToken
    var token = H.HistoryFetchToken()
    let first = token.start()
    let second = token.start()
    expect(!token.isCurrent(first) && token.isCurrent(second), "history token: latest wins")
    token.invalidate()
    expect(!token.isCurrent(second), "history token: invalidate")
}
