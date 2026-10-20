# ccbridge

Remote access to ComputerCraft (CC: Tweaked) computers and turtles: from a browser, from scripts,
and from Claude Code via MCP. Works on servers where you have no disk access — the in-game computers
only make **outbound** WebSocket connections to your relay.

```
[CC computer / turtle] --wss--> [relay on nucnec.de/cc] <-- browser (web terminal)
     startup.lua (agent)              server/             <-- Claude Code (MCP: server/mcp.js)
```

## Components

| Path | What it is |
| --- | --- |
| `lua/agent.lua` | In-game agent. Runs the normal shell inside a mirrored window, streams the screen, accepts keyboard input, runs Lua jobs in the background, reconnects automatically. |
| `server/server.js` | Relay (Node ≥ 18, depends only on `ws`). Serves the agent, the web UI and a REST API. |
| `server/public/index.html` | Web terminal: live colour screen, keyboard input, turtle control pad, Lua console. |
| `server/mcp.js` | MCP server (stdio) so Claude Code can list computers, read screens, run commands, eval Lua and move turtles. |
| `deploy/` | systemd unit, nginx snippet, env template. |

## 0. Check the Minecraft server allows WebSockets

On any in-game computer:

```lua
lua> print(http.websocket("wss://echo.websocket.events"))
```

A table/handle means it works. An error like `Domain not permitted` or `Websockets disabled` means the
server config (`[http]` in `computercraft-server.toml`) blocks it — tell the admin, or we add an HTTP-polling fallback.

## 1. Deploy the relay on the VPS

```sh
sudo useradd --system --home /opt/ccbridge ccbridge
sudo git clone <this repo> /opt/ccbridge
cd /opt/ccbridge/server && sudo npm install --omit=dev
sudo cp ../deploy/env.example /opt/ccbridge/.env
sudo sed -i "s/^AGENT_TOKEN=$/AGENT_TOKEN=$(openssl rand -hex 24)/; s/^API_TOKEN=$/API_TOKEN=$(openssl rand -hex 24)/" /opt/ccbridge/.env
sudo cat /opt/ccbridge/.env    # note both tokens; check PUBLIC_URL
sudo chown -R ccbridge /opt/ccbridge && sudo chmod 600 /opt/ccbridge/.env
sudo cp ../deploy/ccbridge.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ccbridge
```

Add `deploy/nginx-ccbridge.conf` to the nginx `server` block for nucnec.de, then
`sudo nginx -t && sudo systemctl reload nginx`. Check: `curl https://nucnec.de/cc/agent.lua` should print the agent.

## 2. Install the agent in-game

On each computer or turtle:

```
wget https://nucnec.de/cc/agent.lua startup.lua
startup
```

It asks for the `AGENT_TOKEN` once (stored with `settings`), then keeps running on every boot.
Give computers labels (`label set miner1`) so they're easy to tell apart. Later updates:
"Update agent" in the web UI or the `update_agent` tool — no need to touch the computer again.

> If the computer already has a `startup.lua`, rename it first; the agent starts a normal shell, so you can
> still run your old program from there (or add it to the agent later).

## 3. Web terminal

Open `https://nucnec.de/cc/`, log in with the `API_TOKEN`. Click a computer, click the screen and type.

**Script library.** Lua programs in `scripts/` are listed under "Script library" (description = the file's leading
`--` comment) and served publicly at `/scripts/<name>`, so in-game `wget <PUBLIC_URL>/scripts/<name> <name>` works.
Drop `.lua` files onto the library to add them.

**Files.** Each computer's page has a file browser (view, download). Drag files from your desktop or scripts from the
library onto it, or onto a computer in the sidebar, to copy them there. Transfers go through `eval` as base64, so no
agent update is needed; files are limited to 64 KiB (CC caps websocket messages at 128 KiB).

## 4. Claude Code

On the VPS (or any machine that can reach the relay):

```sh
claude mcp add ccbridge \
  -e CCBRIDGE_URL=https://nucnec.de/cc \
  -e CCBRIDGE_TOKEN=<API_TOKEN> \
  -- node /opt/ccbridge/server/mcp.js
```

Tools: `list_computers`, `get_screen`, `run_command`, `send_input`, `eval_lua`, `turtle_action`,
`get_status`, `terminate`, `reboot`, `update_agent`.

## REST API

All endpoints need `Authorization: Bearer <API_TOKEN>`.

| Method & path | Body | Result |
| --- | --- | --- |
| `GET /api/computers` | | list with online status |
| `GET /api/scripts` | | script library: `[{ name, size, description, url }]` |
| `PUT /api/scripts/:name` | file bytes | add or replace a library script |
| `GET /api/computers/:id/files?path=` | | `{ path, entries: [{ name, dir, size, readOnly }] }` |
| `GET /api/computers/:id/file?path=` | | file download |
| `PUT /api/computers/:id/file?path=` | file bytes | write a file (folders are created) |
| `GET /api/computers/:id/screen` | | `{ screen, cursor }` as text (`?format=raw` for colours) |
| `POST /api/computers/:id/run` | `{ command, wait? }` | types command + Enter, returns settled screen |
| `POST /api/computers/:id/input` | `{ text?, enter?, events? }` | raw input (`["key","up"]`, `["char","y"]`, `["paste","…"]`, `["terminate"]`) |
| `POST /api/computers/:id/eval` | `{ code, timeout? }` | `{ ok, values, output, error }` |
| `POST /api/computers/:id/turtle` | `{ action, args? }` | e.g. `{ "action": "forward" }` |
| `POST /api/computers/:id/status` | | fuel, inventory, surrounding blocks, GPS |
| `POST /api/computers/:id/terminate` \| `reboot` \| `update` | | |

## Security

`eval` is remote code execution on your in-game computers — keep both tokens secret, only expose the
relay over HTTPS, and rotate tokens by editing `.env` and restarting (`AGENT_TOKEN` changes need
`set ccbridge.token <new>` in-game).

## Development

```sh
cd server && npm install && npm test
```
