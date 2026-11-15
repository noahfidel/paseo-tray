#!/usr/bin/env node
// Record a scrubbed agent timeline for the PaseoTray reducer tests.
//
//   node --experimental-websocket test/record-timeline.mjs <agentId> <seconds> <out.jsonl>
//
// Uses Node's built-in WebSocket (Node 20 needs --experimental-websocket; no
// `ws` install required). Read-only: sends hello, one tail fetch and one
// timeline subscription, never messages/cancels/approves. Each received
// fetch_agent_timeline_response / agent_stream / agent.timeline.replacement
// frame for the agent is scrubbed to a whitelist (text/message/error become
// "<type>#<seq>" placeholders, chunk boundaries kept) and written as one JSON
// line. The credential is never written.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const [agentId, secondsArg, outPath] = process.argv.slice(2);
if (!agentId || !secondsArg || !outPath) {
  console.error("usage: node --experimental-websocket test/record-timeline.mjs <agentId> <seconds> <out.jsonl>");
  process.exit(2);
}
const home = process.env.PASEO_HOME || path.join(os.homedir(), ".paseo");
const readJSON = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
const pid = readJSON(path.join(home, "paseo.pid"));
const cfg = readJSON(path.join(home, "config.json"));
const listen = (pid?.listen || cfg?.daemon?.listen || "").trim();
if (!/^[^/\s]+:\d+$/.test(listen)) { console.error("no usable daemon listen address"); process.exit(1); }
let token = null;
try { token = fs.readFileSync(path.join(home, "local-credential"), "utf8").trim() || null; } catch {}

const clientId = `record-timeline-${crypto.randomUUID().slice(0, 8)}`;
const ws = new WebSocket(`ws://${listen}/ws`);
const lines = [];
const callIds = new Map();
const turnIds = new Map();
const alias = (map, prefix, v) => {
  if (v == null) return v;
  if (!map.has(v)) map.set(v, `${prefix}-${map.size + 1}`);
  return map.get(v);
};
const send = (m) => ws.send(JSON.stringify({ type: "session", message: m }));

const SAFE_TOOLS = new Set(["Bash", "Read", "Edit", "Write", "Grep", "Glob"]);
function scrubItem(item, seq) {
  if (!item || typeof item !== "object") return item;
  const t = item.type;
  const ph = `${t}#${seq ?? "x"}`;
  switch (t) {
    case "user_message": case "assistant_message": case "reasoning":
      return { type: t, text: ph };
    case "tool_call":
      return { type: t, callId: alias(callIds, "call", item.callId), name: SAFE_TOOLS.has(item.name) ? item.name : "tool",
               status: item.status, error: item.error == null ? null : ph };
    case "error": return { type: t, message: ph };
    case "notification": return { type: t, message: ph };
    default: return { type: t };
  }
}
function scrubEvent(ev, seq) {
  const t = ev?.type;
  const out = { type: t, provider: "p" };
  if (ev.turnId != null) out.turnId = alias(turnIds, "turn", ev.turnId);
  if (t === "turn_failed") out.error = `turn_failed#${seq ?? "x"}`;
  if (t === "turn_canceled") out.reason = `turn_canceled#${seq ?? "x"}`;
  if (t === "timeline") out.item = scrubItem(ev.item, seq);
  if (t === "permission_requested") out.request = { id: "perm-1" };
  if (t === "permission_resolved") out.requestId = "perm-1";
  return out;
}
function scrubFetch(p) {
  const agent = p.agent
    ? { status: p.agent.status, pendingPermissions: (p.agent.pendingPermissions || []).map(() => ({ id: "perm-1" })) }
    : null;
  return {
    requestId: "r", agentId: "agent", agent,
    direction: p.direction, projection: p.projection, epoch: p.epoch,
    reset: p.reset, staleCursor: p.staleCursor, gap: p.gap, window: p.window,
    startCursor: p.startCursor, endCursor: p.endCursor, hasOlder: p.hasOlder, hasNewer: p.hasNewer,
    entries: (p.entries || []).map((e) => ({
      item: scrubItem(e.item, e.seqStart), turnId: alias(turnIds, "turn", e.turnId),
      seqStart: e.seqStart, seqEnd: e.seqEnd, timestamp: e.timestamp,
    })),
    error: p.error ? "error" : null,
  };
}
function record(m) {
  const p = m?.payload;
  if (!p || p.agentId !== agentId) return;
  let out;
  if (m.type === "fetch_agent_timeline_response") out = { type: m.type, payload: scrubFetch(p) };
  else if (m.type === "agent_stream") {
    out = { type: m.type, payload: { agentId: "agent", event: scrubEvent(p.event, p.seq), timestamp: p.timestamp, seq: p.seq, epoch: p.epoch } };
  } else if (m.type === "agent.timeline.replacement") out = { type: m.type, payload: { agentId: "agent", epoch: p.epoch } };
  else return;
  lines.push(JSON.stringify(out));
}

let started = false;
function start() {
  if (started) return; started = true;
  send({ type: "fetch_agent_timeline_request", agentId, requestId: "rec-fetch", direction: "tail", limit: 20, projection: "projected" });
  send({ type: "agent.timeline.set_subscription.request", agentIds: [agentId], requestId: "rec-sub" });
  setTimeout(finish, Number(secondsArg) * 1000);
}
function finish() {
  fs.writeFileSync(outPath, lines.join("\n") + (lines.length ? "\n" : ""));
  console.log(`wrote ${lines.length} frames to ${outPath}`);
  try { ws.close(); } catch {}
  process.exit(0);
}
ws.addEventListener("open", () => {
  const hello = { type: "hello", clientId, clientType: "cli", protocolVersion: 1, appVersion: "0.1.0",
    capabilities: { owned_subscriptions: true, explicit_event_subscriptions: true, hello_rejection: true, all_providers: true } };
  if (token) hello.auth = { kind: "localCredential", token };
  ws.send(JSON.stringify(hello));
  setTimeout(start, 1500);
});
ws.addEventListener("message", (ev) => {
  let o; try { o = JSON.parse(String(ev.data)); } catch { return; }
  if (o.type === "session") { start(); record(o.message); }
});
ws.addEventListener("error", () => { console.error("websocket error"); process.exit(1); });
