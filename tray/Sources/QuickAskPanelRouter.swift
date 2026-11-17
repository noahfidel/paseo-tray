import Foundation

/// Pure rules for Quick Ask's one-panel-per-target windows. A panel's target is its chat's target
/// once a chat started, otherwise its picker selection (ids from `QuickAskTargets`). Foundation only.
enum QuickAskPanelRouter {
    struct Panel: Equatable {
        /// The panel's target id; nil when the picker has nothing selected yet.
        var targetId: String?
        /// A chat started or a first question is being sent: the target is fixed.
        var busy: Bool
        var isVisible: Bool
        var isKey: Bool
        /// Pre-chat text typed in the input: never moved to another target by a retarget.
        var hasDraft = false
    }

    enum Action: Equatable {
        /// Bring this panel forward as it is.
        case focus(Int)
        /// Hotkey toggle: the panel that would be focused is already visible and key.
        case close(Int)
        /// Select the requested target in this pre-chat panel, then bring it forward.
        case retarget(Int)
        /// Open a new panel (preselected on the requested target, if any).
        case open
    }

    /// What to do when Quick Ask is asked for `target` (nil: no known target). `toggle` is the
    /// hotkey: a panel that would be brought forward but is already visible and key closes.
    /// Invisible panels are ignored.
    static func route(panels: [Panel], target: String?, toggle: Bool) -> Action {
        func forward(_ index: Int, _ action: Action) -> Action {
            toggle && panels[index].isVisible && panels[index].isKey ? .close(index) : action
        }
        if let target, let owner = owner(of: target, panels: panels) {
            return forward(owner, .focus(owner))
        }
        // The hotkey closes a key pre-chat panel (draft or not) rather than retargeting it.
        if toggle, let key = panels.indices.first(where: { panels[$0].isVisible && panels[$0].isKey && !panels[$0].busy }) {
            return .close(key)
        }
        // Reuse a panel with no chat yet: the key one first, else the most recently opened. With a
        // target it gets retargeted, so a panel holding a draft is left alone.
        let reusable = panels.indices.filter {
            panels[$0].isVisible && !panels[$0].busy && (target == nil || !panels[$0].hasDraft)
        }
        guard let index = reusable.first(where: { panels[$0].isKey }) ?? reusable.last else { return .open }
        if target == nil { return forward(index, .focus(index)) }
        return forward(index, .retarget(index))
    }

    /// The visible panel whose target is `target`, skipping `excluding` (the panel asking).
    static func owner(of target: String, panels: [Panel], excluding: Int? = nil) -> Int? {
        panels.indices.first { $0 != excluding && panels[$0].isVisible && panels[$0].targetId == target }
    }

    /// The last-used target that still resolves: the first `recent` entry that is a raw bot id
    /// (`botsAvailable` only; bots need not be loaded yet) or the recents key of a known dispatcher
    /// (mapped to its current agent). Nil when nothing resolves.
    static func lastUsedTargetId(recent: [String], dispatchers: [(agentId: String, groupId: String)],
                                 botsAvailable: Bool) -> String? {
        resolvedTargetIds(recent: recent, dispatchers: dispatchers, botsAvailable: botsAvailable).first
    }

    /// Every `recent` entry that still resolves (same mapping as `lastUsedTargetId`), in order,
    /// without duplicates.
    static func resolvedTargetIds(recent: [String], dispatchers: [(agentId: String, groupId: String)],
                                  botsAvailable: Bool) -> [String] {
        var ids: [String] = []
        for key in recent {
            var id: String?
            if key.hasPrefix("dispatcher:") {
                if let match = dispatchers.first(where: { BotRecents.dispatcherKey(groupId: $0.groupId) == key }) {
                    id = QuickAskTargets.dispatcherId(match.agentId)
                }
            } else if botsAvailable, !key.isEmpty {
                id = QuickAskTargets.botId(key)
            }
            if let id, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Hotkey and the plain "Quick Ask…" row. `recent` is the resolved recent list; the last-used
    /// target is its first entry. Unless the last-used target's visible owner panel is busy (in a
    /// chat or sending), this is `route` on the last-used target. A busy owner is never closed,
    /// focused or retargeted: instead a visible pre-chat panel (the key one, else the last) is
    /// focused as it is (the hotkey closes it when it is key), and with none a new panel opens
    /// preselected on the first recent target that has no visible owner.
    /// `target` is what the caller should select for `.open` / `.retarget` (nil: leave the picker).
    static func routeLastUsed(panels: [Panel], recent: [String], toggle: Bool) -> (action: Action, target: String?) {
        let last = recent.first
        guard let last, let owner = owner(of: last, panels: panels), panels[owner].busy else {
            return (route(panels: panels, target: last, toggle: toggle), last)
        }
        let preChat = panels.indices.filter { panels[$0].isVisible && !panels[$0].busy }
        if let index = preChat.first(where: { panels[$0].isKey }) ?? preChat.last {
            return (toggle && panels[index].isKey ? .close(index) : .focus(index), nil)
        }
        return (.open, recent.first { self.owner(of: $0, panels: panels) == nil })
    }
}
