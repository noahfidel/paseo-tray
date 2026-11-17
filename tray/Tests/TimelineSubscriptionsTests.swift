import Foundation

private let subType = "agent.timeline.set_subscription.request"

private func lastSub(_ sender: FakeSender) -> [String: Any]? { sender.messages(subType).last }

private func stream(_ agentId: String, seq: Int, text: String) -> [String: Any] {
    ["agentId": agentId, "epoch": "e1", "seq": seq,
     "event": ["type": "timeline", "item": ["type": "assistant_message", "text": text]]]
}

func testSubscriptionUnion() {
    let sender = FakeSender()
    let subs = TimelineSubscriptions(send: { sender.send($0) })
    let a = subs.register(onError: { _ in })
    let b = subs.register(onError: { _ in })
    subs.setAgent("a1", for: a)
    expect(lastSub(sender)?["agentIds"] as? [String] == ["a1"], "subscriptions: one watcher sends its agent")
    subs.setAgent("b1", for: b)
    expect(lastSub(sender)?["agentIds"] as? [String] == ["a1", "b1"], "subscriptions: two watchers send the union")
    expect((lastSub(sender)?["requestId"] as? String)?.hasPrefix("tl-") == true, "subscriptions: request id has tl- prefix")
    subs.setAgent(nil, for: a)
    expect(lastSub(sender)?["agentIds"] as? [String] == ["b1"], "subscriptions: one stops, the other remains")
    subs.setAgent("b1", for: a)
    expect(lastSub(sender)?["agentIds"] as? [String] == ["b1"], "subscriptions: same agent twice is sent once")
    subs.unregister(a)
    expect(lastSub(sender)?["agentIds"] as? [String] == ["b1"], "subscriptions: unregister sends the rest")
    let count = sender.messages(subType).count
    let idle = subs.register(onError: { _ in })
    subs.unregister(idle)
    expect(sender.messages(subType).count == count, "subscriptions: unregistering an idle watcher sends nothing")
    subs.setAgent(nil, for: b)
    expect(lastSub(sender)?["agentIds"] as? [String] == [], "subscriptions: last one stopping sends []")
}

func testSubscriptionResubscribe() {
    let sender = FakeSender()
    let subs = TimelineSubscriptions(send: { sender.send($0) })
    let a = subs.register(onError: { _ in })
    subs.resubscribe()
    expect(sender.sent.isEmpty, "subscriptions: reconnect with nothing watched sends nothing")
    let b = subs.register(onError: { _ in })
    subs.setAgent("a1", for: a)
    subs.setAgent("b1", for: b)
    let before = sender.messages(subType)
    subs.resubscribe()
    let after = sender.messages(subType)
    expect(after.count == before.count + 1 && after.last?["agentIds"] as? [String] == ["a1", "b1"],
           "subscriptions: reconnect re-sends the union once")
    expect(after.last?["requestId"] as? String != before.last?["requestId"] as? String, "subscriptions: reconnect uses a fresh id")
    sender.connected = false
    expect(!subs.setAgent("a2", for: a), "subscriptions: setAgent reports a send that never left")
    expect(!subs.setAgent("a1", for: 999), "subscriptions: unknown watcher sends nothing")
}

func testSubscriptionErrorRouting() {
    let sender = FakeSender()
    let subs = TimelineSubscriptions(send: { sender.send($0) })
    var errorsA: [String] = [], errorsB: [String] = [], errorsIdle: [String] = []
    let a = subs.register(onError: { errorsA.append($0) })
    let b = subs.register(onError: { errorsB.append($0) })
    _ = subs.register(onError: { errorsIdle.append($0) })
    subs.setAgent("a1", for: a)
    let first = lastSub(sender)?["requestId"] as Any
    subs.setAgent("b1", for: b)
    let second = lastSub(sender)?["requestId"] as Any
    subs.handle(type: "agent.timeline.set_subscription.response", payload: ["requestId": first, "error": "old"])
    expect(errorsA.isEmpty && errorsB.isEmpty, "subscriptions: superseded response ignored")
    subs.handle(type: "agent.timeline.set_subscription.response", payload: ["requestId": second, "error": NSNull()])
    expect(errorsA.isEmpty && errorsB.isEmpty, "subscriptions: ok response is silent")
    subs.setAgent("b2", for: b)
    let third = lastSub(sender)?["requestId"] as Any
    subs.handle(type: "agent.timeline.set_subscription.response", payload: ["requestId": third, "error": "denied"])
    expect(errorsA == ["denied"] && errorsB == ["denied"] && errorsIdle.isEmpty,
           "subscriptions: failure goes to every watcher in the request, not idle ones")
    subs.handle(type: "agent.timeline.set_subscription.response", payload: ["requestId": third, "error": "again"])
    expect(errorsA.count == 1, "subscriptions: a finished request is not reported twice")
    subs.setAgent(nil, for: a)
    let fourth = lastSub(sender)?["requestId"] as Any
    subs.handle(type: "rpc_error", payload: ["requestId": fourth, "error": "boom"])
    expect(errorsA.count == 1 && errorsB == ["denied", "boom"], "subscriptions: rpc_error goes only to watchers in the request")
    subs.handle(type: "rpc_error", payload: ["requestId": "tl-fetch-x", "error": "other"])
    expect(errorsB.count == 2, "subscriptions: rpc_error for another request ignored")
}

