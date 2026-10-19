-- ccbridge agent: connects this computer/turtle to the ccbridge relay.
-- Install in-game with:  wget __CCBRIDGE_URL__/agent.lua startup.lua
-- The relay substitutes __CCBRIDGE_URL__ when serving this file.

local VERSION = "0.1.0"
local BASE_URL = "__CCBRIDGE_URL__"

settings.define("ccbridge.url", {
    description = "Base URL of the ccbridge relay",
    default = BASE_URL,
    type = "string",
})
settings.define("ccbridge.token", {
    description = "Agent token for the ccbridge relay",
    type = "string",
})

local function baseUrl()
    return (settings.get("ccbridge.url"):gsub("/+$", ""))
end

local function wsUrl()
    return baseUrl():gsub("^http", "ws") .. "/ws/agent"
end

-- First run: ask for the token once and persist it.
if not settings.get("ccbridge.token") then
    term.setTextColour(colours.yellow)
    print("ccbridge: no token configured.")
    term.setTextColour(colours.white)
    write("Agent token: ")
    local token = read("*")
    settings.set("ccbridge.token", token)
    settings.save()
end

local native = term.current()
local w, h = native.getSize()
local win = window.create(native, 1, 1, w, h, true)

---------------------------------------------------------------------------
-- Tiny cooperative scheduler so the shell, the network loop and remote jobs
-- can all yield on events independently.
---------------------------------------------------------------------------

local tasks = {}

local function resumeTask(t, ...)
    local ok, filter = coroutine.resume(t.co, ...)
    if not ok then
        t.dead = true
        if t.onError then t.onError(filter) end
    elseif coroutine.status(t.co) == "dead" then
        t.dead = true
    else
        t.filter = filter
    end
end

