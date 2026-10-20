-- lavabot: harvest a ceiling grid of lava cauldrons every 15 minutes (or on a redstone pulse).
--
-- Home: on the oak planks, facing the deposit drawer (full buckets), with the
-- empties drawer to the right. The cauldron grid hangs 3 blocks up; the
-- turtle works 2 blocks up, filling buckets from the cauldron above it. The
-- grid is found by feel: the turtle only moves where there is a cauldron
-- overhead, and steps straight back if it ever is not.
--
-- Pauses when the deposit is full or there are no empty buckets left, and checks
-- again at the next harvest time or redstone pulse.
-- Position is saved after every move, so after a reboot it flies home first.
local INTERVAL = 900         -- seconds between harvests (a redstone pulse starts one early)
local WORK_Y = 2             -- blocks above home where it flies
local REFUEL_BELOW = 2000    -- burn a lava bucket when fuel drops under this
local CARRY = 15             -- empty buckets per trip (one slot of empties + 15 slots of lava)
local HOME_BLOCK = "minecraft:oak_planks"
local BUCKET, LAVA = "minecraft:bucket", "minecraft:lava_bucket"
local STATE_FILE = "/.lavabot_state"

-- Position relative to home. Facing: 0 = towards the deposit (+x), 1 = right (+z), 2 = -x, 3 = -z.
local pos = { x = 0, y = 0, z = 0, f = 0 }
local stats = { runs = 0, buckets = 0 }

local function log(msg)
  print(("[%s] %s"):format(textutils.formatTime(os.time(), true), msg))
end

local function save(pending)
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize({ pos = pos, pending = pending, fuel = turtle.getFuelLevel(), stats = stats }))
  f.close()
end

local function loadState()
  if not fs.exists(STATE_FILE) then return end
  local f = fs.open(STATE_FILE, "r")
  local s = textutils.unserialize(f.readAll())
  f.close()
  if not s then return end
  pos, stats = s.pos, s.stats or stats
  -- A move costs exactly one fuel: if fuel dropped, the move we were in the middle of happened.
  if s.pending and turtle.getFuelLevel() < s.fuel then
    pos.x, pos.y, pos.z = pos.x + s.pending.x, pos.y + s.pending.y, pos.z + s.pending.z
  end
end

---------------------------------------------------------------------------
-- Movement with dead reckoning
---------------------------------------------------------------------------
local DX = { [0] = 1, 0, -1, 0 }
local DZ = { [0] = 0, 1, 0, -1 }

local function turnRight() turtle.turnRight() pos.f = (pos.f + 1) % 4 save() end
local function turnLeft() turtle.turnLeft() pos.f = (pos.f + 3) % 4 save() end
local function face(f)
  if (pos.f + 1) % 4 == f then turnRight() end
  while pos.f ~= f do turnLeft() end
end

-- One step; retries for a while if something (a player, a mob) is in the way.
local function step(dir) -- "fwd", "back", "up", "down"
  local d = { x = 0, y = 0, z = 0 }
  if dir == "fwd" then d.x, d.z = DX[pos.f], DZ[pos.f]
  elseif dir == "back" then d.x, d.z = -DX[pos.f], -DZ[pos.f]
  elseif dir == "up" then d.y = 1
  else d.y = -1 end
  local move = ({ fwd = turtle.forward, back = turtle.back, up = turtle.up, down = turtle.down })[dir]
  for _ = 1, 30 do
    save(d)
    if move() then
      pos.x, pos.y, pos.z = pos.x + d.x, pos.y + d.y, pos.z + d.z
      save()
      return true
    end
    save()
    if dir ~= "back" and dir ~= "fwd" then sleep(1) else return false end
  end
  return false
end

local function stepOrWait(dir)
  for _ = 1, 30 do
    if step(dir) then return end
    sleep(1)
  end
  error("blocked at " .. pos.x .. "," .. pos.y .. "," .. pos.z, 0)
end

local function cauldronAbove()
  local ok, b = turtle.inspectUp()
  return ok and b.name:find("cauldron$") ~= nil, ok and b.name
end

-- Fly at work height to (x, z): first along x, then along z. Only used inside the grid.
local function goTo(x, z)
  while pos.y < WORK_Y do stepOrWait("up") end
  if pos.x ~= x then
    face(pos.x < x and 0 or 2)
    while pos.x ~= x do stepOrWait("fwd") end
  end
  if pos.z ~= z then
    face(pos.z < z and 1 or 3)
    while pos.z ~= z do stepOrWait("fwd") end
  end
end

local function goHome()
  if pos.y > 0 then
    -- Back along z first, then x: the reverse of goTo, so it retraces a known path.
    while pos.y < WORK_Y do stepOrWait("up") end
    if pos.z ~= 0 then face(3) while pos.z ~= 0 do stepOrWait("fwd") end end
    if pos.x ~= 0 then face(2) while pos.x ~= 0 do stepOrWait("fwd") end end
    while pos.y > 0 do stepOrWait("down") end
  end
  face(0)
  local ok, b = turtle.inspectDown()
  if not ok or b.name ~= HOME_BLOCK then
    error("not home (no " .. HOME_BLOCK .. " below me) - put me back on my plank", 0)
  end
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------
local function count(name)
  local n = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then n = n + d.count end
  end
  return n
