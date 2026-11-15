import Foundation

/// One rendered line of a bot chat transcript.
enum ChatRow: Equatable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)          // markdown source
    case tool(callId: String, name: String, status: String, error: String?)
    case error(id: String, message: String)
    case notice(id: String, text: String)              // turn canceled, notifications
    case unsupported(id: String, type: String)
}

enum TurnState: Equatable { case idle, running, failed(String), canceled }

struct TimelineState: Equatable {
    var rows: [ChatRow] = []
    var turn: TurnState = .idle
    var epoch: String?
    var lastSeq: Int?
    var pendingPermission = false
    var needsRefetch = false
    var hasSnapshot = false
    /// Stream frames (serialized) waiting for a snapshot; replayed by `applySnapshot`.
    var buffered: [Data] = []
    /// Item types already reported as `.unsupported` in the current turn.
    var unsupportedSeen: Set<String> = []
    /// True while the last assistant row may still receive chunks.
    var assistantOpen = false
    /// Monotonic counter for ids of rows from seq-less events (unique across snapshot rebuilds).
    var nextEventId = 0
}

/// Pure state machine over the daemon's timeline messages. Foundation only.
enum TimelineReducer {
    static let maxBufferedFrames = 500

    // MARK: Snapshot (fetch_agent_timeline_response.payload)

    static func applySnapshot(_ s: inout TimelineState, payload: [String: Any]) {
        if let error = payload["error"] as? String, !error.isEmpty { return }

        var rows: [ChatRow] = []
        var seen = Set<String>()
        for entry in payload["entries"] as? [[String: Any]] ?? [] {
            guard let item = entry["item"] as? [String: Any] else { continue }
            let id = "s\(entry["seqStart"] as? Int ?? rows.count)"
            appendSnapshotItem(item, id: id, rows: &rows, unsupportedSeen: &seen)
        }

        let agent = payload["agent"] as? [String: Any]
        if let agent {
            s.turn = (agent["status"] as? String) == "running" ? .running : .idle
            s.pendingPermission = !((agent["pendingPermissions"] as? [Any]) ?? []).isEmpty
        }

        s.rows = rows
        s.unsupportedSeen = seen
        s.epoch = payload["epoch"] as? String
        s.lastSeq = (payload["endCursor"] as? [String: Any])?["seq"] as? Int
        s.hasSnapshot = true
        s.needsRefetch = false
        s.assistantOpen = s.turn == .running

        let pending = s.buffered
        s.buffered = []
        for data in pending {
            guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let frameEpoch = frame["epoch"] as? String, let epoch = s.epoch, frameEpoch != epoch { continue }
            // Seq-less frames (turn_*, permission_*) can't be ordered against the
            // snapshot, which already carries the turn and permission state.
            // Exception: a turn-ending frame while the snapshot still says running
            // would leave the panel stuck on "running", so apply its turn change.
            if frame["seq"] as? Int == nil {
                let type = (frame["event"] as? [String: Any])?["type"] as? String
                guard s.turn == .running,
                      let type, ["turn_completed", "turn_failed", "turn_canceled"].contains(type) else { continue }
            }
            applyStream(&s, payload: frame)
        }
    }

    // MARK: Live stream (agent_stream.payload)

    static func applyStream(_ s: inout TimelineState, payload: [String: Any]) {
        if !s.hasSnapshot || s.needsRefetch {
            buffer(&s, payload)
            return
        }
        if let frameEpoch = payload["epoch"] as? String, let epoch = s.epoch, frameEpoch != epoch {
            s.needsRefetch = true
            buffer(&s, payload)
            return
        }
        let seq = payload["seq"] as? Int
        if let seq, let last = s.lastSeq {
            if seq <= last { return }
            if seq > last + 1 {
                s.needsRefetch = true
                buffer(&s, payload)
                return
            }
        }
        if let seq { s.lastSeq = seq }
        guard let event = payload["event"] as? [String: Any], let type = event["type"] as? String else { return }

        switch type {
        case "turn_started":
            s.turn = .running
            s.assistantOpen = false
            s.unsupportedSeen = []
        case "turn_completed":
            s.turn = .idle
            s.assistantOpen = false
        case "turn_failed":
            let message = event["error"] as? String ?? L("Turn failed", "回合失败")
            s.turn = .failed(message)
            s.assistantOpen = false
            s.rows.append(.error(id: rowId(seq, &s), message: message))
        case "turn_canceled":
            s.turn = .canceled
            s.assistantOpen = false
            s.rows.append(.notice(id: rowId(seq, &s), text: L("Stopped", "已停止")))
        case "permission_requested":
            s.pendingPermission = true
        case "permission_resolved":
            s.pendingPermission = false
        case "timeline":
            if let item = event["item"] as? [String: Any] {
                applyStreamItem(&s, item: item, id: rowId(seq, &s))
            }
        default:
            break // thread_started, attention_required, …
        }
    }

