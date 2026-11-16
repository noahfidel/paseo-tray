import Foundation

/// Records everything the client sends; `connected` simulates PaseoClient's state.
final class FakeSender {
    var sent: [[String: Any]] = []
    var connected = true
    func send(_ message: [String: Any]) -> Bool {
        guard connected else { return false }
        sent.append(message)
        return true
    }
    func messages(_ type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
    var fetches: [[String: Any]] { messages("fetch_agent_timeline_request") }
}

private func makeClient() -> (TimelineClient, FakeSender, errors: () -> [String]) {
    let sender = FakeSender()
    var errors: [String] = []
    let client = TimelineClient(send: { sender.send($0) })
    client.onError = { errors.append($0) }
    return (client, sender, { errors })
}

private func snapshotPayload(_ request: [String: Any], agentId: String? = nil, seq: Int = 5,
                             error: String? = nil, text: String = "hi") -> [String: Any] {
    [
        "agentId": agentId ?? request["agentId"] as Any,
        "requestId": request["requestId"] as Any,
        "agent": ["status": "idle"],
        "epoch": "e1",
        "entries": [["item": ["type": "user_message", "text": text], "seqStart": 1, "seqEnd": 1]],
        "endCursor": ["epoch": "e1", "seq": seq],
        "error": error.map { $0 as Any } ?? NSNull(),
    ]
}

private func streamPayload(agentId: String, seq: Int, text: String) -> [String: Any] {
    ["agentId": agentId, "epoch": "e1", "seq": seq,
     "event": ["type": "timeline", "item": ["type": "assistant_message", "text": text]]]
}

func testWatchSendsTailFetchAndSubscription() {
    let (client, sender, _) = makeClient()
    client.watch(agentId: "a1")
    let fetch = sender.fetches.first
    expect(sender.fetches.count == 1, "watch sends one tail fetch")
    expect(fetch?["agentId"] as? String == "a1" && fetch?["direction"] as? String == "tail"
        && fetch?["limit"] as? Int == 50 && fetch?["projection"] as? String == "projected", "fetch shape")
    expect((fetch?["requestId"] as? String)?.hasPrefix("tl-") == true, "fetch id has tl- prefix")
    let sub = sender.messages("agent.timeline.set_subscription.request").first
    expect(sub?["agentIds"] as? [String] == ["a1"], "subscribe [agentId]")
    expect((sub?["requestId"] as? String)?.hasPrefix("tl-") == true, "subscribe id has tl- prefix")
    expect(client.agentId == "a1", "agentId set")
}

func testStaleAndForeignResponsesIgnored() {
    let (client, sender, _) = makeClient()
    client.watch(agentId: "a1")
    let request = sender.fetches[0]
    var changes = 0
    client.onChange = { _ in changes += 1 }
    var stale = snapshotPayload(request); stale["requestId"] = "tl-fetch-old"
    client.handle(type: "fetch_agent_timeline_response", payload: stale)
    expect(!client.state.hasSnapshot && changes == 0, "stale requestId ignored")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(request, agentId: "other"))
    expect(!client.state.hasSnapshot, "other agentId snapshot ignored")
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "other", seq: 6, text: "x"))
    expect(client.state.buffered.isEmpty, "other agentId stream ignored")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(request))
    expect(client.state.hasSnapshot && changes == 1, "matching snapshot applied")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(request, text: "again"))
    expect(changes == 1, "duplicate response for a finished request ignored")
}

func testGapIssuesOneRefetchAtATime() {
    let (client, sender, _) = makeClient()
    client.watch(agentId: "a1")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[0]))
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "a1", seq: 9, text: "x"))
    expect(sender.fetches.count == 2, "gap triggers a refetch")
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "a1", seq: 10, text: "y"))
    client.handle(type: "agent.timeline.replacement", payload: ["agentId": "a1", "epoch": "e2"])
    expect(sender.fetches.count == 2, "no concurrent fetch while one is in flight")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[0], seq: 10))
    expect(sender.fetches.count == 2 && client.state.needsRefetch, "response to superseded request ignored")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[1], seq: 10))
    expect(!client.state.needsRefetch && sender.fetches.count == 2, "refetch clears needsRefetch")
}

