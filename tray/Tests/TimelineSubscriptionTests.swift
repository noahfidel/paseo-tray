import Foundation

// Owned subscriptions: each TimelineClient holds and releases its own server subscription.

private let subType = "agent.timeline.set_subscription.request"
private let releaseType = "subscription.release.request"

private func stream(_ agentId: String, seq: Int, text: String, subscriptionId: String? = nil) -> [String: Any] {
    var payload: [String: Any] = ["agentId": agentId, "epoch": "e1", "seq": seq,
                                  "event": ["type": "timeline", "item": ["type": "assistant_message", "text": text]]]
    if let subscriptionId { payload["subscriptionId"] = subscriptionId }
    return payload
}

private func snapshot(for fetch: [String: Any]) -> [String: Any] {
    [
        "agentId": fetch["agentId"] as Any, "requestId": fetch["requestId"] as Any,
        "agent": ["status": "idle"], "epoch": "e1",
        "entries": [["item": ["type": "user_message", "text": "hi"], "seqStart": 1, "seqEnd": 1]],
        "endCursor": ["epoch": "e1", "seq": 5], "error": NSNull(),
    ]
}

/// Answers the last subscribe request with `subscriptionId`.
private func answerSubscribe(_ client: TimelineClient, _ sender: FakeSender, _ subscriptionId: String,
                             request: [String: Any]? = nil) {
    let sub = request ?? sender.messages(subType).last!
    client.handle(type: "agent.timeline.set_subscription.response",
                  payload: ["agentIds": sub["agentIds"] as Any, "requestId": sub["requestId"] as Any,
                            "subscriptionId": subscriptionId])
}

func testSubscribeResponseRecordsIdAndStopReleasesIt() {
    let sender = FakeSender()
    let client = TimelineClient(send: { sender.send($0) })
    client.watch(agentId: "a1")
    expect(sender.messages(subType).last?["agentIds"] as? [String] == ["a1"], "owned: subscribes only its own agent")
    answerSubscribe(client, sender, "s1")
    expect(sender.messages(releaseType).isEmpty, "owned: an answered subscribe releases nothing")
    client.stopWatching()
    let release = sender.messages(releaseType).last
    expect(sender.messages(releaseType).count == 1 && release?["subscriptionId"] as? String == "s1",
           "owned: stop releases the recorded subscription")
    expect((release?["requestId"] as? String)?.hasPrefix("tl-") == true, "owned: release id has tl- prefix")
    expect(sender.messages(subType).count == 1, "owned: stop never sends an empty subscription")
    client.stopWatching()
    expect(sender.messages(releaseType).count == 1, "owned: a second stop releases nothing")
}

func testRewatchReleasesOldSubscription() {
    let sender = FakeSender()
    let client = TimelineClient(send: { sender.send($0) })
    client.watch(agentId: "a1")
    answerSubscribe(client, sender, "s1")
    client.watch(agentId: "a2")
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["s1"], "owned: re-watch releases the old one")
    expect(sender.messages(subType).last?["agentIds"] as? [String] == ["a2"], "owned: re-watch subscribes the new agent")
    answerSubscribe(client, sender, "s2")
    var changes = 0
    client.onChange = { _ in changes += 1 }
    client.handle(type: "fetch_agent_timeline_response", payload: snapshot(for: sender.fetches.last!))
    client.handle(type: "agent_stream", payload: stream("a2", seq: 6, text: "x", subscriptionId: "s1"))
    expect(changes == 1, "owned: a frame from the released subscription is dropped")
    client.handle(type: "agent_stream", payload: stream("a2", seq: 6, text: "x", subscriptionId: "s2"))
    expect(changes == 2, "owned: a frame from its own subscription applies")
}

