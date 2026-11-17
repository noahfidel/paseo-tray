import Foundation

/// Pure layout of the tray's "Quick Ask" submenu, mirroring the Quick Ask picker: the Quick Ask
/// entry, bots (last used first, no team headers), then a "Dispatchers" header and dispatchers.
enum QuickAskMenu {
    enum Bots: Equatable {
        case hidden
        case loading
        case loaded([Bot])
    }

    struct Bot: Equatable {
        let id: String
        let name: String
    }

    enum Row: Equatable {
        case quickAsk
        case separator
        case header(String)
        case loading
        case bot(id: String, name: String)
        case dispatcher(agentId: String, name: String, title: String, needsYou: Bool)
    }

    /// [] means hide the whole item.
    static func rows(connected: Bool, bots: Bots, recent: [String], dispatchers: [TrayDispatcher]) -> [Row] {
        guard connected else { return [] }
        var botRows: [Row] = []
        switch bots {
        case .hidden:
            break
        case .loading:
            botRows = [.loading]
        case .loaded(let list):
            botRows = BotRecents.order(list, recent: recent, id: { $0.id }).map { .bot(id: $0.id, name: $0.name) }
        }
        if botRows.isEmpty && dispatchers.isEmpty { return [] }

        var rows: [Row] = [.quickAsk, .separator]
        rows += botRows
        if !dispatchers.isEmpty {
            if !botRows.isEmpty { rows.append(.separator) }
            rows.append(.header(L("Dispatchers", "调度器")))
            rows += dispatchers.map {
                .dispatcher(agentId: $0.agentId, name: $0.name, title: $0.menuTitle, needsYou: $0.needsYou)
            }
        }
        return rows
    }

    static func title(dispatchers: [TrayDispatcher]) -> String {
        TrayDispatcher.parentMenuTitle(L("Quick Ask", "快速提问"), for: dispatchers)
    }
}
