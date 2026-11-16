#!/usr/bin/env python3
"""Derive Fixtures/dispatchers-updates.jsonl from the recorded Fixtures/dispatchers-snapshot.json.

dispatchers-snapshot.json is a recorded fetch_agents_response (scripts outside the repo:
hello + fetch_agents_request with filter.labels {"flowly-dispatcher": "1"}, includeBackground,
no subscribe), then trimmed to the fields the tray reads (id, title, status, labels, archivedAt,
internal, createdAt, updatedAt, pendingPermissions, requiresAttention, attentionReason; project
keeps projectKey/projectName/workspaceName) so no system prompts or local paths ship. Values are
exactly as recorded. Every line written here is an agent_update payload built from that snapshot's
agents with a field edited (pendingPermissions, status, id/createdAt), never an invented shape.
The pendingPermissions entry shape is hand-written: no recorded dispatcher had one pending.
Lines, in order (the tests rely on it):
  1 Tooling gains a pending AskUserQuestion permission   2 it resolves ([])
  3 Tooling goes closed                                   4 a newer Tooling dispatcher appears
  5 that newer one is removed
Run: python3 -I Tests/derive-dispatcher-fixtures.py   (from tray/)
"""
import copy, json, os

d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Fixtures")
snap = json.load(open(os.path.join(d, "dispatchers-snapshot.json")))
tooling = next(e for e in snap["payload"]["entries"]
               if e["agent"]["title"].endswith("Tooling") and e["agent"]["status"] != "closed")
sub = "sub-dispatchers"

def upsert(agent):
    return {"kind": "upsert", "agent": agent, "project": tooling.get("project"), "subscriptionId": sub}

def edit(**changes):
    a = copy.deepcopy(tooling["agent"])
    a.update(changes)
    return a

perm = [{"requestId": "perm-1", "kind": "tool", "name": "AskUserQuestion"}]
newer = edit(id="aaaaaaaa-0000-4000-8000-000000000001",
             createdAt="2026-11-16T20:00:00.000Z", updatedAt="2026-11-16T20:00:00.000Z")
lines = [
    upsert(edit(pendingPermissions=perm, status="running")),
    upsert(edit(pendingPermissions=[])),
    upsert(edit(status="closed")),
    upsert(newer),
    {"kind": "remove", "agentId": newer["id"], "subscriptionId": sub},
]
with open(os.path.join(d, "dispatchers-updates.jsonl"), "w") as fh:
    for o in lines:
        fh.write(json.dumps(o, separators=(",", ":")) + "\n")
