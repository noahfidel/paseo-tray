#!/usr/bin/env python3
"""Derive the edited-copy fixtures from the recorded Fixtures/stream-text-and-tools.jsonl.

stream-text-and-tools.jsonl itself is recorded (test/record-timeline.mjs) and
scrubbed; everything written here is that file's lines with a field edited
(a seq skipped, an epoch swapped, an event type changed), never invented shapes.
Run: python3 -I Tests/derive-fixtures.py   (from tray/)
"""
import copy, json, os

d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Fixtures")
rec = [json.loads(l) for l in open(os.path.join(d, "stream-text-and-tools.jsonl"))]
snap, frames, done = rec[0], rec[1:-1], rec[-1]  # frames: seq 1090..1095
by_seq = {f["payload"]["seq"]: f for f in frames}

def write(name, lines):
    with open(os.path.join(d, name), "w") as fh:
        for o in lines:
            fh.write(json.dumps(o, separators=(",", ":")) + "\n")

def snapshot_through(seq, extra_entries):
    s = copy.deepcopy(snap)
    p = s["payload"]
    p["entries"] += extra_entries
    p["endCursor"]["seq"] = seq
    p["window"].update(maxSeq=seq, nextSeq=seq + 1)
    return s

assistant_merged = {"item": {"type": "assistant_message",
                             "text": "assistant_message#1090assistant_message#1091"},
                    "turnId": "turn-1", "seqStart": 1090, "seqEnd": 1091,
                    "timestamp": by_seq[1091]["payload"]["timestamp"]}
tool_running = {"item": {"type": "tool_call", "callId": "call-15", "name": "Bash",
                         "status": "running", "error": None},
                "turnId": "turn-1", "seqStart": 1092, "seqEnd": 1094,
                "timestamp": by_seq[1094]["payload"]["timestamp"]}

# gap: seq 1092 never arrives; refetch snapshot (through 1094) follows.
write("gap.jsonl", [snap, by_seq[1090], by_seq[1091], by_seq[1093], by_seq[1094],
                    snapshot_through(1094, [assistant_merged, tool_running])])

# replacement: epoch changes under us, then a snapshot on the new epoch.
new_epoch = "00000000-0000-0000-0000-00000000e2"
repl = {"type": "agent.timeline.replacement",
        "payload": {"agentId": "agent", "epoch": new_epoch}}
snap2 = copy.deepcopy(snap)
snap2["payload"]["epoch"] = new_epoch
snap2["payload"]["startCursor"]["epoch"] = new_epoch
snap2["payload"]["endCursor"]["epoch"] = new_epoch
write("replacement.jsonl", [snap, by_seq[1090], repl, snap2])

# stream frames first, snapshot (through 1090) afterwards.
write("stream-before-snapshot.jsonl",
      [by_seq[1090], by_seq[1091],
       snapshot_through(1090, [{**assistant_merged,
                                "item": {"type": "assistant_message", "text": "assistant_message#1090"},
                                "seqEnd": 1090}])])

def event_frame(event_type, **fields):
    f = copy.deepcopy(done)
    f["payload"]["event"] = {"type": event_type, "provider": "p", "turnId": "turn-1", **fields}
    return f

write("canceled.jsonl", [snap, by_seq[1090], event_frame("turn_canceled", reason="turn_canceled#x")])
write("failed.jsonl", [snap, by_seq[1090], event_frame("turn_failed", error="turn_failed#x")])
write("permission.jsonl", [snap, event_frame("permission_requested", request={"id": "perm-1"}),
                           event_frame("permission_resolved", requestId="perm-1")])

unk = copy.deepcopy(by_seq[1090])
unk["payload"]["event"]["item"] = {"type": "future_widget"}
unk2 = copy.deepcopy(unk)
unk2["payload"]["seq"] = 1091
write("unknown-item.jsonl", [snap, unk, unk2])