/// Two panels' clients on one connection: each streams, sends and stops only its own agent.
func testTwoTimelineClientsStayIndependent() {
    let sender = FakeSender()
    let subs = TimelineSubscriptions(send: { sender.send($0) })
    var errorsA: [String] = [], errorsB: [String] = []
    let clientA = TimelineClient(send: { sender.send($0) }, subscriptions: subs)
    let clientB = TimelineClient(send: { sender.send($0) }, subscriptions: subs)
    clientA.onError = { errorsA.append($0) }
    clientB.onError = { errorsB.append($0) }
    var changesA = 0, changesB = 0
    clientA.watch(agentId: "a1")
    clientB.watch(agentId: "b1")
    clientA.onChange = { _ in changesA += 1 }
    clientB.onChange = { _ in changesB += 1 }
    expect(lastSub(sender)?["agentIds"] as? [String] == ["a1", "b1"], "two clients: subscription is the union")

    let fetches = sender.fetches
    for fetch in fetches {
        let payload: [String: Any] = [
            "agentId": fetch["agentId"] as Any, "requestId": fetch["requestId"] as Any,
            "agent": ["status": "idle"], "epoch": "e1",
            "entries": [["item": ["type": "user_message", "text": "hi"], "seqStart": 1, "seqEnd": 1]],
            "endCursor": ["epoch": "e1", "seq": 5], "error": NSNull(),
        ]
        clientA.handle(type: "fetch_agent_timeline_response", payload: payload)
        clientB.handle(type: "fetch_agent_timeline_response", payload: payload)
    }
    expect(changesA == 1 && changesB == 1, "two clients: each applies only its own snapshot")
    let rowsB = clientB.state.rows.count
    clientA.handle(type: "agent_stream", payload: stream("a1", seq: 6, text: "for A"))
    clientB.handle(type: "agent_stream", payload: stream("a1", seq: 6, text: "for A"))
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
    expect(lastSub(sender)?["agentIds"] as? [String] == ["b1"], "two clients: closing A keeps B subscribed")
    expect(clientB.agentId == "b1", "two clients: B still watching")
    clientB.handle(type: "agent_stream", payload: stream("b1", seq: 6, text: "for B"))
    expect(changesB == 2, "two clients: B keeps streaming after A stops")
}

func testTimelineClientDeinitLeavesSubscription() {
    let sender = FakeSender()
    let subs = TimelineSubscriptions(send: { sender.send($0) })
    let keep = TimelineClient(send: { sender.send($0) }, subscriptions: subs)
    keep.watch(agentId: "b1")
    do {
        let gone = TimelineClient(send: { sender.send($0) }, subscriptions: subs)
        gone.watch(agentId: "a1")
        expect(subs.agentIds == ["b1", "a1"], "deinit: both watched")
    }
    expect(subs.agentIds == ["b1"] && lastSub(sender)?["agentIds"] as? [String] == ["b1"],
           "deinit: a freed client drops its agent from the union")
}

func runTimelineSubscriptionsTests() {
    testSubscriptionUnion()
    testSubscriptionResubscribe()
    testSubscriptionErrorRouting()
    testTwoTimelineClientsStayIndependent()
    testTimelineClientDeinitLeavesSubscription()
}
