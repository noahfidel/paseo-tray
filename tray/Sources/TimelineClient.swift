import Foundation

/// Streams one agent's timeline over the daemon connection into a `TimelineState`.
/// Foundation only: all I/O goes through the injected `send` (PaseoClient's
/// session channel), and daemon messages come back through `handle`.
/// Main-thread only.
final class TimelineClient {
    private let send: ([String: Any]) -> Bool
    private(set) var agentId: String?
    private(set) var state = TimelineState()
    var onChange: ((TimelineState) -> Void)?
    var onError: ((String) -> Void)?

    static let tailLimit = 50
    /// Delays before the 1st and 2nd retry of a failed tail fetch; a third failure gives up.
    static let retryDelays: [TimeInterval] = [1, 5]

    private var fetchRequestId: String?
    private var subscribeRequestId: String?
    private var pendingMessageIds = Set<String>()
    private var retryCount = 0
    private var retryPending = false
    private var gaveUp = false
    /// Invalidates scheduled retries when the watch changes.
    private var retryToken = 0

    init(send: @escaping ([String: Any]) -> Bool) {
        self.send = send
    }

    // MARK: Commands

    func watch(agentId: String) {
        self.agentId = agentId
        state = TimelineState()
        beginWatch()
        onChange?(state)
    }

    func stopWatching() {
        guard agentId != nil else { return }
        agentId = nil
        fetchRequestId = nil
        pendingMessageIds = []
        invalidateRetry()
        subscribe([])
    }

    /// After a reconnect: subscriptions are per-socket, so refetch and subscribe again.
    func resubscribe() {
        guard agentId != nil else { return }
        // Frames arriving before the new snapshot must buffer, not apply.
        state.needsRefetch = true
        beginWatch()
    }

    func sendFollowUp(_ text: String) {
        guard let agentId else { return }
        let requestId = Self.newId("msg")
        pendingMessageIds.insert(requestId)
        if !send([
            "type": "send_agent_message_request",
            "requestId": requestId,
            "agentId": agentId,
            "text": text,
            "messageId": UUID().uuidString,
        ]) {
            pendingMessageIds.remove(requestId)
            notConnected()
        }
    }

    func stop() {
        guard let agentId else { return }
        if !send([
            "type": "cancel_agent_request",
            "agentId": agentId,
            "requestId": Self.newId("cancel"),
        ]) {
            notConnected()
        }
    }

    // MARK: Daemon messages

    func handle(type: String, payload: [String: Any]) {
        switch type {
        case "fetch_agent_timeline_response":
            guard matchesAgent(payload),
                  let requestId = payload["requestId"] as? String, requestId == fetchRequestId else { return }
            fetchRequestId = nil
            if let error = payload["error"] as? String, !error.isEmpty {
                fetchFailed(error)
                return
            }
            retryCount = 0
            TimelineReducer.applySnapshot(&state, payload: payload)
            changed()
        case "agent_stream":
            guard matchesAgent(payload) else { return }
            TimelineReducer.applyStream(&state, payload: payload)
            changed()
        case "agent.timeline.replacement":
            guard matchesAgent(payload) else { return }
            TimelineReducer.applyReplacement(&state, payload: payload)
            changed()
        case "agent.timeline.set_subscription.response":
            guard let requestId = payload["requestId"] as? String, requestId == subscribeRequestId else { return }
            subscribeRequestId = nil
            if let error = payload["error"] as? String, !error.isEmpty { onError?(error) }
        case "send_agent_message_response":
            guard matchesAgent(payload),
                  let requestId = payload["requestId"] as? String,
                  pendingMessageIds.remove(requestId) != nil else { return }
            if payload["accepted"] as? Bool == false {
                onError?(payload["error"] as? String ?? L("Message was not accepted", "消息未被接受"))
            }
        case "rpc_error":
            guard let requestId = payload["requestId"] as? String, requestId.hasPrefix("tl-") else { return }
            let error = payload["error"] as? String ?? L("Request failed", "请求失败")
            if requestId == fetchRequestId {
                fetchRequestId = nil
                fetchFailed(error)
            } else if requestId == subscribeRequestId {
                subscribeRequestId = nil
                onError?(error)
            } else if pendingMessageIds.remove(requestId) != nil {
                onError?(error)
            }
        default:
            break
        }
    }

    // MARK: Internals

    private static func newId(_ kind: String) -> String {
        "tl-\(kind)-\(UUID().uuidString.lowercased())"
    }

    private func matchesAgent(_ payload: [String: Any]) -> Bool {
        guard let agentId, payload["agentId"] as? String == agentId else { return false }
        return true
    }

    private func notConnected() {
        onError?(L("Paseo isn't connected", "Paseo 未连接"))
    }

    private func invalidateRetry() {
        retryToken += 1
        retryPending = false
        retryCount = 0
        gaveUp = false
    }

    private func beginWatch() {
        invalidateRetry()
        fetchTail()
        if let agentId { subscribe([agentId]) }
    }

    private func subscribe(_ agentIds: [String]) {
        let requestId = Self.newId("sub")
        subscribeRequestId = requestId
        if !send([
            "type": "agent.timeline.set_subscription.request",
            "agentIds": agentIds,
            "requestId": requestId,
        ]) {
            subscribeRequestId = nil
            notConnected()
        }
    }

    /// Supersedes any fetch in flight (its response will be ignored).
    private func fetchTail() {
        guard let agentId else { return }
        let requestId = Self.newId("fetch")
        fetchRequestId = requestId
        if !send([
            "type": "fetch_agent_timeline_request",
            "agentId": agentId,
            "requestId": requestId,
            "direction": "tail",
            "limit": Self.tailLimit,
            "projection": "projected",
        ]) {
            fetchRequestId = nil
            notConnected()
        }
    }

    private func changed() {
        refetchIfNeeded()
        onChange?(state)
    }

    private func refetchIfNeeded() {
        guard state.needsRefetch, fetchRequestId == nil, !retryPending, !gaveUp else { return }
        fetchTail()
    }

    private func fetchFailed(_ error: String) {
        guard retryCount < Self.retryDelays.count else {
            gaveUp = true
            onError?(error)
            return
        }
        let delay = Self.retryDelays[retryCount]
        retryCount += 1
        retryPending = true
        let token = retryToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.retryToken == token, self.retryPending else { return }
            self.retryPending = false
            if self.fetchRequestId == nil { self.fetchTail() }
        }
    }
}
