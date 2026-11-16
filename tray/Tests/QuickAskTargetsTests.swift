import Foundation

func runQuickAskTargetsTests() {
    let bots = [(id: "b1", title: "Ada"), (id: "b2", title: "Bo")]
    let none: [(id: String, title: String)] = []

    expect(QuickAskTargets.items(bots: none, dispatchers: none) == [], "quickAskTargets: empty")

    expect(QuickAskTargets.items(bots: bots, dispatchers: none) == [
        .item(id: "bot:b1", title: "Ada"), .item(id: "bot:b2", title: "Bo"),
    ], "quickAskTargets: bots only has no separator or header")

    let dispatchersOnly = QuickAskTargets.items(bots: none, dispatchers: [(id: "a1", title: "Tooling")])
    expect(dispatchersOnly == [.header(L("Dispatchers", "调度器")), .item(id: "dispatcher:a1", title: "Tooling")],
           "quickAskTargets: dispatchers only shows header without separator")

    let both = QuickAskTargets.items(bots: bots, dispatchers: [(id: "a1", title: "Tooling"), (id: "a2", title: "Zen")])
    expect(both == [
        .item(id: "bot:b1", title: "Ada"), .item(id: "bot:b2", title: "Bo"),
        .separator, .header(L("Dispatchers", "调度器")),
        .item(id: "dispatcher:a1", title: "Tooling"), .item(id: "dispatcher:a2", title: "Zen"),
    ], "quickAskTargets: both groups in order with separator and header")

    let needs = TrayDispatcher(agentId: "a3", groupId: "g", name: "Zen", needsYou: true, status: "idle")
    let marked = QuickAskTargets.items(bots: none, dispatchers: [(id: needs.agentId, title: needs.menuTitle)])
    expect(marked.last == .item(id: "dispatcher:a3", title: needs.menuTitle) && needs.menuTitle.hasPrefix("● "),
           "quickAskTargets: needs-you dispatcher title is marked")

    expect(QuickAskTargets.dispatcherId("a1") == "dispatcher:a1"
           && QuickAskTargets.dispatcherId("a1").dropFirst("dispatcher:".count) == "a1",
           "quickAskTargets: dispatcher id round-trips its agent id")

    func d(_ status: String, _ needs: Bool = false) -> TrayDispatcher {
        TrayDispatcher(agentId: "a", groupId: "g", name: "N", needsYou: needs, status: status)
    }
    expect(d("idle").isAskable, "askable: idle")
    expect(d("error").isAskable, "askable: error")
    expect(!d("running").isAskable, "askable: running is not")
    expect(!d("initializing").isAskable, "askable: initializing is not")
    expect(!d("closed").isAskable, "askable: closed is not")
    expect(!d("idle", true).isAskable, "askable: idle with needs-you is not")
}
