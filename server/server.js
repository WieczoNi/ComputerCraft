// ccbridge relay: ComputerCraft agents connect here over WebSocket; browsers and
// Claude Code (via the REST API / MCP server) talk to them through it.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { timingSafeEqual, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { WebSocketServer } from "ws";
import { toLua, statusCode as statusLua } from "./lua.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const AGENT_PATH = path.join(here, "..", "lua", "agent.lua");
const PUBLIC_DIR = path.join(here, "public");

const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || "127.0.0.1";
const PUBLIC_URL = (process.env.PUBLIC_URL || `http://localhost:${PORT}`).replace(/\/+$/, "");
const AGENT_TOKEN = process.env.AGENT_TOKEN;
const API_TOKEN = process.env.API_TOKEN;

if (!AGENT_TOKEN || !API_TOKEN) {
  console.error("AGENT_TOKEN and API_TOKEN must be set");
  process.exit(1);
}

const TURTLE_ACTIONS = new Set([
  "forward", "back", "up", "down", "turnLeft", "turnRight",
  "dig", "digUp", "digDown", "place", "placeUp", "placeDown",
  "attack", "attackUp", "attackDown", "suck", "suckUp", "suckDown",
  "drop", "dropUp", "dropDown", "select", "refuel", "transferTo",
  "detect", "detectUp", "detectDown", "inspect", "inspectUp", "inspectDown",
  "compare", "compareUp", "compareDown", "compareTo", "equipLeft", "equipRight",
  "getItemDetail", "getItemCount", "getItemSpace", "getFuelLevel", "getFuelLimit",
  "getSelectedSlot", "craft",
]);

function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const ba = Buffer.from(a), bb = Buffer.from(b);
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

// CC strings are bytes; escape everything non-ASCII so the agent's JSON parser
// gets plain \u00XX escapes instead of raw UTF-8.
function encodeForAgent(obj) {
  return JSON.stringify(obj).replace(/[\u0080-￿]/g, (c) =>
    "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
}

// ---------------------------------------------------------------------------
// Computer registry
// ---------------------------------------------------------------------------

/** id -> { info, ws, screen, online, lastSeen, pending: Map<reqId, {resolve, timer}> } */
const computers = new Map();
const uiClients = new Set();

function summary(c) {
  return { ...c.info, online: c.online, lastSeen: c.lastSeen };
}

function broadcastUi(msg) {
  const data = JSON.stringify(msg);
  for (const ui of uiClients) if (ui.readyState === 1) ui.send(data);
}

function broadcastComputers() {
  broadcastUi({ type: "computers", computers: [...computers.values()].map(summary) });
}

function getComputer(id) {
  const c = computers.get(Number(id));
  if (!c) throw httpError(404, `unknown computer ${id}`);
  if (!c.online) throw httpError(409, `computer ${id} is offline`);
  return c;
}

/** Send an op to a computer and wait for its result message. */
function call(c, op, args = {}, timeoutMs = 15000) {
  const reqId = randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      c.pending.delete(reqId);
      if (op === "eval") c.ws?.send(encodeForAgent({ op: "cancel", target: reqId }));
      reject(httpError(504, `timed out after ${timeoutMs}ms waiting for computer ${c.info.id}`));
    }, timeoutMs);
    c.pending.set(reqId, { resolve, reject, timer });
    c.ws.send(encodeForAgent({ ...args, op, reqId }));
  });
}

function screenText(screen) {
  if (!screen) return "";
  return screen.lines.map((l) => l.replace(/\s+$/, "")).join("\n");
}

const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20 });

function handleAgent(ws) {
  let c = null;
  ws.isAlive = true;
  ws.on("pong", () => { ws.isAlive = true; });

  ws.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    if (!c) {
      if (msg.type !== "hello" || !safeEqual(msg.token, AGENT_TOKEN)) {
        ws.send(encodeForAgent({ type: "error", message: "authentication failed" }));
        ws.close(4001, "auth");
        return;
      }
      const id = Number(msg.id);
      const existing = computers.get(id);
      if (existing?.ws && existing.ws !== ws) existing.ws.close(4000, "replaced");
      c = existing || { pending: new Map() };
      c.ws = ws;
      c.online = true;
      c.lastSeen = Date.now();
      c.info = {
        id,
        label: msg.label ?? null,
        turtle: !!msg.turtle,
        pocket: !!msg.pocket,
        advanced: !!msg.advanced,
        version: msg.version,
        width: msg.width,
        height: msg.height,
      };
      computers.set(id, c);
      console.log(`agent ${id} (${c.info.label ?? "unlabelled"}) connected`);
      broadcastComputers();
      return;
    }

    c.lastSeen = Date.now();
    if (msg.type === "screen") {
      c.screen = msg.screen;
      broadcastUi({ type: "screen", id: c.info.id, screen: msg.screen });
    } else if (msg.type === "result") {
      const p = c.pending.get(msg.reqId);
      if (p) {
        clearTimeout(p.timer);
        c.pending.delete(msg.reqId);
        p.resolve({
          ok: !!msg.ok,
          values: Array.isArray(msg.values) ? msg.values : [],
          output: Array.isArray(msg.output) ? msg.output : [],
          error: msg.error ?? null,
        });
      }
    }
  });

  ws.on("close", () => {
    if (!c || c.ws !== ws) return;
    c.online = false;
    c.ws = null;
    for (const [, p] of c.pending) {
      clearTimeout(p.timer);
      p.reject(httpError(503, `computer ${c.info.id} disconnected`));
    }
    c.pending.clear();
    console.log(`agent ${c.info.id} disconnected`);
    broadcastComputers();
  });
}

