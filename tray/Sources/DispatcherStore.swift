import Foundation

/// The only Flowly-specific code in the tray: how a Paseo agent is recognised
/// as a Flowly dispatcher. Everything else treats dispatchers as plain agents.
enum DispatcherMatch {
    /// Exact label match used as the daemon-side filter (old and new dispatchers have it).
    static let filterLabelKey = "flowly-dispatcher"
    static let filterLabelValue = "1"
    /// Present on current dispatchers; its value is the board group id.
    static let groupLabelKey = "flowly-dispatcher-group"
    /// Titles look like "Flowly dispatcher · <group name>".
    static let titlePrefix = "Flowly dispatcher · "
    static let closedStatus = "closed"
    static let groupIdFallbackLength = 8

    /// The group id of a live dispatcher, nil when the agent is not one.
    static func groupId(of agent: [String: Any]) -> String? {
        guard let labels = agent["labels"] as? [String: Any],
              labels[filterLabelKey] as? String == filterLabelValue,
              let group = labels[groupLabelKey] as? String, !group.isEmpty else { return nil }
        if !(agent["archivedAt"] is NSNull) && agent["archivedAt"] != nil { return nil }
        if agent["status"] as? String == closedStatus { return nil }
        if agent["internal"] as? Bool == true { return nil }
        return group
    }

    static func name(title: String?, groupId: String) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(titlePrefix) {
            let rest = String(trimmed.dropFirst(titlePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return rest }
        }
        if !trimmed.isEmpty { return trimmed }
        return String(groupId.prefix(groupIdFallbackLength))
    }
}

struct TrayDispatcher: Equatable {
    let agentId: String
    let groupId: String
    let name: String
    let needsYou: Bool
    let status: String

    /// Menu title; a needs-you dispatcher gets a leading dot and a suffix.
    var menuTitle: String {
        needsYou ? L("● \(name) — needs you", "● \(name) — 需要你处理") : name
    }

    /// Parent menu item title: leading dot when any dispatcher needs the user.
    static func parentMenuTitle(_ title: String, for list: [TrayDispatcher]) -> String {
        list.contains(where: \.needsYou) ? "● " + title : title
    }
}

/// Raw agent dictionaries of the dispatcher subscription, keyed by id.
final class DispatcherStore {
    private var agents: [String: [String: Any]] = [:]

    func replace(entries: [[String: Any]]) {
        agents = [:]
        for entry in entries {
            if let agent = entry["agent"] as? [String: Any], let id = agent["id"] as? String {
                agents[id] = agent
            }
        }
    }

    func apply(update payload: [String: Any]) {
        guard let kind = payload["kind"] as? String else { return }
        if kind == "remove" {
            if let agentId = payload["agentId"] as? String { agents.removeValue(forKey: agentId) }
            return
        }
        guard kind == "upsert", let agent = payload["agent"] as? [String: Any],
              let id = agent["id"] as? String else { return }
        agents[id] = agent
    }

    func clear() {
        agents = [:]
    }

    func dispatchers() -> [TrayDispatcher] {
        var newest: [String: [String: Any]] = [:]
        for agent in agents.values {
            guard let group = DispatcherMatch.groupId(of: agent) else { continue }
            if let current = newest[group], !Self.isNewer(agent, than: current) { continue }
            newest[group] = agent
        }
        let result = newest.compactMap { group, agent -> TrayDispatcher? in
            guard let id = agent["id"] as? String else { return nil }
            let permissions = agent["pendingPermissions"] as? [Any]
            return TrayDispatcher(
                agentId: id,
                groupId: group,
                name: DispatcherMatch.name(title: agent["title"] as? String, groupId: group),
                needsYou: !(permissions ?? []).isEmpty,
                status: agent["status"] as? String ?? ""
            )
        }
        return result.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.agentId < $1.agentId
        }
    }

    /// ISO-8601 UTC strings of one format sort as text; ties fall back to `updatedAt`, then id.
    private static func isNewer(_ a: [String: Any], than b: [String: Any]) -> Bool {
        for key in ["createdAt", "updatedAt"] {
            let x = a[key] as? String ?? ""
            let y = b[key] as? String ?? ""
            if x != y { return x > y }
        }
        return (a["id"] as? String ?? "") > (b["id"] as? String ?? "")
    }
}
