// End-to-end test: start the relay, connect a fake agent, drive it via the REST API and the MCP server.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import WebSocket from "ws";

const dir = path.dirname(fileURLToPath(import.meta.url));
const PORT = 18000 + Math.floor(Math.random() * 1000);
const BASE = `http://127.0.0.1:${PORT}`;
const env = { ...process.env, PORT: String(PORT), AGENT_TOKEN: "agent-secret", API_TOKEN: "api-secret", PUBLIC_URL: "https://example.test/cc" };

let relay, agent;
const received = [];

function screen(lines) {
  return { width: 10, height: lines.length, lines, fg: lines.map(() => "0".repeat(10)), bg: lines.map(() => "f".repeat(10)), cursor: { x: 1, y: 1, blink: true } };
}

const api = (method, p, body, token = "api-secret") =>
  fetch(`${BASE}/api/${p}`, { method, headers: { authorization: `Bearer ${token}` }, body: body && JSON.stringify(body) });

before(async () => {
  relay = spawn(process.execPath, [path.join(dir, "..", "server.js")], { env, stdio: ["ignore", "pipe", "inherit"] });
  await new Promise((r) => relay.stdout.once("data", r));

  agent = new WebSocket(`ws://127.0.0.1:${PORT}/ws/agent`);
  await new Promise((r) => agent.once("open", r));
  agent.send(JSON.stringify({ type: "hello", token: "agent-secret", id: 7, label: "Digger", turtle: true, width: 10, height: 2 }));
  agent.send(JSON.stringify({ type: "screen", screen: screen(["> ", ""]) }));
  agent.on("message", (raw) => {
    const msg = JSON.parse(raw);
    received.push(msg);
    if (msg.op === "eval") {
      agent.send(JSON.stringify({ type: "result", reqId: msg.reqId, ok: true, values: [msg.code], output: ["hi"] }));
    } else if (msg.op === "input") {
      const typed = msg.events.filter((e) => e[0] === "paste").map((e) => e[1]).join("");
      agent.send(JSON.stringify({ type: "screen", screen: screen(["> " + typed, "done"]) }));
    }
  });
  await new Promise((r) => setTimeout(r, 100));
});

after(() => {
  agent?.close();
  relay?.kill();
});

test("serves agent.lua with the public URL substituted", async () => {
  const body = await (await fetch(`${BASE}/agent.lua`)).text();
  assert.match(body, /local BASE_URL = "https:\/\/example\.test\/cc"/);
});

test("rejects bad API tokens", async () => {
  assert.equal((await api("GET", "computers", undefined, "nope")).status, 401);
});

test("rejects agents with a bad token", async () => {
  const bad = new WebSocket(`ws://127.0.0.1:${PORT}/ws/agent`);
  await new Promise((r) => bad.once("open", r));
  bad.send(JSON.stringify({ type: "hello", token: "wrong", id: 99 }));
  const code = await new Promise((r) => bad.once("close", r));
  assert.equal(code, 4001);
  const list = await (await api("GET", "computers")).json();
  assert.ok(!list.some((c) => c.id === 99));
});

test("lists computers and reads the screen", async () => {
  const list = await (await api("GET", "computers")).json();
  assert.deepEqual(list.map((c) => [c.id, c.label, c.turtle, c.online]), [[7, "Digger", true, true]]);
  const s = await (await api("GET", "computers/7/screen")).json();
  assert.equal(s.screen, ">\n");
});

test("turtle actions become Lua and return results", async () => {
  const r = await (await api("POST", "computers/7/turtle", { action: "select", args: [3] })).json();
  assert.deepEqual(r, { ok: true, values: ["return turtle.select(3)"], output: ["hi"], error: null });
  assert.equal((await api("POST", "computers/7/turtle", { action: "os.reboot" })).status, 400);
});

test("run types the command and returns the settled screen", async () => {
  const r = await (await api("POST", "computers/7/run", { command: "ls", wait: 2000 })).json();
  assert.equal(r.screen, "> ls\ndone");
  const input = received.findLast((m) => m.op === "input");
  assert.deepEqual(input.events, [["paste", "ls"], ["key", "enter"]]);
});

test("non-ASCII is escaped for the agent", async () => {
  await api("POST", "computers/7/eval", { code: "print('é')" });
  assert.ok(received.some((m) => m.code === "print('é')"));
});

test("MCP server lists tools and calls the API", async () => {
  const mcp = spawn(process.execPath, [path.join(dir, "..", "mcp.js")], {
    env: { ...process.env, CCBRIDGE_URL: BASE, CCBRIDGE_TOKEN: "api-secret" },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const responses = [];
  let buf = "";
  mcp.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) { responses.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); }
  });
  const send = (m) => mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
  const waitFor = async (id) => {
    for (let t = 0; t < 100; t++) {
      const r = responses.find((x) => x.id === id);
      if (r) return r;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error(`no response for ${id}`);
  };

  send({ id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
  assert.equal((await waitFor(1)).result.serverInfo.name, "ccbridge");
  send({ method: "notifications/initialized" });
  send({ id: 2, method: "tools/list" });
  const names = (await waitFor(2)).result.tools.map((t) => t.name);
  assert.ok(names.includes("turtle_action") && names.includes("get_screen"));
  send({ id: 3, method: "tools/call", params: { name: "turtle_action", arguments: { id: 7, action: "forward" } } });
  assert.match((await waitFor(3)).result.content[0].text, /returned: \["return turtle.forward\(\)"\]/);
  send({ id: 4, method: "tools/call", params: { name: "get_screen", arguments: { id: 42 } } });
  assert.equal((await waitFor(4)).result.isError, true);
  mcp.kill();
});
