import Foundation

func runQuickAskPanelRouterTests() {
    typealias R = QuickAskPanelRouter
    func p(_ target: String?, busy: Bool = false, visible: Bool = true, key: Bool = false, draft: Bool = false) -> R.Panel {
        R.Panel(targetId: target, busy: busy, isVisible: visible, isKey: key, hasDraft: draft)
    }

    // Open-or-focus
    expect(R.route(panels: [], target: "bot:a", toggle: false) == .open, "router: no panels opens one")
    expect(R.route(panels: [], target: nil, toggle: true) == .open, "router: no panels and no target opens one")
    let twoChats = [p("bot:a", busy: true), p("dispatcher:d", busy: true)]
    expect(R.route(panels: twoChats, target: "dispatcher:d", toggle: false) == .focus(1),
           "router: panel already on the target is focused")
    expect(R.route(panels: twoChats, target: "dispatcher:d", toggle: true) == .focus(1),
           "router: hotkey focuses the target's panel when it isn't key")
    expect(R.route(panels: [p("bot:a", busy: true), p("dispatcher:d", busy: true, key: true)],
                   target: "dispatcher:d", toggle: true) == .close(1),
           "router: hotkey closes the target's panel when visible and key")
    expect(R.route(panels: [p("bot:a", busy: true), p("dispatcher:d", busy: true, key: true)],
                   target: "dispatcher:d", toggle: false) == .focus(1),
           "router: menu row never closes a key panel")
    expect(R.route(panels: twoChats, target: "bot:b", toggle: false) == .open,
           "router: in-chat panels on other targets are not reused")
    expect(R.route(panels: [p("bot:a", busy: true), p("bot:c")], target: "bot:b", toggle: false) == .retarget(1),
           "router: a pre-chat panel is reused for a new target")
    expect(R.route(panels: [p("bot:c", busy: true)], target: "bot:c", toggle: false) == .focus(0),
           "router: a sending panel still owns its target")
    expect(R.route(panels: [p("bot:c", busy: true)], target: "bot:b", toggle: false) == .open,
           "router: a sending panel is not reused")
    expect(R.route(panels: [p("bot:c"), p(nil), p("bot:d", key: true)], target: "bot:b", toggle: false) == .retarget(2),
           "router: the key pre-chat panel is reused first")
    expect(R.route(panels: [p("bot:c"), p("bot:d"), p("bot:x", busy: true)], target: "bot:b", toggle: false) == .retarget(1),
           "router: else the most recent pre-chat panel")
    expect(R.route(panels: [p("bot:c", key: true)], target: "bot:b", toggle: true) == .close(0),
           "router: hotkey closes a key pre-chat panel instead of retargeting it")
    expect(R.route(panels: [p("bot:b", visible: false)], target: "bot:b", toggle: true) == .open,
           "router: invisible panels are ignored")
    expect(R.route(panels: [p(nil)], target: "bot:b", toggle: false) == .retarget(0),
           "router: a still-empty pre-chat panel is retargeted")

    // Drafts
    expect(R.route(panels: [p("bot:c", draft: true)], target: "bot:b", toggle: false) == .open,
           "router: a pre-chat panel with a draft is not retargeted; a new panel opens")
    expect(R.route(panels: [p("bot:c"), p("bot:d", key: true, draft: true)], target: "bot:b", toggle: false) == .retarget(0),
           "router: an empty pre-chat panel is reused over a key one with a draft")
    expect(R.route(panels: [p("bot:b", draft: true)], target: "bot:b", toggle: false) == .focus(0),
           "router: a draft panel on the target itself is focused")
    expect(R.route(panels: [p("bot:c", draft: true)], target: nil, toggle: false) == .focus(0),
           "router: nil target still focuses a draft panel (nothing moves)")

    // Hotkey on a key pre-chat panel
    expect(R.route(panels: [p("bot:c", key: true, draft: true)], target: "bot:b", toggle: true) == .close(0),
           "router: hotkey closes a key pre-chat panel with a draft")
    expect(R.route(panels: [p("bot:a", busy: true), p("bot:c", key: true)], target: "bot:b", toggle: true) == .close(1),
           "router: hotkey closes a key pre-chat panel without a draft")
    expect(R.route(panels: [p("bot:c", key: true, draft: true)], target: "bot:b", toggle: false) == .open,
           "router: the menu still opens a new panel past a key draft panel")
    expect(R.route(panels: [p("bot:b", busy: true), p("bot:c", key: true)], target: "bot:b", toggle: true) == .focus(0),
           "router: hotkey focuses the target's owner even when a pre-chat panel is key")
    expect(R.route(panels: [p("bot:b", busy: true, key: true), p("bot:c")], target: "bot:b", toggle: true) == .close(0),
           "router: hotkey still closes a key panel that owns the target")
    expect(R.route(panels: [p("bot:c", busy: true, key: true)], target: "bot:b", toggle: true) == .open,
           "router: hotkey never closes a key in-chat panel on another target")

    // No resolvable target
    expect(R.route(panels: [p("bot:a", busy: true), p("bot:c")], target: nil, toggle: false) == .focus(1),
           "router: nil target focuses a pre-chat panel")
    expect(R.route(panels: [p("bot:a", busy: true), p("bot:c", key: true)], target: nil, toggle: true) == .close(1),
           "router: nil target with hotkey closes a key pre-chat panel")
    expect(R.route(panels: [p("bot:a", busy: true, key: true)], target: nil, toggle: true) == .open,
           "router: nil target never focuses or closes an in-chat panel")

    // Picker conflict
    let open = [p("bot:a", busy: true), p("bot:b")]
    expect(R.owner(of: "bot:a", panels: open, excluding: 1) == 0, "router: picking another panel's target finds that panel")
    expect(R.owner(of: "bot:b", panels: open, excluding: 1) == nil, "router: the asking panel itself is not a conflict")
    expect(R.owner(of: "bot:z", panels: open, excluding: 1) == nil, "router: a free target is no conflict")
    expect(R.owner(of: "bot:a", panels: [p("bot:a", busy: true, visible: false), p("bot:b")], excluding: 1) == nil,
           "router: a closed panel is no conflict")

    // Last-used target
    let ds = [(agentId: "ag1", groupId: "g1"), (agentId: "ag2", groupId: "g2")]
    expect(R.lastUsedTargetId(recent: [], dispatchers: ds, botsAvailable: true) == nil, "lastUsed: no recents")
    expect(R.lastUsedTargetId(recent: ["b1", "dispatcher:g1"], dispatchers: ds, botsAvailable: true) == "bot:b1",
           "lastUsed: raw bot id maps directly, bots need not be loaded")
    expect(R.lastUsedTargetId(recent: ["dispatcher:g2", "b1"], dispatchers: ds, botsAvailable: true) == "dispatcher:ag2",
           "lastUsed: dispatcher key maps to its current agent")
    expect(R.lastUsedTargetId(recent: ["dispatcher:gone", "b1"], dispatchers: ds, botsAvailable: true) == "bot:b1",
           "lastUsed: unknown dispatcher is skipped")
    expect(R.lastUsedTargetId(recent: ["dispatcher:gone"], dispatchers: [], botsAvailable: true) == nil,
           "lastUsed: only unknown dispatchers resolves to nothing")
    expect(R.lastUsedTargetId(recent: ["b1", "dispatcher:g1"], dispatchers: ds, botsAvailable: false) == "dispatcher:ag1",
           "lastUsed: bot ids are skipped without paseo-bots")
    expect(R.resolvedTargetIds(recent: ["b1", "dispatcher:gone", "dispatcher:g2", "b1", "b2"], dispatchers: ds,
                               botsAvailable: true) == ["bot:b1", "dispatcher:ag2", "bot:b2"],
           "resolved: all resolvable in order, unknown dispatchers skipped, deduped")
    expect(R.resolvedTargetIds(recent: ["b1", "dispatcher:g1", "b2"], dispatchers: ds, botsAvailable: false)
           == ["dispatcher:ag1"], "resolved: bots skipped when unavailable")

    // Last-used (hotkey / Quick Ask… row)
    func lastUsed(_ panels: [R.Panel], _ recent: [String], _ toggle: Bool, _ action: R.Action, _ target: String?,
                  _ name: String) {
        let r = R.routeLastUsed(panels: panels, recent: recent, toggle: toggle)
        expect(r.action == action && r.target == target, "lastUsed route: \(name) (got \(r))")
    }
    let ab = ["bot:a", "bot:b"]
    lastUsed([p("bot:a", busy: true, key: true)], ab, true, .open, "bot:b", "busy key owner is not closed, opens on next free")
    lastUsed([p("bot:a", busy: true, key: true)], ab, false, .open, "bot:b", "menu row opens on next free")
    lastUsed([p("bot:a", busy: true), p("bot:b", busy: true)], ab, false, .open, nil, "all recents owned")
    lastUsed([p("bot:a", busy: true), p("bot:b", busy: true, visible: false)], ab, false, .open, "bot:b",
             "invisible owner does not count")
    lastUsed([p("bot:a", busy: true), p("bot:c", key: true)], ab, true, .close(1), nil, "key pre-chat panel closes on hotkey")
    lastUsed([p("bot:a", busy: true), p("bot:c")], ab, true, .focus(1), nil, "non-key pre-chat panel is focused")
    lastUsed([p("bot:a", busy: true), p("bot:c", key: true)], ab, false, .focus(1), nil, "menu row focuses key pre-chat panel")
    lastUsed([p("bot:a", busy: true), p("bot:c", draft: true)], ab, false, .focus(1), nil, "draft panel is focused, not retargeted")
    lastUsed([p("bot:a", busy: true), p("bot:c"), p("bot:d", key: true), p("bot:e")], ab, false, .focus(2), nil,
             "key pre-chat panel preferred")
    lastUsed([p("bot:a", busy: true), p("bot:c"), p("bot:d")], ab, false, .focus(2), nil, "else the last pre-chat panel")
    lastUsed([p("bot:a", key: true)], ab, true, .close(0), "bot:a", "non-busy owner behaves like route: closes")
    lastUsed([p("bot:a")], ab, true, .focus(0), "bot:a", "non-busy owner behaves like route: focuses")
    lastUsed([p("bot:c")], ab, false, .retarget(0), "bot:a", "no owner: retargets a pre-chat panel to last-used")
    lastUsed([p("bot:c", busy: true)], ab, false, .open, "bot:a", "no owner: opens on last-used")
    lastUsed([p("bot:a", visible: false)], ab, false, .open, "bot:a", "invisible owner is no owner")
    lastUsed([p("bot:c")], [], false, .focus(0), nil, "empty recent: route with nil target")
    lastUsed([], [], true, .open, nil, "empty recent, no panels opens")
}