function handleUi(ws) {
  uiClients.add(ws);
  ws.isAlive = true;
  ws.on("pong", () => { ws.isAlive = true; });
  ws.send(JSON.stringify({ type: "computers", computers: [...computers.values()].map(summary) }));
  for (const c of computers.values()) {
    if (c.screen) ws.send(JSON.stringify({ type: "screen", id: c.info.id, screen: c.screen }));
  }
  ws.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    const c = computers.get(Number(msg.id));
    if (!c?.online) return;
    if (msg.type === "input" && Array.isArray(msg.events)) {
      c.ws.send(encodeForAgent({ op: "input", events: msg.events }));
    }
  });
  ws.on("close", () => uiClients.delete(ws));
}

// Detect dead connections (CC answers pings automatically).
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 30000).unref();

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function httpError(status, message) {
  const e = new Error(message);
  e.status = status;
  return e;
}

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 1 << 20) throw httpError(413, "body too large");
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString()); } catch { throw httpError(400, "invalid JSON"); }
}

function bearer(req) {
  const h = req.headers.authorization || "";
  return h.startsWith("Bearer ") ? h.slice(7) : null;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

/** Send input events, then wait until the screen has been quiet for a moment. */
async function inputAndSettle(c, events, waitMs) {
  c.ws.send(encodeForAgent({ op: "input", events }));
  const deadline = Date.now() + waitMs;
  let last = JSON.stringify(c.screen), quietSince = Date.now();
  await delay(150);
  while (Date.now() < deadline) {
    const now = JSON.stringify(c.screen);
    if (now !== last) { last = now; quietSince = Date.now(); }
    else if (Date.now() - quietSince >= 500) break;
    await delay(100);
  }
  return { screen: screenText(c.screen), cursor: c.screen?.cursor ?? null };
}

const STATIC = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/index.html": ["index.html", "text/html; charset=utf-8"],
};

async function route(req, res) {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;

  if (req.method === "GET" && p === "/agent.lua") {
    const src = await readFile(AGENT_PATH, "utf8");
    res.writeHead(200, { "content-type": "text/x-lua; charset=utf-8" });
    res.end(src.replaceAll("__CCBRIDGE_URL__", PUBLIC_URL));
    return;
  }
  if (req.method === "GET" && STATIC[p]) {
    const [file, type] = STATIC[p];
    res.writeHead(200, { "content-type": type });
    res.end(await readFile(path.join(PUBLIC_DIR, file)));
    return;
  }
  if (!p.startsWith("/api/")) throw httpError(404, "not found");
  if (!safeEqual(bearer(req), API_TOKEN)) throw httpError(401, "unauthorized");

  if (req.method === "GET" && p === "/api/computers") {
    return json(res, 200, [...computers.values()].map(summary));
  }

  const m = p.match(/^\/api\/computers\/(\d+)\/([a-z]+)$/);
  if (!m) throw httpError(404, "not found");
  const [, id, action] = m;

  if (req.method === "GET" && action === "screen") {
    const c = computers.get(Number(id));
    if (!c) throw httpError(404, `unknown computer ${id}`);
    if (url.searchParams.get("format") === "raw") return json(res, 200, c.screen ?? null);
    return json(res, 200, { online: c.online, screen: screenText(c.screen), cursor: c.screen?.cursor ?? null });
  }

  if (req.method !== "POST") throw httpError(405, "method not allowed");
  const body = await readBody(req);
  const c = getComputer(id);
  const timeout = Math.min(Number(body.timeout) || 15000, 300000);

  switch (action) {
    case "eval": {
      if (typeof body.code !== "string") throw httpError(400, "code must be a string");
      return json(res, 200, await call(c, "eval", { code: body.code }, timeout));
    }
    case "turtle": {
      if (!c.info.turtle) throw httpError(400, `computer ${id} is not a turtle`);
      if (!TURTLE_ACTIONS.has(body.action)) throw httpError(400, `unsupported turtle action: ${body.action}`);
      const args = Array.isArray(body.args) ? body.args.map(toLua).join(", ") : "";
      return json(res, 200, await call(c, "eval", { code: `return turtle.${body.action}(${args})` }, timeout));
    }
    case "status": {
      return json(res, 200, await call(c, "eval", { code: statusLua }, timeout));
    }
    case "input": {
      const events = [];
      if (Array.isArray(body.events)) events.push(...body.events);
      if (typeof body.text === "string") events.push(["paste", body.text]);
      if (body.enter) events.push(["key", "enter"]);
      return json(res, 200, await inputAndSettle(c, events, Math.min(timeout, 10000)));
    }
    case "run": {
      if (typeof body.command !== "string") throw httpError(400, "command must be a string");
      const wait = Math.min(Number(body.wait) || 3000, 60000);
      return json(res, 200, await inputAndSettle(c, [["paste", body.command], ["key", "enter"]], wait));
    }
    case "terminate": {
      return json(res, 200, await inputAndSettle(c, [["terminate"]], 2000));
    }
    case "reboot":
    case "update": {
      return json(res, 200, await call(c, action, {}, timeout));
    }
  }
  throw httpError(404, "not found");
}

const server = createServer((req, res) => {
  route(req, res).catch((e) => {
    if (res.headersSent) return res.end();
    json(res, e.status || 500, { error: e.message });
    if (!e.status) console.error(e);
  });
});

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/ws/agent") {
    wss.handleUpgrade(req, socket, head, handleAgent);
  } else if (url.pathname === "/ws/ui" && safeEqual(url.searchParams.get("token"), API_TOKEN)) {
    wss.handleUpgrade(req, socket, head, handleUi);
  } else {
    socket.destroy();
  }
});

server.listen(PORT, HOST, () => {
  console.log(`ccbridge relay listening on http://${HOST}:${PORT} (public URL ${PUBLIC_URL})`);
});
