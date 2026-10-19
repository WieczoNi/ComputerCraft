#!/usr/bin/env node
// Minimal MCP (stdio) server exposing the ccbridge REST API as tools for Claude Code.
// Register with:
//   claude mcp add ccbridge -e CCBRIDGE_URL=https://nucnec.de/cc -e CCBRIDGE_TOKEN=... -- node /path/to/server/mcp.js

import { createInterface } from "node:readline";

const BASE = (process.env.CCBRIDGE_URL || "http://127.0.0.1:8080").replace(/\/+$/, "");
const TOKEN = process.env.CCBRIDGE_TOKEN || process.env.API_TOKEN;

async function api(method, path, body) {
  const res = await fetch(`${BASE}/api/${path}`, {
    method,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = text; }
  if (!res.ok) throw new Error(data?.error || `${res.status} ${res.statusText}`);
  return data;
}

const id = { type: "integer", description: "Computer ID (from list_computers)" };
const timeout = { type: "integer", description: "Timeout in milliseconds (default 15000, max 300000)" };

function formatScreen(r) {
  const cur = r.cursor ? `\n[cursor at ${r.cursor.x},${r.cursor.y}]` : "";
  return "```\n" + r.screen + "\n```" + cur;
}

function formatEval(r) {
  const parts = [];
  if (r.output?.length) parts.push("output:\n" + r.output.join("\n"));
  if (r.ok) parts.push("returned: " + JSON.stringify(r.values));
  else parts.push("error: " + r.error);
  return parts.join("\n");
}

const tools = [
  {
    name: "list_computers",
    description: "List ComputerCraft computers and turtles known to the relay, with online status.",
    inputSchema: { type: "object", properties: {} },
    run: async () => JSON.stringify(await api("GET", "computers"), null, 2),
  },
  {
    name: "get_screen",
    description: "Read the current terminal screen of a computer as text.",
    inputSchema: { type: "object", properties: { id }, required: ["id"] },
    run: async (a) => formatScreen(await api("GET", `computers/${a.id}/screen`)),
  },
  {
    name: "run_command",
    description: "Type a shell command into the computer's terminal, press Enter, and return the screen once output settles. " +
      "Use for CraftOS programs (ls, edit is interactive, wget, pastebin, programs on disk). The command runs visibly in the in-game shell.",
    inputSchema: {
      type: "object",
      properties: { id, command: { type: "string" }, wait: { type: "integer", description: "Max ms to wait for output to settle (default 3000)" } },
      required: ["id", "command"],
    },
    run: async (a) => formatScreen(await api("POST", `computers/${a.id}/run`, { command: a.command, wait: a.wait })),
  },
  {
    name: "send_input",
    description: "Send raw input to the terminal: text (pasted), optional Enter, and/or key events like [\"key\",\"up\"], " +
      "[\"key\",\"leftCtrl\"], [\"char\",\"y\"], [\"terminate\"]. Key names are CC `keys` names. Returns the screen afterwards.",
    inputSchema: {
      type: "object",
      properties: {
        id,
        text: { type: "string" },
        enter: { type: "boolean" },
        events: { type: "array", items: { type: "array" } },
      },
      required: ["id"],
    },
    run: async (a) => formatScreen(await api("POST", `computers/${a.id}/input`, { text: a.text, enter: a.enter, events: a.events })),
  },
  {
    name: "eval_lua",
    description: "Run Lua code on the computer in the background (not in the visible shell) and return its results. " +
      "Expressions are returned automatically; print() output is captured. Full CC APIs available (turtle, fs, peripheral, http, gps, ...).",
    inputSchema: { type: "object", properties: { id, code: { type: "string" }, timeout }, required: ["id", "code"] },
    run: async (a) => formatEval(await api("POST", `computers/${a.id}/eval`, { code: a.code, timeout: a.timeout })),
  },
  {
    name: "turtle_action",
    description: "Run a single turtle API function, e.g. forward, back, up, down, turnLeft, turnRight, dig, digUp, digDown, " +
      "place, select (args [slot]), refuel, inspect, suck, drop, transferTo. Returns the function's return values.",
    inputSchema: {
      type: "object",
      properties: { id, action: { type: "string" }, args: { type: "array" }, timeout },
      required: ["id", "action"],
    },
    run: async (a) => formatEval(await api("POST", `computers/${a.id}/turtle`, { action: a.action, args: a.args, timeout: a.timeout })),
  },
  {
    name: "get_status",
    description: "Get a computer's status: label, and for turtles fuel, selected slot, inventory and the blocks in front/up/down; " +
      "GPS position if a wireless modem and GPS network are available.",
    inputSchema: { type: "object", properties: { id }, required: ["id"] },
    run: async (a) => formatEval(await api("POST", `computers/${a.id}/status`, {})),
  },
  {
    name: "terminate",
    description: "Send Ctrl+T (terminate) to stop the program currently running in the terminal.",
    inputSchema: { type: "object", properties: { id }, required: ["id"] },
    run: async (a) => formatScreen(await api("POST", `computers/${a.id}/terminate`, {})),
  },
  {
    name: "reboot",
    description: "Reboot the computer. The agent reconnects automatically after a few seconds.",
    inputSchema: { type: "object", properties: { id }, required: ["id"] },
    run: async (a) => JSON.stringify(await api("POST", `computers/${a.id}/reboot`, {})),
  },
  {
    name: "update_agent",
    description: "Make the computer re-download the latest agent.lua from the relay and reboot.",
    inputSchema: { type: "object", properties: { id }, required: ["id"] },
    run: async (a) => JSON.stringify(await api("POST", `computers/${a.id}/update`, {})),
  },
];

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function replyError(id, code, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

async function handle(msg) {
  const { id, method, params } = msg;
  if (id === undefined) return; // notification
  switch (method) {
    case "initialize":
      return reply(id, {
        protocolVersion: params?.protocolVersion || "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "ccbridge", version: "0.1.0" },
      });
    case "ping":
      return reply(id, {});
    case "tools/list":
      return reply(id, { tools: tools.map(({ run, ...t }) => t) });
    case "tools/call": {
      const tool = tools.find((t) => t.name === params?.name);
      if (!tool) return replyError(id, -32602, `unknown tool: ${params?.name}`);
      try {
        const text = await tool.run(params.arguments || {});
        return reply(id, { content: [{ type: "text", text }] });
      } catch (e) {
        return reply(id, { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true });
      }
    }
    default:
      return replyError(id, -32601, `method not found: ${method}`);
  }
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return replyError(null, -32700, "parse error"); }
  handle(msg).catch((e) => replyError(msg.id ?? null, -32603, e.message));
});
