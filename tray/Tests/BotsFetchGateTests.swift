import Foundation

func runBotsFetchGateTests() {
    var gate = BotsFetchGate()
    let first = gate.start()
    expect(first != nil && gate.inFlight, "fetchGate: first fetch starts")
    expect(gate.start() == nil, "fetchGate: no second fetch while one runs")
    expect(gate.finish(first!), "fetchGate: the running fetch's result applies")
    expect(!gate.inFlight, "fetchGate: finishing ends the fetch")
    expect(!gate.finish(first!), "fetchGate: a result applies once")

    // The coordinator's scenario: a slow fetch outlived a reset; its late failure must not settle.
    let slow = gate.start()!
    gate.reset()
    expect(!gate.inFlight, "fetchGate: reset clears in-flight")
    let fresh = gate.start()
    expect(fresh != nil && fresh != slow, "fetchGate: a fetch after reset gets a new token")
    expect(!gate.finish(slow), "fetchGate: the stale fetch's result is dropped")
    expect(gate.inFlight, "fetchGate: the stale result leaves the latest running")
    expect(gate.finish(fresh!), "fetchGate: the latest fetch's result applies")

    var idle = BotsFetchGate()
    expect(!idle.finish(1), "fetchGate: nothing running, nothing applies")
}
