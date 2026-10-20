// Helpers for generating Lua code sent to agents.

/** Convert a JSON value to a Lua literal. */
export function toLua(v) {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new Error("non-finite number");
    return String(v);
  }
  if (typeof v === "string") {
    return '"' + v.replace(/[\\"\x00-\x1f\x7f]/g, (c) => "\\" + c.charCodeAt(0).toString().padStart(3, "0")) + '"';
  }
  if (Array.isArray(v)) return "{" + v.map(toLua).join(", ") + "}";
  if (typeof v === "object") {
    return "{" + Object.entries(v).map(([k, val]) => `[${toLua(k)}] = ${toLua(val)}`).join(", ") + "}";
  }
  throw new Error(`cannot convert ${typeof v} to Lua`);
}

/** Lua snippet returning a status table: identity, fuel, inventory, surroundings, GPS. */
export const statusCode = `
local s = { id = os.getComputerID(), label = os.getComputerLabel(), turtle = turtle ~= nil }
if turtle then
  s.fuel = turtle.getFuelLevel()
  s.fuelLimit = turtle.getFuelLimit()
  s.selected = turtle.getSelectedSlot()
  s.inventory = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then s.inventory[#s.inventory + 1] = { slot = i, name = d.name, count = d.count } end
  end
  s.blocks = {}
  for _, dir in ipairs({ "", "Up", "Down" }) do
    local ok, b = turtle["inspect" .. dir]()
    s.blocks[dir == "" and "front" or dir:lower()] = ok and b.name or "air"
  end
end
if peripheral.find("modem", function(_, m) return m.isWireless() end) then
  local x, y, z = gps.locate(1)
  if x then s.position = { x = x, y = y, z = z } end
end
return s
`;

// Files travel as base64 so arbitrary bytes survive the JSON round trip; CC
// websocket messages are capped at 128 KiB, so keep files well under that.
export const MAX_FILE_BYTES = 64 * 1024;

const B64 = `
local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64enc(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    out[#out + 1] = A:sub(q[1] + 1, q[1] + 1) .. A:sub(q[2] + 1, q[2] + 1)
      .. (b and A:sub(q[3] + 1, q[3] + 1) or "=") .. (c and A:sub(q[4] + 1, q[4] + 1) or "=")
  end
  return table.concat(out)
end
local function b64dec(s)
  local idx = {}
  for i = 1, 64 do idx[A:byte(i)] = i - 1 end
  local out = {}
  for i = 1, #s, 4 do
    local a, b, c, d = s:byte(i, i + 3)
    local n = idx[a] * 262144 + idx[b] * 4096 + (idx[c] or 0) * 64 + (idx[d] or 0)
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if c ~= 61 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if d ~= 61 then out[#out + 1] = string.char(n % 256) end
  end
  return table.concat(out)
end
`;

/** Lua returning { path, entries = { {name, dir, size} } } for a directory. */
export function listFilesCode(dir) {
  return `
local dir = ${toLua(dir)}
if not fs.isDir(dir) then error("not a directory: " .. dir, 0) end
local entries = {}
for _, name in ipairs(fs.list(dir)) do
  local p = fs.combine(dir, name)
  local isDir = fs.isDir(p)
  entries[#entries + 1] = { name = name, dir = isDir, size = isDir and 0 or fs.getSize(p), readOnly = fs.isReadOnly(p) }
end
return { path = "/" .. fs.combine(dir, ""), entries = entries }`;
}

/** Lua returning { size, data = base64 } for a file. */
export function readFileCode(file) {
  return `${B64}
local path = ${toLua(file)}
if not fs.exists(path) or fs.isDir(path) then error("no such file: " .. path, 0) end
local size = fs.getSize(path)
if size > ${MAX_FILE_BYTES} then error("file too large to transfer (" .. size .. " bytes)", 0) end
local f = fs.open(path, "rb")
local data = f.readAll() or ""
f.close()
return { size = #data, data = b64enc(data) }`;
}

/** Lua that writes base64 data to a file (creating folders) and returns its size. */
export function writeFileCode(file, base64) {
  return `${B64}
local path = ${toLua(file)}
if fs.isDir(path) then error("is a directory: " .. path, 0) end
if fs.isReadOnly(path) then error("read-only: " .. path, 0) end
local dir = fs.getDir(path)
if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
local data = b64dec(${toLua(base64)})
local f = fs.open(path, "wb")
f.write(data)
f.close()
return { size = fs.getSize(path) }`;
}
