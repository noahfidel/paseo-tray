import Foundation

/// One Quick Ask panel's bots fetches: at most one runs at a time, and only the latest one's
/// result counts (an older fetch from before a reset must not settle the picker). Foundation only.
struct BotsFetchGate {
    private(set) var generation = 0
    private(set) var inFlight = false

    /// A token for the new fetch, or nil when one is already running (let that one finish).
    mutating func start() -> Int? {
        guard !inFlight else { return nil }
        inFlight = true
        generation += 1
        return generation
    }

    /// True when `token` is the running fetch: its result may be applied. Ends the fetch.
    mutating func finish(_ token: Int) -> Bool {
        guard inFlight, token == generation else { return false }
        inFlight = false
        return true
    }

    /// The panel's session changed (closed or reset): any fetch still running is stale.
    mutating func reset() {
        inFlight = false
        generation += 1
    }
}