func testResubscribeRefetchesAndResubscribes() {
    let (client, sender, _) = makeClient()
    client.resubscribe()
    expect(sender.sent.isEmpty, "resubscribe without a watch sends nothing")
    client.watch(agentId: "a1")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[0]))
    client.resubscribe()
    expect(sender.fetches.count == 2, "resubscribe refetches the tail")
    expect(sender.messages("agent.timeline.set_subscription.request").count == 2, "resubscribe subscribes again")
    expect(sender.fetches[0]["requestId"] as? String != sender.fetches[1]["requestId"] as? String, "fresh requestId")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[0]))
    expect(client.state.needsRefetch, "pre-reconnect response ignored")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[1]))
    expect(!client.state.needsRefetch, "post-reconnect response applied")
}

func testFollowUpAndCancelShape() {
    let (client, sender, errors) = makeClient()
    client.watch(agentId: "a1")
    client.sendFollowUp("hello")
    let message = sender.messages("send_agent_message_request").first
    expect(message?["agentId"] as? String == "a1" && message?["text"] as? String == "hello", "follow-up fields")
    expect((message?["requestId"] as? String)?.hasPrefix("tl-") == true, "follow-up id has tl- prefix")
    expect(UUID(uuidString: message?["messageId"] as? String ?? "") != nil, "messageId is a UUID")
    client.handle(type: "send_agent_message_response",
                  payload: ["agentId": "a1", "requestId": message?["requestId"] as Any, "accepted": false, "error": "busy"])
    expect(errors() == ["busy"], "rejected follow-up reports the daemon error")
    client.handle(type: "send_agent_message_response",
                  payload: ["agentId": "a1", "requestId": "tl-unknown", "accepted": false, "error": "nope"])
    expect(errors().count == 1, "unknown send response ignored")
    client.stop()
    let cancel = sender.messages("cancel_agent_request").first
    expect(cancel?["agentId"] as? String == "a1" && (cancel?["requestId"] as? String)?.hasPrefix("tl-") == true, "cancel shape")
}

func testNotConnectedReportsError() {
    let (client, sender, errors) = makeClient()
    sender.connected = false
    client.watch(agentId: "a1")
    expect(errors().contains(L("Paseo isn't connected", "Paseo 未连接")), "watch while disconnected reports error")
    let before = errors().count
    let sent = client.sendFollowUp("x")
    expect(errors().count == before + 1, "follow-up while disconnected reports error")
    expect(!sent, "follow-up while disconnected returns false")
    let idle = TimelineClient(send: { _ in true })
    expect(!idle.sendFollowUp("x"), "follow-up while not watching returns false")
    let (live, _, _) = makeClient()
    live.watch(agentId: "a1")
    expect(live.sendFollowUp("x"), "follow-up that was sent returns true")
}

func testFetchErrorRetriesWithDelayNotTightLoop() {
    let (client, sender, errors) = makeClient()
    client.watch(agentId: "a1")
    client.handle(type: "fetch_agent_timeline_response",
                  payload: snapshotPayload(sender.fetches[0], error: "boom"))
    expect(sender.fetches.count == 1 && errors().isEmpty, "error snapshot schedules a delayed retry, not an immediate one")
    client.handle(type: "rpc_error", payload: ["requestId": sender.fetches[0]["requestId"] as Any, "error": "x"])
    expect(sender.fetches.count == 1, "late rpc_error for a finished request does nothing")
    // Pump the run loop past the 1 s delay.
    RunLoop.main.run(until: Date().addingTimeInterval(1.4))
    expect(sender.fetches.count == 2, "retry fired after about a second")
}

func testStopWatchingUnsubscribes() {
    let (client, sender, _) = makeClient()
    client.watch(agentId: "a1")
    client.stopWatching()
    let subs = sender.messages("agent.timeline.set_subscription.request")
    expect(subs.last?["agentIds"] as? [String] == [], "stopWatching subscribes []")
    expect(client.agentId == nil, "agentId cleared")
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "a1", seq: 6, text: "x"))
    expect(client.state.buffered.isEmpty, "payloads after stopWatching ignored")
}

func testLostFollowUpSurfacedOnResubscribe() {
    let (client, sender, errors) = makeClient()
    client.watch(agentId: "a1")
    client.sendFollowUp("hello")
    client.resubscribe()
    expect(errors() == [L("Your last message may not have been sent", "你的上一条消息可能未发送")], "lost follow-up reported once")
    expect(sender.messages("send_agent_message_request").count == 1, "no automatic resend")
    client.resubscribe()
    expect(errors().count == 1, "pending ids drained")
    client.sendFollowUp("again")
    client.watch(agentId: "a1")
    let id = sender.messages("send_agent_message_request").last?["requestId"] as Any
    client.handle(type: "send_agent_message_response", payload: ["agentId": "a1", "requestId": id, "accepted": false, "error": "x"])
    expect(errors().count == 1, "watch clears pending follow-ups")
}

