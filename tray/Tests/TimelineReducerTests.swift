import Foundation

var fixturesDirectory = ""

/// One recorded session message: `{"type": …, "payload": {…}}`.
struct Frame {
    let type: String
    let payload: [String: Any]
    var seq: Int? { payload["seq"] as? Int }
}

func loadFixture(_ name: String) -> [Frame] {
    let url = URL(fileURLWithPath: fixturesDirectory).appendingPathComponent(name + ".jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("FAIL missing fixture \(name)")
        exit(1)
    }
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return nil }
        return Frame(type: type, payload: payload)
    }
}

func apply(_ frame: Frame, to state: inout TimelineState) {
    switch frame.type {
    case "fetch_agent_timeline_response": TimelineReducer.applySnapshot(&state, payload: frame.payload)
    case "agent_stream": TimelineReducer.applyStream(&state, payload: frame.payload)
    case "agent.timeline.replacement": TimelineReducer.applyReplacement(&state, payload: frame.payload)
    default: break
    }
}

func replay(_ frames: [Frame]) -> TimelineState {
    var state = TimelineState()
    for frame in frames { apply(frame, to: &state) }
    return state
}

func snapshotOnly(_ frames: [Frame]) -> TimelineState {
    var state = TimelineState()
    if let first = frames.first(where: { $0.type == "fetch_agent_timeline_response" }) {
        apply(first, to: &state)
    }
    return state
}

func assistantTexts(_ state: TimelineState) -> [String] {
    state.rows.compactMap { if case .assistant(_, let text) = $0 { return text } else { return nil } }
}

func toolRows(_ state: TimelineState, callId: String) -> [(status: String, error: String?)] {
    state.rows.compactMap {
        if case .tool(let id, _, let status, let error) = $0, id == callId { return (status, error) }
        return nil
    }
}

func streamFrame(_ frames: [Frame], seq: Int) -> Frame {
    frames.first { $0.seq == seq }!
}

func chunkText(_ frame: Frame) -> String {
    let event = frame.payload["event"] as? [String: Any]
    let item = event?["item"] as? [String: Any]
    return item?["text"] as? String ?? ""
}

func testChunksAppendIntoOneAssistantRow() {
    let frames = loadFixture("stream-text-and-tools")
    let state = replay(frames)
    let expected = chunkText(streamFrame(frames, seq: 1090)) + chunkText(streamFrame(frames, seq: 1091))
    let streamed = assistantTexts(state).filter { $0.hasPrefix("assistant_message#1090") }
    expect(streamed == [expected], "testChunksAppendIntoOneAssistantRow")
    expect(state.rows.filter { if case .assistant(let id, _) = $0 { return id == "s1090" } else { return false } }.count == 1,
           "testChunksAppendIntoOneAssistantRow: stable id from first chunk seq")
}

func testToolStatusUpdatesInPlace() {
    let frames = loadFixture("stream-text-and-tools")
    var state = TimelineState()
    var countAtRunning: Int?
    for frame in frames {
        apply(frame, to: &state)
        if frame.seq == 1094 { countAtRunning = state.rows.count }
    }
    let rows = toolRows(state, callId: "call-15")
    expect(rows.count == 1, "testToolStatusUpdatesInPlace: one row for callId")
    expect(rows.first?.status == "completed", "testToolStatusUpdatesInPlace: final status completed")
    expect(countAtRunning == state.rows.count, "testToolStatusUpdatesInPlace: row count unchanged by completion")
    expect(state.turn == .idle, "testToolStatusUpdatesInPlace: turn_completed makes idle")
}

func testFailedToolKeepsError() {
    let state = snapshotOnly(loadFixture("stream-text-and-tools"))
    let rows = toolRows(state, callId: "call-4")
    expect(rows.first?.status == "failed" && rows.first?.error != nil, "testFailedToolKeepsError")
}

func testGapRequestsRefetch() {
    let frames = loadFixture("gap")
    var state = TimelineState()
    var rowsBeforeGap: [ChatRow] = []
    for frame in frames.dropLast() {
        if frame.seq == 1093 { rowsBeforeGap = state.rows }
        apply(frame, to: &state)
    }
    expect(state.needsRefetch, "testGapRequestsRefetch: needsRefetch after skipped seq")
    expect(state.rows == rowsBeforeGap, "testGapRequestsRefetch: rows unchanged by frames after the gap")
    apply(frames.last!, to: &state)
    expect(!state.needsRefetch, "testGapRequestsRefetch: cleared by snapshot")
    expect(state.rows == snapshotOnly([frames.last!]).rows, "testGapRequestsRefetch: rows equal the snapshot")
    expect(state.lastSeq == 1094, "testGapRequestsRefetch: lastSeq from snapshot")
}

func testReplacementRequestsRefetch() {
    let frames = loadFixture("replacement")
    var state = TimelineState()
    let oldEpoch = frames[0].payload["epoch"] as? String
    apply(frames[0], to: &state)
    apply(frames[1], to: &state)
    expect(state.epoch == oldEpoch && !state.needsRefetch, "testReplacementRequestsRefetch: same-epoch frame applies")
    apply(frames[2], to: &state)
    expect(state.needsRefetch, "testReplacementRequestsRefetch: new epoch requests refetch")
    apply(frames[3], to: &state)
    expect(!state.needsRefetch && state.epoch == frames[3].payload["epoch"] as? String && state.epoch != oldEpoch,
           "testReplacementRequestsRefetch: snapshot sets the new epoch")
}

