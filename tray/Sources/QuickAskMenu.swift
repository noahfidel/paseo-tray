import Foundation

/// Pure layout of the tray's "Quick Ask" submenu, mirroring the Quick Ask picker: the Quick Ask
/// entry, used targets (bots and dispatchers, last used first), never-used bots, then a
/// "Dispatchers" header and the never-used dispatchers.
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
        let list: [Bot]
        var loadingRow = false
        switch bots {
        case .hidden: list = []
        case .loading: list = []; loadingRow = true
        case .loaded(let loaded): list = loaded
        }
        if list.isEmpty && !loadingRow && dispatchers.isEmpty { return [] }

        func dispatcherRow(_ d: TrayDispatcher) -> Row {
            .dispatcher(agentId: d.agentId, name: d.name, title: d.menuTitle, needsYou: d.needsYou)
        }
        let parts = QuickAskTargets.partition(
            bots: list, dispatchers: dispatchers, recent: recent,
            botKey: { $0.id }, dispatcherKey: { BotRecents.dispatcherKey(groupId: $0.groupId) })
        var rows: [Row] = [.quickAsk, .separator]
        rows += parts.used.map {
            switch $0 {
            case .bot(let bot): return .bot(id: bot.id, name: bot.name)
            case .dispatcher(let d): return dispatcherRow(d)
            }
        }
        if loadingRow { rows.append(.loading) }
        rows += parts.unusedBots.map { .bot(id: $0.id, name: $0.name) }
        if !parts.unusedDispatchers.isEmpty {
            if rows.count > 2 { rows.append(.separator) }
            rows.append(.header(L("Dispatchers", "调度器")))
            rows += parts.unusedDispatchers.map(dispatcherRow)
        }
        return rows
    }

    static func title(dispatchers: [TrayDispatcher]) -> String {
        TrayDispatcher.parentMenuTitle(L("Quick Ask", "快速提问"), for: dispatchers)
    }
}
