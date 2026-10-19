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