func testStreamFrameWithOtherEpochRequestsRefetch() {
    let frames = loadFixture("stream-text-and-tools")
    var state = replay(Array(frames.prefix(1)))
    var other = streamFrame(frames, seq: 1090).payload
    other["epoch"] = "some-other-epoch"
    TimelineReducer.applyStream(&state, payload: other)
    expect(state.needsRefetch, "testStreamFrameWithOtherEpochRequestsRefetch")
}

func testDuplicateSeqIgnored() {
    let frames = loadFixture("stream-text-and-tools")
    let once = replay(Array(frames.prefix(3)))      // snapshot, 1090, 1091
    var twice = replay(Array(frames.prefix(3)))
    apply(frames[2], to: &twice)                    // 1091 again
    apply(frames[1], to: &twice)                    // 1090 again
    expect(twice == once && !twice.needsRefetch, "testDuplicateSeqIgnored")
}

func testStreamBeforeSnapshotIsBuffered() {
    let frames = loadFixture("stream-before-snapshot")
    var state = TimelineState()
    apply(frames[0], to: &state)
    apply(frames[1], to: &state)
    expect(state.rows.isEmpty && !state.hasSnapshot, "testStreamBeforeSnapshotIsBuffered: nothing rendered yet")
    apply(frames[2], to: &state)
    let text = assistantTexts(state).filter { $0.hasPrefix("assistant_message#1090") }
    let expected = chunkText(frames[0]) + chunkText(frames[1])
    expect(text == [expected], "testStreamBeforeSnapshotIsBuffered: no duplicated text")
    expect(state.lastSeq == 1091 && !state.needsRefetch, "testStreamBeforeSnapshotIsBuffered: buffered frame applied")
}

func testBufferIsCapped() {
    let frames = loadFixture("stream-before-snapshot")
    var state = TimelineState()
    for _ in 0..<2000 { apply(frames[0], to: &state) }
    expect(state.buffered.count <= 500, "testBufferIsCapped")
}

func testTurnCanceledAddsStoppedNotice() {
    let state = replay(loadFixture("canceled"))
    expect(state.turn == .canceled, "testTurnCanceledAddsStoppedNotice: turn")
    if case .notice(_, let text)? = state.rows.last {
        expect(text == L("Stopped", "已停止"), "testTurnCanceledAddsStoppedNotice: notice text")
    } else {
        expect(false, "testTurnCanceledAddsStoppedNotice: last row is a notice")
    }
}

func testTurnFailedShowsError() {
    let state = replay(loadFixture("failed"))
    expect(state.turn == .failed("turn_failed#x"), "testTurnFailedShowsError: turn")
    if case .error(_, let message)? = state.rows.last {
        expect(message == "turn_failed#x", "testTurnFailedShowsError: error row")
    } else {
        expect(false, "testTurnFailedShowsError: last row is an error")
    }
}

func testPermissionFlag() {
    let frames = loadFixture("permission")
    var state = TimelineState()
    apply(frames[0], to: &state)
    expect(!state.pendingPermission, "testPermissionFlag: initially false")
    apply(frames[1], to: &state)
    expect(state.pendingPermission, "testPermissionFlag: requested")
    apply(frames[2], to: &state)
    expect(!state.pendingPermission, "testPermissionFlag: resolved")
}

func testUnknownItemBecomesUnsupported() {
    let state = replay(loadFixture("unknown-item"))
    let rows = state.rows.filter { if case .unsupported = $0 { return true } else { return false } }
    expect(rows == [.unsupported(id: "s1090", type: "future_widget")],
           "testUnknownItemBecomesUnsupported: once per type per turn")
}

func testSnapshotIgnoresHiddenItems() {
    let state = snapshotOnly(loadFixture("stream-text-and-tools"))
    let unsupported = state.rows.filter { if case .unsupported = $0 { return true } else { return false } }
    expect(unsupported.isEmpty, "testSnapshotIgnoresHiddenItems: compaction is not shown")
    expect(state.hasSnapshot && state.turn == .running && state.lastSeq == 1089, "testSnapshotIgnoresHiddenItems: snapshot state")
}

func runTimelineReducerTests() {
    testChunksAppendIntoOneAssistantRow()
    testToolStatusUpdatesInPlace()
    testFailedToolKeepsError()
    testGapRequestsRefetch()
    testReplacementRequestsRefetch()
    testStreamFrameWithOtherEpochRequestsRefetch()
    testDuplicateSeqIgnored()
    testStreamBeforeSnapshotIsBuffered()
    testBufferIsCapped()
    testTurnCanceledAddsStoppedNotice()
    testTurnFailedShowsError()
    testPermissionFlag()
    testUnknownItemBecomesUnsupported()
    testSnapshotIgnoresHiddenItems()
}