func testLateSubscribeResponseIsReleased() {
    let sender = FakeSender()
    let client = TimelineClient(send: { sender.send($0) })
    client.watch(agentId: "a1")
    let first = sender.messages(subType).last!
    client.stopWatching()
    expect(sender.messages(releaseType).isEmpty, "owned: stop before the response has nothing to release yet")
    answerSubscribe(client, sender, "late", request: first)
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["late"],
           "owned: a response after stop is released at once")
    answerSubscribe(client, sender, "late", request: first)
    expect(sender.messages(releaseType).count == 1, "owned: a late response is released once")

    client.watch(agentId: "a1")
    let second = sender.messages(subType).last!
    client.watch(agentId: "a2")
    answerSubscribe(client, sender, "s2")
    answerSubscribe(client, sender, "old", request: second)
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["late", "old"],
           "owned: a response for an earlier watch is released, the current one kept")
    client.stopWatching()
    expect(sender.messages(releaseType).last?["subscriptionId"] as? String == "s2", "owned: the current one is kept until stop")
}

func testReconnectResubscribesWithoutRelease() {
    let sender = FakeSender()
    let client = TimelineClient(send: { sender.send($0) })
    client.watch(agentId: "a1")
    answerSubscribe(client, sender, "s1")
    client.resubscribe()
    expect(sender.messages(releaseType).isEmpty, "owned: reconnect doesn't release the dead socket's subscription")
    expect(sender.messages(subType).count == 2 && sender.messages(subType).last?["agentIds"] as? [String] == ["a1"],
           "owned: reconnect subscribes again")
    answerSubscribe(client, sender, "s9")
    client.stopWatching()
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["s9"],
           "owned: after reconnect only the new subscription is released")
}

func testSubscribeErrorReported() {
    let sender = FakeSender()
    var errors: [String] = []
    let client = TimelineClient(send: { sender.send($0) })
    client.onError = { errors.append($0) }
    client.watch(agentId: "a1")
    let sub = sender.messages(subType).last!
    client.handle(type: "rpc_error", payload: ["requestId": sub["requestId"] as Any, "error": "denied"])
    expect(errors == ["denied"], "owned: subscribe rpc_error reported")
    client.handle(type: "rpc_error", payload: ["requestId": "tl-release-x", "error": "gone"])
    expect(errors.count == 1, "owned: release errors are ignored")
}

func testDeinitReleasesSubscription() {
    let sender = FakeSender()
    do {
        let client = TimelineClient(send: { sender.send($0) })
        client.watch(agentId: "a1")
        answerSubscribe(client, sender, "s1")
    }
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["s1"], "owned: a freed client releases")
}

/// Two panels' clients on one connection: each subscribes, streams, stops and releases only its own.
func testTwoTimelineClientsStayIndependent() {
    let sender = FakeSender()
    var errorsA: [String] = [], errorsB: [String] = []
    let clientA = TimelineClient(send: { sender.send($0) })
    let clientB = TimelineClient(send: { sender.send($0) })
    clientA.onError = { errorsA.append($0) }
    clientB.onError = { errorsB.append($0) }
    clientA.watch(agentId: "a1")
    let subA = sender.messages(subType).last!
    clientB.watch(agentId: "b1")
    let subB = sender.messages(subType).last!
    expect(subA["agentIds"] as? [String] == ["a1"] && subB["agentIds"] as? [String] == ["b1"],
           "two clients: each subscribes its own agent")
    for client in [clientA, clientB] {
        answerSubscribe(client, sender, "sA", request: subA)
        answerSubscribe(client, sender, "sB", request: subB)
    }
    expect(sender.messages(releaseType).isEmpty, "two clients: neither releases the other's response")

    var changesA = 0, changesB = 0
    clientA.onChange = { _ in changesA += 1 }
    clientB.onChange = { _ in changesB += 1 }
    for fetch in sender.fetches {
        clientA.handle(type: "fetch_agent_timeline_response", payload: snapshot(for: fetch))
        clientB.handle(type: "fetch_agent_timeline_response", payload: snapshot(for: fetch))
    }
    expect(changesA == 1 && changesB == 1, "two clients: each applies only its own snapshot")
    let rowsB = clientB.state.rows.count
    for client in [clientA, clientB] {
        client.handle(type: "agent_stream", payload: stream("a1", seq: 6, text: "for A", subscriptionId: "sA"))
    }
    expect(changesA == 2 && changesB == 1 && clientB.state.rows.count == rowsB, "two clients: A's stream doesn't touch B")

    clientA.stop()
    clientB.stop()
    let cancels = sender.messages("cancel_agent_request")
    expect(cancels.map { $0["agentId"] as? String } == ["a1", "b1"], "two clients: each Stop cancels its own agent")
    let cancelA = cancels[0]["requestId"] as? String, cancelB = cancels[1]["requestId"] as? String
    expect(cancelA != nil && cancelA != cancelB, "two clients: own cancel request ids")
    for client in [clientA, clientB] {
        client.handle(type: "rpc_error", payload: ["requestId": cancelA as Any, "error": "cannot cancel"])
    }
    expect(errorsA == ["cannot cancel"] && errorsB.isEmpty, "two clients: A's cancel error reaches only A")

    clientA.stopWatching()
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["sA"],
           "two clients: closing A releases only A's subscription")
    expect(clientB.agentId == "b1", "two clients: B still watching")
    clientB.handle(type: "agent_stream", payload: stream("b1", seq: 6, text: "for B", subscriptionId: "sB"))
    expect(changesB == 2, "two clients: B keeps streaming after A stops")
}

