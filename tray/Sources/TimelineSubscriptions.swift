import Foundation

/// Owns the socket's timeline subscription for every `TimelineClient` on one connection.
/// `agent.timeline.set_subscription.request` replaces the socket's whole subscription list, so
/// clients never send it themselves: each one registers here, says which agent it watches, and
/// this sends the union of all watched agents. It alone handles the subscription response (and
/// its `rpc_error`), reporting a failure to the watchers whose agents were in the failed request.
/// Foundation only; main-thread only.
final class TimelineSubscriptions {
    private struct Watcher {
        let id: Int
        var agentId: String?
        let onError: (String) -> Void
    }

    private let send: ([String: Any]) -> Bool
    private var watchers: [Watcher] = []
    private var nextWatcherId = 0
    /// Only the latest request matters: each one replaces the whole list.
    private var requestId: String?
    /// Watchers whose agents were in the latest request.
    private var requestWatchers: [Int] = []

    init(send: @escaping ([String: Any]) -> Bool) {
        self.send = send
    }

    /// Every watched agent, once each, in registration order.
    var agentIds: [String] {
        var seen = Set<String>()
        return watchers.compactMap(\.agentId).filter { seen.insert($0).inserted }
    }

    /// Adds a watcher (watching nothing yet); `onError` gets subscription failures that include its agent.
    func register(onError: @escaping (String) -> Void) -> Int {
        nextWatcherId += 1
        watchers.append(Watcher(id: nextWatcherId, agentId: nil, onError: onError))
        return nextWatcherId
    }

    /// Drops a watcher; when it was watching an agent, the remaining union is sent.
    func unregister(_ watcher: Int) {
        guard let index = watchers.firstIndex(where: { $0.id == watcher }) else { return }
        let wasWatching = watchers[index].agentId != nil
        watchers.remove(at: index)
        if wasWatching { sendUnion() }
    }

    /// Sets (or clears, with nil) the agent a watcher follows and sends the new union, even when
    /// it is unchanged (a re-watch retries a subscription that failed). Returns false when nothing
    /// was sent (not connected or unknown watcher).
    @discardableResult
    func setAgent(_ agentId: String?, for watcher: Int) -> Bool {
        guard let index = watchers.firstIndex(where: { $0.id == watcher }) else { return false }
        watchers[index].agentId = agentId
        return sendUnion()
    }

    /// After a reconnect: subscriptions are per socket, so send the union again (nothing when empty).
    func resubscribe() {
        guard !agentIds.isEmpty else { return }
        sendUnion()
    }

    func handle(type: String, payload: [String: Any]) {
        switch type {
        case "agent.timeline.set_subscription.response":
            guard let id = payload["requestId"] as? String, id == requestId else { return }
            requestId = nil
            if let error = Self.errorText(payload) { report(error) }
        case "rpc_error":
            guard let id = payload["requestId"] as? String, id == requestId else { return }
            requestId = nil
            report(payload["error"] as? String ?? L("Request failed", "请求失败"))
        default:
            break
        }
    }

    // MARK: Internals

    @discardableResult
    private func sendUnion() -> Bool {
        let id = "tl-sub-\(UUID().uuidString.lowercased())"
        requestId = id
        requestWatchers = watchers.filter { $0.agentId != nil }.map(\.id)
        if !send([
            "type": "agent.timeline.set_subscription.request",
            "agentIds": agentIds,
            "requestId": id,
        ]) {
            requestId = nil
            requestWatchers = []
            return false
        }
        return true
    }

    private func report(_ error: String) {
        let ids = requestWatchers
        requestWatchers = []
        for watcher in watchers where ids.contains(watcher.id) && watcher.agentId != nil {
            watcher.onError(error)
        }
    }

    /// Any non-null `error` is a failure; show it when it is a string.
    private static func errorText(_ payload: [String: Any]) -> String? {
        guard let value = payload["error"], !(value is NSNull) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        return L("Request failed", "请求失败")
    }
}
