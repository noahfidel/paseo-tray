import Foundation

func runBotRecentsTests() {
    let api = ["a", "b", "c", "d"]
    let identity: (String) -> String = { $0 }

    expect(BotRecents.order(api, recent: [], id: identity) == api, "testRecentsNoneKeepsApiOrder")
    expect(BotRecents.order(api, recent: ["c", "a"], id: identity) == ["c", "a", "b", "d"],
           "testRecentsLastUsedFirstThenApiOrder")
    expect(BotRecents.order(api, recent: ["gone", "d"], id: identity) == ["d", "a", "b", "c"],
           "testRecentsIgnoresUnknownIds")

    expect(BotRecents.dispatcherKey(groupId: "g1") == "dispatcher:g1", "testRecentsDispatcherKey")
    expect(BotRecents.adding("b", to: ["a", "b", "c"]) == ["b", "a", "c"], "testRecentsAddingMovesToFront")
    expect(BotRecents.adding("z", to: []) == ["z"], "testRecentsAddingToEmpty")
    let long = (0..<BotRecents.limit).map { "id\($0)" }
    let capped = BotRecents.adding("new", to: long)
    expect(capped.count == BotRecents.limit && capped.first == "new" && !capped.contains("id\(BotRecents.limit - 1)"),
           "testRecentsAddingCapsLength")

    // Round trip through an in-memory defaults domain (removed afterwards).
    let suite = "sh.paseo.tray.tests.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suite) {
        BotRecents.markUsed("a", defaults: defaults)
        BotRecents.markUsed("b", defaults: defaults)
        BotRecents.markUsed("a", defaults: defaults)
        expect(BotRecents.recentIds(defaults: defaults) == ["a", "b"], "testRecentsMarkUsedPersists")
        BotRecents.markDispatcherUsed(groupId: "g9", defaults: defaults)
        expect(BotRecents.recentIds(defaults: defaults) == ["dispatcher:g9", "a", "b"],
               "testRecentsMarkDispatcherUsedKeepsBotIds")
        BotRecents.markUsed("b", defaults: defaults)
        BotRecents.markDispatcherUsed(groupId: "g9", defaults: defaults)
        expect(BotRecents.recentIds(defaults: defaults) == ["dispatcher:g9", "b", "a"],
               "testRecentsDedupAcrossKinds")
        defaults.removePersistentDomain(forName: suite)
    } else {
        expect(false, "testRecentsMarkUsedPersists")
    }
}
