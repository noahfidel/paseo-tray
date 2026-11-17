import Foundation

/// Streams one agent's timeline over the daemon connection into a `TimelineState`.
/// Foundation only: all I/O goes through the injected `send` (PaseoClient's
/// session channel), and daemon messages come back through `handle`. Several clients can share
/// one connection: the tray is an owned-subscriptions client, so each
/// `agent.timeline.set_subscription.request` makes a separate server subscription with its own
/// `subscriptionId`. Each client holds one subscription for its agent and releases it
/// (`subscription.release.request`) when it stops, re-watches or is freed; every request and
/// payload is matched by agent, request id and subscription id.
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
    /// The server subscription this client holds (from the subscribe response).
    private var subscriptionId: String?
    /// Subscribe requests sent for an earlier watch: their late responses are released at once.
    private var abandonedSubscribeRequestIds = Set<String>()
    /// Subscriptions released on this socket: frames still in flight for them are dropped.
    private var releasedSubscriptionIds = Set<String>()
    private var cancelRequestId: String?
    private var pendingMessageIds = Set<String>()
    private var retryCount = 0
    private var retryPending = false
    private var gaveUp = false
    private var reportedDisconnect = false
    /// Invalidates scheduled retries when the watch changes.
    private var retryToken = 0
    private var activeTurnBehavior: String?

    init(send: @escaping ([String: Any]) -> Bool) {
        self.send = send
    }

    deinit {
        releaseSubscription()
    }

    // MARK: Commands

    /// `activeTurnBehavior` (e.g. "steer") rides along on follow-ups so a send never interrupts a
    /// running turn; nil leaves the key out and keeps the server default.
    func watch(agentId: String, activeTurnBehavior: String? = nil) {
        releaseSubscription()
        self.agentId = agentId
        self.activeTurnBehavior = activeTurnBehavior
        state = TimelineState()
        pendingMessageIds = []
        beginWatch()
        onChange?(state)
    }

    func stopWatching() {
        guard agentId != nil else { return }
        agentId = nil
        fetchRequestId = nil
        cancelRequestId = nil
        pendingMessageIds = []
        invalidateRetry()
        releaseSubscription()
    }

    /// After a reconnect: the old socket's subscriptions died with it, so forget them (no
    /// release), then refetch and subscribe again.
    func resubscribe() {
        guard agentId != nil else { return }
        // Frames arriving before the new snapshot must buffer, not apply.
        state.needsRefetch = true
        let lost = !pendingMessageIds.isEmpty
        pendingMessageIds = []
        subscriptionId = nil
        subscribeRequestId = nil
        abandonedSubscribeRequestIds = []
        releasedSubscriptionIds = []
        beginWatch()
        // A follow-up whose response never arrived may or may not have reached the agent; don't resend.
        if lost { onError?(L("Your last message may not have been sent", "你的上一条消息可能未发送")) }
    }

    /// Returns false when nothing was sent (not watching, or the connection dropped), so the caller keeps the typed text.
    @discardableResult
    func sendFollowUp(_ text: String) -> Bool {
        guard let agentId else { return false }
        gaveUp = false
        retryCount = 0
        let requestId = Self.newId("msg")
        pendingMessageIds.insert(requestId)
        var request: [String: Any] = [
            "type": "send_agent_message_request",
            "requestId": requestId,
            "agentId": agentId,
            "text": text,
            "messageId": UUID().uuidString,
        ]
        if let activeTurnBehavior { request["activeTurnBehavior"] = activeTurnBehavior }
        if !send(request) {
            pendingMessageIds.remove(requestId)
            notConnected()
            return false
        }
        return true
    }

    func stop() {
        guard let agentId else { return }
        let requestId = Self.newId("cancel")
        cancelRequestId = requestId
        if !send([
            "type": "cancel_agent_request",
            "agentId": agentId,
            "requestId": requestId,
        ]) {
            cancelRequestId = nil
            notConnected()
        }
    }

    // MARK: Daemon messages

    /// Returns true when this client claimed a subscribe response (its current or an abandoned
    /// request); see `releaseUnclaimedSubscription` for the ones nobody claims.
    @discardableResult
    func handle(type: String, payload: [String: Any]) -> Bool {
        if type == "agent.timeline.set_subscription.response" { return handleSubscribeResponse(payload) }
        apply(type: type, payload: payload)
        return false
    }

    /// A subscribe response from this connection that no live client claimed (its client was freed
    /// before the answer came): release the subscription so it doesn't outlive the panel.
    /// Returns true when a release was sent.
    @discardableResult
    static func releaseUnclaimedSubscription(type: String, payload: [String: Any], claimed: Bool,
                                             send: ([String: Any]) -> Bool) -> Bool {
        guard !claimed, type == "agent.timeline.set_subscription.response",
              let requestId = payload["requestId"] as? String, requestId.hasPrefix("tl-sub-"),
              let id = payload["subscriptionId"] as? String else { return false }
        return send(releaseRequest(id))
    }

    private func handleSubscribeResponse(_ payload: [String: Any]) -> Bool {
        guard let requestId = payload["requestId"] as? String else { return false }
        let id = payload["subscriptionId"] as? String
        if requestId == subscribeRequestId {
            subscribeRequestId = nil
            if let error = Self.errorText(payload) {
                onError?(error)
            } else {
                subscriptionId = id
            }
            return true
        }
        if abandonedSubscribeRequestIds.remove(requestId) != nil {
            // Answered after this client stopped or re-watched: nobody wants it.
            if let id { release(id) }
            return true
        }
        return false
    }

    private func apply(type: String, payload: [String: Any]) {
        switch type {
        case "fetch_agent_timeline_response":
            guard matchesAgent(payload),
                  let requestId = payload["requestId"] as? String, requestId == fetchRequestId else { return }
            fetchRequestId = nil
            if let error = Self.errorText(payload) {
                fetchFailed(error)
                return
            }
            retryCount = 0
            TimelineReducer.applySnapshot(&state, payload: payload)
            changed()
        case "agent_stream":
            guard matchesAgent(payload), matchesSubscription(payload) else { return }
            TimelineReducer.applyStream(&state, payload: payload)
            changed()
        case "agent.timeline.replacement":
            guard matchesAgent(payload), matchesSubscription(payload) else { return }
            TimelineReducer.applyReplacement(&state, payload: payload)
            changed()
        case "send_agent_message_response":
            guard matchesAgent(payload),
                  let requestId = payload["requestId"] as? String,
                  pendingMessageIds.remove(requestId) != nil else { return }
            if let error = Self.errorText(payload) {
                onError?(error)
            } else if payload["accepted"] as? Bool == false {
                onError?(L("Message was not accepted", "消息未被接受"))
            }
        case "cancel_agent_response":
            guard matchesAgent(payload),
                  let requestId = payload["requestId"] as? String, requestId == cancelRequestId else { return }
            cancelRequestId = nil
            if let error = Self.errorText(payload) { onError?(error) }
        case "rpc_error":
            guard let requestId = payload["requestId"] as? String, requestId.hasPrefix("tl-") else { return }
            let error = payload["error"] as? String ?? L("Request failed", "请求失败")
            if requestId == fetchRequestId {
                fetchRequestId = nil
                fetchFailed(error)
            } else if requestId == subscribeRequestId {
                subscribeRequestId = nil
                onError?(error)
            } else if abandonedSubscribeRequestIds.remove(requestId) != nil {
                break
            } else if requestId == cancelRequestId {
                cancelRequestId = nil
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

    /// Any non-null `error` is a failure; show it when it is a string.
    private static func errorText(_ payload: [String: Any]) -> String? {
        guard let value = payload["error"], !(value is NSNull) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        return L("Request failed", "请求失败")
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

    private func notConnectedOnce() {
        guard !reportedDisconnect else { return }
        reportedDisconnect = true
        notConnected()
    }

    private func beginWatch() {
        reportedDisconnect = false
        invalidateRetry()
        fetchTail()
        subscribe()
    }

    private func subscribe() {
        guard let agentId else { return }
        let requestId = Self.newId("sub")
        subscribeRequestId = requestId
        if !send([
            "type": "agent.timeline.set_subscription.request",
            "agentIds": [agentId],
            "requestId": requestId,
        ]) {
            subscribeRequestId = nil
            notConnectedOnce()
        }
    }

    /// Gives up this client's subscription: releases the one it holds and marks a pending
    /// subscribe as abandoned (its response is released when it arrives). Never sends `[]`.
    private func releaseSubscription() {
        if let subscriptionId {
            self.subscriptionId = nil
            release(subscriptionId)
        }
        if let subscribeRequestId {
            self.subscribeRequestId = nil
            abandonedSubscribeRequestIds.insert(subscribeRequestId)
        }
    }

    /// A failed send needs no retry: the socket is gone and its subscriptions with it.
    private func release(_ id: String) {
        releasedSubscriptionIds.insert(id)
        _ = send(Self.releaseRequest(id))
    }

    private static func releaseRequest(_ subscriptionId: String) -> [String: Any] {
        [
            "type": "subscription.release.request",
            "subscriptionId": subscriptionId,
            "requestId": newId("release"),
        ]
    }

    /// Frames tagged with a subscription id must be this client's: once it knows its id, only
    /// that one; before, anything but a subscription it already released.
    private func matchesSubscription(_ payload: [String: Any]) -> Bool {
        guard let id = payload["subscriptionId"] as? String else { return true }
        if let subscriptionId { return id == subscriptionId }
        return !releasedSubscriptionIds.contains(id)
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
            notConnectedOnce()
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
