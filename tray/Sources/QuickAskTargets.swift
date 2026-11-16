import Foundation

/// Pure layout of the Quick Ask picker: bots, then (when any exist) a separator, a disabled
/// "Dispatchers" header and the dispatchers. Generic over (id, title) pairs so it needs no AppKit.
enum QuickAskTargets {
    enum Entry: Equatable {
        case item(id: String, title: String)
        case separator
        case header(String)
    }

    static func botId(_ id: String) -> String { "bot:\(id)" }
    static func dispatcherId(_ agentId: String) -> String { "dispatcher:\(agentId)" }

    static func items(bots: [(id: String, title: String)],
                      dispatchers: [(id: String, title: String)]) -> [Entry] {
        var entries = bots.map { Entry.item(id: botId($0.id), title: $0.title) }
        if !dispatchers.isEmpty {
            if !bots.isEmpty { entries.append(.separator) }
            entries.append(.header(L("Dispatchers", "调度器")))
            entries += dispatchers.map { Entry.item(id: dispatcherId($0.id), title: $0.title) }
        }
        return entries
    }
}
