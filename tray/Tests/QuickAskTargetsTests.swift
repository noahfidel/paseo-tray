import Foundation

func runQuickAskTargetsTests() {
    typealias D = (id: String, groupId: String, title: String)
    let bots = [(id: "b1", title: "Ada"), (id: "b2", title: "Bo")]
    let none: [(id: String, title: String)] = []
    let noD: [D] = []
    let header = QuickAskTargets.Entry.header(L("Dispatchers", "调度器"))

    expect(QuickAskTargets.items(bots: none, dispatchers: noD, recent: []) == [], "quickAskTargets: empty")

    expect(QuickAskTargets.items(bots: bots, dispatchers: noD, recent: []) == [
        .item(id: "bot:b1", title: "Ada"), .item(id: "bot:b2", title: "Bo"),
    ], "quickAskTargets: bots only has no separator or header")

    let dispatchersOnly = QuickAskTargets.items(bots: none, dispatchers: [(id: "a1", groupId: "g1", title: "Tooling")], recent: [])
    expect(dispatchersOnly == [header, .item(id: "dispatcher:a1", title: "Tooling")],
           "quickAskTargets: dispatchers only shows header without separator")

    let both = QuickAskTargets.items(
        bots: bots, dispatchers: [(id: "a1", groupId: "g1", title: "Tooling"), (id: "a2", groupId: "g2", title: "Zen")], recent: [])
    expect(both == [
        .item(id: "bot:b1", title: "Ada"), .item(id: "bot:b2", title: "Bo"),
        .separator, header,
        .item(id: "dispatcher:a1", title: "Tooling"), .item(id: "dispatcher:a2", title: "Zen"),
    ], "quickAskTargets: no recents gives bots then header and dispatchers")

    let abc = [(id: "a", title: "A"), (id: "b", title: "B"), (id: "c", title: "C")]
    let gd: [D] = [(id: "x1", groupId: "g1", title: "Alpha"), (id: "x2", groupId: "g2", title: "Zen")]
    let mixed = QuickAskTargets.items(bots: abc, dispatchers: gd, recent: ["dispatcher:g2", "b", "gone"])
    expect(mixed == [
        .item(id: "dispatcher:x2", title: "Zen"), .item(id: "bot:b", title: "B"),
        .item(id: "bot:a", title: "A"), .item(id: "bot:c", title: "C"),
        .separator, header, .item(id: "dispatcher:x1", title: "Alpha"),
    ], "quickAskTargets: used targets mixed first, then unused bots, then unused dispatchers; stale ids ignored")

    let allUsed = QuickAskTargets.items(bots: abc, dispatchers: gd, recent: ["dispatcher:g1", "dispatcher:g2"])
    expect(allUsed == [
        .item(id: "dispatcher:x1", title: "Alpha"), .item(id: "dispatcher:x2", title: "Zen"),
        .item(id: "bot:a", title: "A"), .item(id: "bot:b", title: "B"), .item(id: "bot:c", title: "C"),
    ], "quickAskTargets: all dispatchers used has no header")

    let onlyUsedD = QuickAskTargets.items(bots: none, dispatchers: gd, recent: ["dispatcher:g2"])
    expect(onlyUsedD == [.item(id: "dispatcher:x2", title: "Zen"), .separator, header, .item(id: "dispatcher:x1", title: "Alpha")],
           "quickAskTargets: used dispatcher on top, separator before header of the rest")

    let needs = TrayDispatcher(agentId: "a3", groupId: "g", name: "Zen", needsYou: true, status: "idle")
    let marked = QuickAskTargets.items(bots: none, dispatchers: [(id: needs.agentId, groupId: needs.groupId, title: needs.menuTitle)], recent: [])
    expect(marked.last == .item(id: "dispatcher:a3", title: needs.menuTitle) && needs.menuTitle.hasPrefix("● "),
           "quickAskTargets: needs-you dispatcher title is marked")

    // Selection rule
    typealias Q = QuickAskTargets
    let lateIds = ["bot:b", "dispatcher:x1"]
    let a = Q.selection(ids: lateIds, current: "dispatcher:x1", currentIsExplicit: false, pending: nil)
    expect(a.id == "bot:b" && !a.explicit && !a.pendingCleared, "selection: defaulted dispatcher is replaced by a more recent bot")
    let b = Q.selection(ids: lateIds, current: "dispatcher:x1", currentIsExplicit: true, pending: nil)
    expect(b.id == "dispatcher:x1" && b.explicit, "selection: explicit choice is kept when bots arrive")
    let c1 = Q.selection(ids: ["dispatcher:x1"], current: "dispatcher:x1", currentIsExplicit: false, pending: "bot:b")
    expect(c1.id == "dispatcher:x1" && !c1.explicit && !c1.pendingCleared, "selection: absent pending selects first and stays pending")
    let c2 = Q.selection(ids: lateIds, current: "dispatcher:x1", currentIsExplicit: false, pending: "bot:b")
    expect(c2.id == "bot:b" && c2.explicit && c2.pendingCleared, "selection: present pending is selected, explicit and cleared")
    let sd = Q.selection(ids: ["bot:b"], current: "dispatcher:x1", currentIsExplicit: true, pending: nil)
    expect(sd.id == "bot:b" && !sd.explicit, "selection: vanished explicit choice falls back to first, defaulted")
    expect(Q.selection(ids: [], current: nil, currentIsExplicit: false, pending: nil).id == nil, "selection: nothing to select")

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