    // MARK: Replacement (agent.timeline.replacement.payload)

    static func applyReplacement(_ s: inout TimelineState, payload: [String: Any]) {
        if let epoch = payload["epoch"] as? String, epoch != s.epoch {
            s.needsRefetch = true
        }
    }

    // MARK: Helpers

    private static func rowId(_ seq: Int?, _ s: inout TimelineState) -> String {
        if let seq { return "s\(seq)" }
        s.nextEventId += 1
        return "e\(s.nextEventId)"
    }

    private static func buffer(_ s: inout TimelineState, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        s.buffered.append(data)
        if s.buffered.count > maxBufferedFrames {
            s.buffered.removeFirst(s.buffered.count - maxBufferedFrames)
        }
    }

    private static func toolError(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }

    private static func toolRow(_ item: [String: Any]) -> ChatRow? {
        guard let callId = item["callId"] as? String else { return nil }
        let status = item["status"] as? String ?? "running"
        return .tool(callId: callId, name: item["name"] as? String ?? "tool", status: status,
                     error: toolError(item["error"]))
    }

    /// Projected snapshot entries are already merged: each one is its own row.
    private static func appendSnapshotItem(_ item: [String: Any], id: String, rows: inout [ChatRow],
                                           unsupportedSeen: inout Set<String>) {
        switch item["type"] as? String ?? "" {
        case "user_message":
            unsupportedSeen = []
            rows.append(.user(id: id, text: item["text"] as? String ?? ""))
        case "assistant_message":
            rows.append(.assistant(id: id, text: item["text"] as? String ?? ""))
        case "tool_call":
            guard let row = toolRow(item), case .tool(let callId, _, _, _) = row else { return }
            if let index = rows.firstIndex(where: { if case .tool(let c, _, _, _) = $0 { return c == callId } else { return false } }) {
                rows[index] = row
            } else {
                rows.append(row)
            }
        case "error":
            rows.append(.error(id: id, message: item["message"] as? String ?? ""))
        case "notification":
            if let text = item["message"] as? String, !text.isEmpty { rows.append(.notice(id: id, text: text)) }
        case "reasoning", "todo", "compaction":
            break
        case let other:
            if unsupportedSeen.insert(other).inserted { rows.append(.unsupported(id: id, type: other)) }
        }
    }

    /// Stream items: assistant text arrives as chunks to append.
    private static func applyStreamItem(_ s: inout TimelineState, item: [String: Any], id: String) {
        switch item["type"] as? String ?? "" {
        case "user_message":
            s.unsupportedSeen = []
            s.assistantOpen = false
            s.rows.append(.user(id: id, text: item["text"] as? String ?? ""))
        case "assistant_message":
            let chunk = item["text"] as? String ?? ""
            if s.assistantOpen, case .assistant(let rowId, let text)? = s.rows.last {
                s.rows[s.rows.count - 1] = .assistant(id: rowId, text: text + chunk)
            } else {
                s.rows.append(.assistant(id: id, text: chunk))
            }
            s.assistantOpen = true
        case "tool_call":
            guard let row = toolRow(item), case .tool(let callId, _, _, _) = row else { return }
            if let index = s.rows.firstIndex(where: { if case .tool(let c, _, _, _) = $0 { return c == callId } else { return false } }) {
                s.rows[index] = row
            } else {
                s.rows.append(row)
            }
        case "error":
            s.rows.append(.error(id: id, message: item["message"] as? String ?? ""))
        case "notification":
            if let text = item["message"] as? String, !text.isEmpty { s.rows.append(.notice(id: id, text: text)) }
        case "reasoning", "todo", "compaction":
            break
        case let other:
            if s.unsupportedSeen.insert(other).inserted { s.rows.append(.unsupported(id: id, type: other)) }
        }
    }
}
