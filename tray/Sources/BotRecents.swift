import Foundation

/// Quick Ask's recents: bot ids and dispatcher keys, last used first. Foundation only;
/// the `[TrayBot]` overload lives next to the panel.
enum BotRecents {
    static let defaultsKey = "QuickAskRecentBots"
    static let limit = 50

    static func recentIds(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func markUsed(_ botId: String, defaults: UserDefaults = .standard) {
        defaults.set(adding(botId, to: recentIds(defaults: defaults)), forKey: defaultsKey)
    }

    /// Recents key for a dispatcher: its group id, which stays the same across agent restarts.
    static func dispatcherKey(groupId: String) -> String { "dispatcher:\(groupId)" }

    static func markDispatcherUsed(groupId: String, defaults: UserDefaults = .standard) {
        markUsed(dispatcherKey(groupId: groupId), defaults: defaults)
    }

    /// Moves `id` to the front, without duplicates, keeping at most `limit` ids.
    static func adding(_ id: String, to recent: [String]) -> [String] {
        Array(([id] + recent.filter { $0 != id }).prefix(limit))
    }

    /// Items whose id is in `recent` come first, in `recent` order; the rest keep their order.
    static func order<T>(_ items: [T], recent: [String], id: (T) -> String) -> [T] {
        var rank: [String: Int] = [:]
        for (index, value) in recent.enumerated() where rank[value] == nil { rank[value] = index }
        let used = items.filter { rank[id($0)] != nil }.sorted { rank[id($0)]! < rank[id($1)]! }
        let rest = items.filter { rank[id($0)] == nil }
        return used + rest
    }
}