end

local function selectItem(name)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then turtle.select(s) return true end
  end
  return false
end

local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

-- Room for the filled bucket: a free slot, or the bucket stack is down to its last one.
local function canFill()
  return selectItem(BUCKET) and (freeSlots() > 0 or turtle.getItemCount() == 1)
end

local function refuel()
  -- Running dry with nothing to burn: borrow one bucket from the deposit.
  if turtle.getFuelLevel() < 400 and count(LAVA) == 0 then
    face(0)
    turtle.select(16)
    turtle.suck(1)
  end
  while turtle.getFuelLevel() < REFUEL_BELOW and selectItem(LAVA) do
    turtle.refuel(1)
    log(("Refuelled, fuel %d"):format(turtle.getFuelLevel()))
  end
end

-- At home: refuel, put lava in the deposit, top up empties. Returns false + reason to stop.
local function serviceHome()
  refuel()
  face(0)
  while selectItem(LAVA) do
    if not turtle.drop() then return false, "deposit drawer is full" end
  end
  face(1)
  local have = count(BUCKET)
  if have > CARRY then
    selectItem(BUCKET)
    turtle.drop(have - CARRY)
  elseif have < CARRY then
    turtle.select(1)
    turtle.suck(CARRY - have)
  end
  face(0)
  if count(BUCKET) == 0 then return false, "no empty buckets left" end
  return true
end

---------------------------------------------------------------------------
-- Harvest: snake through the grid, rows along x, stepping +z between rows.
---------------------------------------------------------------------------

-- Step forward only if a cauldron is above the next cell; otherwise come back.
local function stepInGrid()
  if not step("fwd") then return false end
  if cauldronAbove() then return true end
  stepOrWait("back")
  return false
end

local function harvest()
  local filled = 0
  goTo(0, 0)
  if not cauldronAbove() then error("no cauldron above my home column", 0) end
  local rowDir = 0
  while true do
    local ok, name = cauldronAbove()
    if ok and name == "minecraft:lava_cauldron" then
      if not canFill() then
        -- Out of buckets or room: run home, unload, and come back to this cell.
        local x, z, f = pos.x, pos.z, pos.f
        goHome()
        local cont, why = serviceHome()
        if not cont then return filled, why end
        goTo(x, z)
        face(f)
        selectItem(BUCKET)
      end
      if turtle.placeUp() then
        filled = filled + 1
        stats.buckets = stats.buckets + 1
      end
    end
    face(rowDir)
    if not stepInGrid() then
      -- End of the row: shift one to the right and snake back.
      face(1)
      if not stepInGrid() then break end
      rowDir = (rowDir + 2) % 4
    end
  end
  return filled
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
-- Standing on the plank? Then we are home whatever the save says; find which way
-- we face from the drawers (deposit in front, empties to the right).
local function onPlank()
  local ok, b = turtle.inspectDown()
  return ok and b.name == HOME_BLOCK
end
local function isDrawer()
  local ok, b = turtle.inspect()
  return ok and b.name:find("^storagedrawers:") ~= nil
end
local function calibrate()
  for _ = 1, 4 do
    if isDrawer() then
      turtle.turnRight()
      local right = isDrawer()
      turtle.turnLeft()
      if right then
        pos = { x = 0, y = 0, z = 0, f = 0 }
        save()
        return
      end
    end
    turtle.turnRight()
  end
  error("on my plank but cannot find the drawers", 0)
end

loadState()
if onPlank() then
  calibrate()
else
  log("Resuming: flying home first")
end
goHome()
term.clear()
term.setCursorPos(1, 1)
log("lavabot online")

local function redstoneOn()
  for _, side in ipairs(redstone.getSides()) do
    if redstone.getInput(side) then return true end
  end
  return false
end

-- Wait for the next harvest time, or a fresh redstone signal on any side.
local function waitForNext()
  local timer = os.startTimer(INTERVAL)
  local was = redstoneOn()
  while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == timer then return end
    if ev == "redstone" then
      local now = redstoneOn()
      if now and not was then
        log("Redstone signal: harvesting now")
        return
      end
      was = now
    end
  end
end

-- One harvest; returns why it had to pause, or nil if all went well.
local function cycle()
  local cont, why = serviceHome()
  if not cont then return why end
  stats.runs = stats.runs + 1
  log(("Harvest #%d, fuel %d"):format(stats.runs, turtle.getFuelLevel()))
  local filled, stop = harvest()
  goHome()
  log(("Collected %d (total %d)"):format(filled, stats.buckets))
  if stop then return stop end
  cont, why = serviceHome()
  if not cont then return why end
end

while true do
  local paused = cycle()
  save()
  if paused then
    log("Paused: " .. paused .. ". Will check again in " .. INTERVAL / 60 .. " min.")
  else
    log(("Next harvest in %d min"):format(INTERVAL / 60))
  end
  waitForNext()
end
