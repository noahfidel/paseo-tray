import Foundation

private func json(_ file: String) -> Any {
    let url = URL(fileURLWithPath: fixturesDirectory).appendingPathComponent(file)
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        print("FAIL missing fixture \(file)")
        exit(1)
    }
    return object
}

private func snapshotEntries() -> [[String: Any]] {
    let message = json("dispatchers-snapshot.json") as? [String: Any]
    return (message?["payload"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
}

private func updates() -> [[String: Any]] {
    let url = URL(fileURLWithPath: fixturesDirectory).appendingPathComponent("dispatchers-updates.jsonl")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

private func agent(
    _ id: String, group: String? = "g1", title: String? = "Flowly dispatcher · Alpha",
    status: String = "idle", created: String = "2026-01-01T00:00:00.000Z",
    updated: String = "2026-01-01T00:00:00.000Z", archivedAt: Any? = nil,
    internalFlag: Bool? = nil, permissions: [[String: Any]] = []
) -> [String: Any] {
    var labels: [String: Any] = ["flowly-dispatcher": "1"]
    if let group { labels["flowly-dispatcher-group"] = group }
    var a: [String: Any] = [
        "id": id, "labels": labels, "status": status, "createdAt": created,
        "updatedAt": updated, "pendingPermissions": permissions,
        "archivedAt": archivedAt ?? NSNull(),
    ]
    if let title { a["title"] = title }
    if let internalFlag { a["internal"] = internalFlag }
    return a
}

private func store(_ agents: [[String: Any]]) -> DispatcherStore {
    let s = DispatcherStore()
    s.replace(entries: agents.map { ["agent": $0] })
    return s
}

func runDispatcherStoreTests() {
    // Recorded snapshot: 2 live dispatchers, plus an older closed one for the Zenlytic group.
    let recorded = DispatcherStore()
    recorded.replace(entries: snapshotEntries())
    let list = recorded.dispatchers()
    expect(snapshotEntries().count >= 3, "dispatchers: snapshot fixture has live and closed entries")
    expect(list.map(\.name) == ["Tooling", "Zenlytic"], "dispatchers: recorded snapshot keeps one per group, sorted")
    expect(list.allSatisfy { !$0.needsYou && $0.status != "closed" }, "dispatchers: recorded dispatchers are idle")
    expect(list.first?.agentId.hasPrefix("368156a8") == true, "dispatchers: Tooling is the live one")

    // Derived updates (see derive-dispatcher-fixtures.py).
    let u = updates()
    expect(u.count == 5, "dispatchers: updates fixture has 5 frames")
    if u.count == 5 {
        recorded.apply(update: u[0])
        expect(recorded.dispatchers().first?.needsYou == true, "dispatchers: pending permission sets needsYou")
        expect(recorded.dispatchers().dropFirst().allSatisfy { !$0.needsYou }, "dispatchers: other groups unaffected")
        recorded.apply(update: u[1])
        expect(recorded.dispatchers().first?.needsYou == false, "dispatchers: resolved permission clears needsYou")
        recorded.apply(update: u[3])
        let newer = recorded.dispatchers().filter { $0.groupId == list[0].groupId }
        expect(newer.count == 1 && newer[0].agentId.hasPrefix("aaaaaaaa"), "dispatchers: newer same-group dispatcher wins")
        recorded.apply(update: u[4])
        expect(recorded.dispatchers().first?.agentId == list[0].agentId, "dispatchers: remove brings the older one back")
        recorded.apply(update: u[2])
        expect(recorded.dispatchers().map(\.name) == ["Zenlytic"], "dispatchers: closed dispatcher disappears")
    }

    // Match rules.
    let dropped = store([
        agent("closed", status: "closed"),
        agent("archived", archivedAt: "2026-02-01T00:00:00.000Z"),
        agent("old", group: nil),
        agent("emptygroup", group: ""),
        agent("internal", internalFlag: true),
    ])
    expect(dropped.dispatchers().isEmpty, "match: closed, archived, label-less, empty group, internal are dropped")
    expect(store([agent("a", internalFlag: false)]).dispatchers().count == 1, "match: internal false is kept")
    var noArchivedKey = agent("a"); noArchivedKey.removeValue(forKey: "archivedAt")
    expect(store([noArchivedKey]).dispatchers().count == 1, "match: absent archivedAt is kept")
    var wrongValue = agent("a"); wrongValue["labels"] = ["flowly-dispatcher": "0", "flowly-dispatcher-group": "g1"]
    expect(store([wrongValue]).dispatchers().isEmpty, "match: filter label must equal 1")

    // One per group.
    let groups = store([
        agent("old", created: "2026-01-01T00:00:00.000Z"),
        agent("new", created: "2026-01-02T00:00:00.000Z"),
        agent("other", group: "g2", title: "Flowly dispatcher · Beta"),
    ]).dispatchers()
    expect(groups.map(\.agentId) == ["new", "other"], "group: newest createdAt wins, one per group")
    let tie = store([
        agent("a", updated: "2026-01-01T00:00:00.000Z"),
        agent("b", updated: "2026-01-03T00:00:00.000Z"),
    ]).dispatchers()
    expect(tie.map(\.agentId) == ["b"], "group: createdAt tie falls back to newest updatedAt")
    let closedNewest = store([
        agent("old", created: "2026-01-01T00:00:00.000Z"),
        agent("newclosed", status: "closed", created: "2026-01-02T00:00:00.000Z"),
    ]).dispatchers()
    expect(closedNewest.map(\.agentId) == ["old"], "group: a newer closed one does not hide the live one")

    // Names.
    func name(_ title: String?, group: String = "0123456789abcdef") -> String {
        store([agent("x", group: group, title: title)]).dispatchers().first?.name ?? "?"
    }
    expect(name("Flowly dispatcher · Zenlytic") == "Zenlytic", "name: prefix stripped")
    expect(name("Flowly dispatcher · Many · Parts") == "Many · Parts", "name: only the prefix is stripped")
    expect(name("  My chat  ") == "My chat", "name: other title is trimmed")
    expect(name("Flowly dispatcher · ") == "Flowly dispatcher ·", "name: empty remainder keeps the title")
    expect(name("   ") == "01234567", "name: blank title falls back to group id prefix")
    expect(name(nil) == "01234567", "name: missing title falls back to group id prefix")

    // Sorting.
    let sorted = store([
        agent("1", group: "a", title: "Flowly dispatcher · Team 10"),
        agent("2", group: "b", title: "Flowly dispatcher · Team 2"),
        agent("4", group: "d", title: "Flowly dispatcher · Same"),
        agent("3", group: "c", title: "Flowly dispatcher · Same"),
    ]).dispatchers()
    expect(sorted.map(\.agentId) == ["3", "4", "2", "1"], "sort: localized standard compare, then agentId")

    // Store plumbing.
    let s = store([agent("a")])
    s.apply(update: ["kind": "upsert", "agent": agent("a", permissions: [["requestId": "r"]])])
    expect(s.dispatchers().first?.needsYou == true, "store: upsert replaces the agent")
    s.apply(update: ["kind": "upsert"])
    s.apply(update: ["kind": "bogus", "agentId": "a"])
    expect(s.dispatchers().count == 1, "store: malformed updates are ignored")
    s.apply(update: ["kind": "remove", "agentId": "a"])
    expect(s.dispatchers().isEmpty, "store: remove drops the agent")
    s.replace(entries: [["agent": agent("a")], ["project": [:]]])
    expect(s.dispatchers().count == 1, "store: entries without an agent are skipped")
    s.clear()
    expect(s.dispatchers().isEmpty, "store: empty after clear")
    s.replace(entries: [["agent": agent("a")]])
    s.replace(entries: [])
    expect(s.dispatchers().isEmpty, "store: replace with no entries empties it")

    // Menu titles.
    let quiet = TrayDispatcher(agentId: "a", groupId: "g", name: "Alpha", needsYou: false, status: "idle")
    let waiting = TrayDispatcher(agentId: "b", groupId: "h", name: "Beta", needsYou: true, status: "idle")
    expect(quiet.menuTitle == "Alpha", "menu: quiet dispatcher shows its name")
    expect(waiting.menuTitle == L("● Beta — needs you", "● Beta — 需要你处理"), "menu: needs-you marker and suffix")
    expect(TrayDispatcher.parentMenuTitle("D", for: [quiet]) == "D", "menu: parent unmarked when none need you")
    expect(TrayDispatcher.parentMenuTitle("D", for: [quiet, waiting]) == "● D", "menu: parent marked when any needs you")
}