local function spawn(fn, opts)
    local t = { co = coroutine.create(fn) }
    if opts then
        for k, v in pairs(opts) do t[k] = v end
    end
    tasks[#tasks + 1] = t
    resumeTask(t)
    return t
end

---------------------------------------------------------------------------
-- JSON helpers
---------------------------------------------------------------------------

-- Turn arbitrary Lua values into something serialiseJSON accepts.
local function sanitize(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local ty = type(v)
    if ty == "nil" or ty == "boolean" or ty == "string" then return v end
    if ty == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    end
    if ty ~= "table" then return "<" .. ty .. ">" end
    if seen[v] then return "<cycle>" end
    if depth > 8 then return "<table>" end
    seen[v] = true

    local n, isArray = 0, true
    for k in pairs(v) do
        n = n + 1
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then isArray = false end
    end
    if isArray and n == #v then
        if n == 0 then
            seen[v] = nil
            return textutils.empty_json_array
        end
        local out = {}
        for i = 1, n do
            local s = sanitize(v[i], depth + 1, seen)
            if s == nil then s = textutils.json_null end
            out[i] = s
        end
        seen[v] = nil
        return out
    end
    local out = {}
    for k, val in pairs(v) do
        local s = sanitize(val, depth + 1, seen)
        if s ~= nil then out[tostring(k)] = s end
    end
    seen[v] = nil
    return out
end

local ws -- current websocket, nil while disconnected

local function send(msg)
    if not ws then return false end
    local ok = pcall(ws.send, textutils.serialiseJSON(sanitize(msg)))
    return ok
end

---------------------------------------------------------------------------
-- Screen mirroring
---------------------------------------------------------------------------

local lastScreen

local function snapshot()
    local lines, fg, bg = {}, {}, {}
    for y = 1, h do
        lines[y], fg[y], bg[y] = win.getLine(y)
    end
    local cx, cy = win.getCursorPos()
    return {
        width = w,
        height = h,
        lines = lines,
        fg = fg,
        bg = bg,
        cursor = { x = cx, y = cy, blink = win.getCursorBlink() },
    }
end

local function screenKey(s)
    return table.concat(s.lines, "\n") .. table.concat(s.fg) .. table.concat(s.bg)
        .. s.cursor.x .. "," .. s.cursor.y .. tostring(s.cursor.blink)
end

local function pushScreen(force)
    local s = snapshot()
    local key = screenKey(s)
    if force or key ~= lastScreen then
        if send({ type = "screen", screen = s }) then lastScreen = key end
    end
end

---------------------------------------------------------------------------
-- Remote operations
---------------------------------------------------------------------------

local jobs = {}

local function runEval(reqId, code)
    local output = {}
    local function capture(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        output[#output + 1] = table.concat(parts, "\t")
    end
    local env = setmetatable({
        print = capture,
        write = function(s) output[#output + 1] = tostring(s) end,
    }, { __index = _ENV })

    local fn, err = load("return " .. code, "=remote", "t", env)
    if not fn then fn, err = load(code, "=remote", "t", env) end
    if not fn then
        send({ type = "result", reqId = reqId, ok = false, error = err, output = output })
        return
    end

    local job = spawn(function()
        local res = table.pack(pcall(fn))
        jobs[reqId] = nil
        if res[1] then
            local values = {}
            for i = 2, res.n do
                local v = sanitize(res[i])
                if v == nil then v = textutils.json_null end
                values[i - 1] = v
            end
            if #values == 0 then values = textutils.empty_json_array end
            send({ type = "result", reqId = reqId, ok = true, values = values, output = output })
        else
            send({ type = "result", reqId = reqId, ok = false, error = tostring(res[2]), output = output })
        end
    end, {
        onError = function(e)
            jobs[reqId] = nil
            send({ type = "result", reqId = reqId, ok = false, error = tostring(e), output = output })
        end,
    })
    -- Jobs that finish without yielding are already done here.
    if not job.dead then jobs[reqId] = job end
end

local function queueInput(events)
    for _, e in ipairs(events or {}) do
        local kind = e[1]
        if kind == "key" then
            local code = keys[e[2]]
            if code then
                os.queueEvent("key", code, false)
                if e[3] ~= "hold" then os.queueEvent("key_up", code) end
            end
        elseif kind == "key_up" then
            local code = keys[e[2]]
            if code then os.queueEvent("key_up", code) end
        elseif kind == "char" then
            for c in tostring(e[2]):gmatch(".") do os.queueEvent("char", c) end
        elseif kind == "paste" then
            os.queueEvent("paste", tostring(e[2]))
        elseif kind == "terminate" then
            os.queueEvent("terminate")
        end
    end
end

local function selfUpdate()
    local res = http.get(baseUrl() .. "/agent.lua")
    if not res then return false, "download failed" end
    local body = res.readAll()
    res.close()
    local path = "/" .. shell.getRunningProgram()
    local f = fs.open(path, "w")
    f.write(body)
    f.close()
    return true
end

local function handle(msg)
    local op = msg.op
    if op == "eval" then
        runEval(msg.reqId, msg.code or "")
        return
    elseif op == "input" then
        queueInput(msg.events)
    elseif op == "screen" then
        pushScreen(true)
    elseif op == "cancel" then
        local job = jobs[msg.target]
        if job then
            job.dead = true
            jobs[msg.target] = nil
        end
    elseif op == "reboot" then
        send({ type = "result", reqId = msg.reqId, ok = true, values = { true } })
        os.reboot()
    elseif op == "update" then
        local ok, err = selfUpdate()
        send({ type = "result", reqId = msg.reqId, ok = ok, error = err, values = { ok } })
        if ok then os.reboot() end
        return
    else
        send({ type = "result", reqId = msg.reqId, ok = false, error = "unknown op: " .. tostring(op) })
        return
    end
    if msg.reqId then send({ type = "result", reqId = msg.reqId, ok = true, values = { true } }) end
end

---------------------------------------------------------------------------
-- Network loop
---------------------------------------------------------------------------

local function hello()
    return {
        type = "hello",
        token = settings.get("ccbridge.token"),
        id = os.getComputerID(),
        label = os.getComputerLabel(),
        turtle = turtle ~= nil,
        pocket = pocket ~= nil,
        advanced = term.isColour(),
        version = VERSION,
        width = w,
        height = h,
    }
end

local function netLoop()
    while true do
        local sock = http.websocket(wsUrl())
        if sock then
            ws = sock
            lastScreen = nil
            send(hello())
            pushScreen(true)
            local tick = os.startTimer(0.1)
            while ws do
                local ev = table.pack(os.pullEventRaw())
                local name = ev[1]
                if name == "websocket_message" and ev[2] == wsUrl() then
                    local ok, msg = pcall(textutils.unserialiseJSON, ev[3])
                    if ok and type(msg) == "table" then
                        if msg.type == "error" then
                            -- Relay rejected us (e.g. bad token); show it on screen.
                            print("ccbridge: " .. tostring(msg.message))
                        else
                            handle(msg)
                        end
                    end
                elseif name == "websocket_closed" and ev[2] == wsUrl() then
                    ws = nil
                elseif name == "timer" and ev[2] == tick then
                    pushScreen(false)
                    tick = os.startTimer(0.1)
                end
            end
        end
        sleep(5)
    end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local function shellLoop()
    while true do
        os.run({ shell = shell, multishell = multishell }, "/rom/programs/shell.lua")
        print("ccbridge: shell exited, restarting")
    end
end

term.redirect(win)
win.clear()
win.setCursorPos(1, 1)

local function netMain()
    while true do
        local ok, err = pcall(netLoop)
        ws = nil
        if not ok then printError("ccbridge net error: " .. tostring(err)) end
        sleep(5)
    end
end

spawn(shellLoop)
spawn(netMain, { isNet = true })

while true do
    local ev = table.pack(os.pullEventRaw())
    local name = ev[1]
    local snapshotTasks = { table.unpack(tasks) }
    for _, t in ipairs(snapshotTasks) do
        if not t.dead then
            local wants = t.filter == nil or t.filter == name
            -- Ctrl+T in-game only goes to the shell and remote jobs, never the net loop.
            if name == "terminate" then wants = not t.isNet end
            if wants then resumeTask(t, table.unpack(ev, 1, ev.n)) end
        end
    end
    for i = #tasks, 1, -1 do
        if tasks[i].dead then table.remove(tasks, i) end
    end
end