func testUnclaimedSubscribeResponseIsReleased() {
    let sender = FakeSender()
    let send: ([String: Any]) -> Bool = { sender.send($0) }
    var client: TimelineClient? = TimelineClient(send: send)
    client?.watch(agentId: "a1")
    let sub = sender.messages(subType).last!
    client = nil
    expect(sender.messages(releaseType).isEmpty, "unclaimed: a client freed before its answer has nothing to release")
    let response: [String: Any] = ["agentIds": ["a1"], "requestId": sub["requestId"] as Any, "subscriptionId": "orphan"]
    let claimed = client?.handle(type: "agent.timeline.set_subscription.response", payload: response) ?? false
    expect(TimelineClient.releaseUnclaimedSubscription(type: "agent.timeline.set_subscription.response",
                                                       payload: response, claimed: claimed, send: send),
           "unclaimed: the connection releases a response nobody claimed")
    expect(sender.messages(releaseType).map { $0["subscriptionId"] as? String } == ["orphan"], "unclaimed: release names its id")

    let live = TimelineClient(send: send)
    live.watch(agentId: "b1")
    let liveSub = sender.messages(subType).last!
    let liveResponse: [String: Any] = ["agentIds": ["b1"], "requestId": liveSub["requestId"] as Any, "subscriptionId": "kept"]
    let liveClaimed = live.handle(type: "agent.timeline.set_subscription.response", payload: liveResponse)
    expect(liveClaimed, "unclaimed: a client claims its own response")
    expect(!TimelineClient.releaseUnclaimedSubscription(type: "agent.timeline.set_subscription.response",
                                                        payload: liveResponse, claimed: liveClaimed, send: send),
           "unclaimed: a claimed response is not released")
    expect(sender.messages(releaseType).count == 1, "unclaimed: nothing extra sent")
    expect(!TimelineClient.releaseUnclaimedSubscription(type: "agent.timeline.set_subscription.response",
                                                        payload: ["requestId": "other-1", "subscriptionId": "x"],
                                                        claimed: false, send: send),
           "unclaimed: a response for another component's request is left alone")
    expect(!live.handle(type: "agent_stream", payload: stream("b1", seq: 6, text: "x")), "unclaimed: other messages aren't claims")
}

func runTimelineSubscriptionTests() {
    testUnclaimedSubscribeResponseIsReleased()
    testSubscribeResponseRecordsIdAndStopReleasesIt()
    testRewatchReleasesOldSubscription()
    testLateSubscribeResponseIsReleased()
    testReconnectResubscribesWithoutRelease()
    testSubscribeErrorReported()
    testDeinitReleasesSubscription()
    testTwoTimelineClientsStayIndependent()
}
