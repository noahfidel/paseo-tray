import Foundation

/// Pure layout of the Quick Ask picker: every used target (bots and dispatchers mixed) in recency
/// order, then never-used bots, then (when any never-used dispatchers exist) a separator, a disabled
/// "Dispatchers" header and those dispatchers. Generic over plain values so it needs no AppKit.
enum QuickAskTargets {
    enum Entry: Equatable {
        case item(id: String, title: String)
        case separator
        case header(String)
    }

    /// A target that appears in the recents list.
    enum Used<B, D> {
        case bot(B)
        case dispatcher(D)
    }

    static func botId(_ id: String) -> String { "bot:\(id)" }
    static func dispatcherId(_ agentId: String) -> String { "dispatcher:\(agentId)" }

    /// Splits targets into used (recency order, bots and dispatchers mixed), never-used bots (input
    /// order) and never-used dispatchers (input order). `recent` holds raw bot ids and
    /// `BotRecents.dispatcherKey` keys; ids that match nothing are ignored.
    static func partition<B, D>(bots: [B], dispatchers: [D], recent: [String],
                                botKey: (B) -> String,
                                dispatcherKey: (D) -> String) -> (used: [Used<B, D>], unusedBots: [B], unusedDispatchers: [D]) {
        var botsByKey: [String: B] = [:]
        for bot in bots where botsByKey[botKey(bot)] == nil { botsByKey[botKey(bot)] = bot }
        var dispatchersByKey: [String: D] = [:]
        for dispatcher in dispatchers where dispatchersByKey[dispatcherKey(dispatcher)] == nil {
            dispatchersByKey[dispatcherKey(dispatcher)] = dispatcher
        }
        var used: [Used<B, D>] = []
        var seen = Set<String>()
        for key in recent where seen.insert(key).inserted {
            if let bot = botsByKey[key] {
                used.append(.bot(bot))
            } else if let dispatcher = dispatchersByKey[key] {
                used.append(.dispatcher(dispatcher))
            }
        }
        let unusedBots = bots.filter { !seen.contains(botKey($0)) }
        let unusedDispatchers = dispatchers.filter { !seen.contains(dispatcherKey($0)) }
        return (used, unusedBots, unusedDispatchers)
    }

    static func items(bots: [(id: String, title: String)],
                      dispatchers: [(id: String, groupId: String, title: String)],
                      recent: [String]) -> [Entry] {
        let parts = partition(bots: bots, dispatchers: dispatchers, recent: recent,
                              botKey: { $0.id }, dispatcherKey: { BotRecents.dispatcherKey(groupId: $0.groupId) })
        var entries: [Entry] = parts.used.map {
            switch $0 {
            case .bot(let bot): return .item(id: botId(bot.id), title: bot.title)
            case .dispatcher(let d): return .item(id: dispatcherId(d.id), title: d.title)
            }
        }
        entries += parts.unusedBots.map { Entry.item(id: botId($0.id), title: $0.title) }
        if !parts.unusedDispatchers.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(.header(L("Dispatchers", "调度器")))
            entries += parts.unusedDispatchers.map { Entry.item(id: dispatcherId($0.id), title: $0.title) }
        }
        return entries
    }

    /// Which picker entry to select after a rebuild. `explicit` marks a choice made by the user or
    /// the menu (kept while present); otherwise the first entry is a default that a later rebuild
    /// may replace. A pending target not in `ids` yet stays pending.
    static func selection(ids: [String], current: String?, currentIsExplicit: Bool,
                          pending: String?) -> (id: String?, explicit: Bool, pendingCleared: Bool) {
        if let pending, ids.contains(pending) { return (pending, true, true) }
        if currentIsExplicit, let current, ids.contains(current) { return (current, true, false) }
        return (ids.first, false, false)
    }
}
