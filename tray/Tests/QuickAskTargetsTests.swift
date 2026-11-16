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
}