func testRefetchResumesAfterGiveUpAndResubscribe() {
    let (client, sender, errors) = makeClient()
    client.watch(agentId: "a1")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches[0]))
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "a1", seq: 9, text: "x"))
    for _ in 0..<3 {
        client.handle(type: "rpc_error", payload: ["requestId": sender.fetches.last?["requestId"] as Any, "error": "boom"])
        RunLoop.main.run(until: Date().addingTimeInterval(5.3))
    }
    expect(errors() == ["boom"], "gave up after retries")
    let count = sender.fetches.count
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "a1", seq: 12, text: "y"))
    expect(sender.fetches.count == count, "no refetch after give-up")
    client.resubscribe()
    expect(sender.fetches.count == count + 1, "resubscribe fetches again after give-up")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches.last!, seq: 12))
    client.handle(type: "agent_stream", payload: streamPayload(agentId: "a1", seq: 20, text: "z"))
    expect(sender.fetches.count == count + 2, "gap refetches again")
}

func testDisconnectedErrorsAndNonStringErrors() {
    let (client, sender, errors) = makeClient()
    sender.connected = false
    client.watch(agentId: "a1")
    expect(errors().count == 1, "not connected reported once per watch")
    client.stopWatching()
    expect(errors().count == 1, "stopWatching while disconnected is silent")
    sender.connected = true
    client.watch(agentId: "a1")
    client.handle(type: "fetch_agent_timeline_response", payload: snapshotPayload(sender.fetches.last!, error: nil).merging(["error": ["code": 1]]) { $1 })
    expect(sender.fetches.count == 1 && !client.state.hasSnapshot, "non-string error is a failure")
    client.sendFollowUp("hi")
    let id = sender.messages("send_agent_message_request").last?["requestId"] as Any
    client.handle(type: "send_agent_message_response", payload: ["agentId": "a1", "requestId": id, "accepted": true, "error": ["code": 2]])
    expect(errors().last == L("Request failed", "请求失败"), "non-string send error shows generic text")
}

func testFailedStopSurfacesError() {
    let (client, sender, errors) = makeClient()
    client.watch(agentId: "a1")
    client.stop()
    let id = sender.messages("cancel_agent_request").last?["requestId"] as Any
    client.handle(type: "cancel_agent_response", payload: ["agentId": "a1", "requestId": id, "agent": NSNull()])
    expect(errors().isEmpty, "testFailedStopSurfacesError: ok response is silent")
    client.handle(type: "rpc_error", payload: ["requestId": "tl-cancel-unknown", "error": "x"])
    expect(errors().isEmpty, "testFailedStopSurfacesError: unknown rpc_error ignored")
    client.stop()
    let id2 = sender.messages("cancel_agent_request").last?["requestId"] as Any
    client.handle(type: "rpc_error", payload: ["requestId": id2, "error": "cannot cancel"])
    expect(errors() == ["cannot cancel"], "testFailedStopSurfacesError: rpc_error reported")
    client.stop()
    let id3 = sender.messages("cancel_agent_request").last?["requestId"] as Any
    client.handle(type: "cancel_agent_response", payload: ["agentId": "a1", "requestId": id3, "error": "nope"])
    expect(errors().last == "nope", "testFailedStopSurfacesError: response error reported")
}

func testActiveTurnBehaviorOnFollowUp() {
    let (client, sender, _) = makeClient()
    client.watch(agentId: "a1", activeTurnBehavior: "steer")
    client.sendFollowUp("hi")
    expect(sender.messages("send_agent_message_request").last?["activeTurnBehavior"] as? String == "steer", "steer watch sends activeTurnBehavior")
    client.watch(agentId: "a2")
    client.sendFollowUp("hi")
    expect(sender.messages("send_agent_message_request").last?["activeTurnBehavior"] == nil, "plain watch sends no activeTurnBehavior")
}

func runTimelineClientTests() {
    testActiveTurnBehaviorOnFollowUp()
    testFailedStopSurfacesError()
    testLostFollowUpSurfacedOnResubscribe()
    testRefetchResumesAfterGiveUpAndResubscribe()
    testDisconnectedErrorsAndNonStringErrors()
    testWatchSendsTailFetchAndSubscription()
    testStaleAndForeignResponsesIgnored()
    testGapIssuesOneRefetchAtATime()
    testResubscribeRefetchesAndResubscribes()
    testFollowUpAndCancelShape()
    testNotConnectedReportsError()
    testFetchErrorRetriesWithDelayNotTightLoop()
    testStopWatchingUnsubscribes()
}
