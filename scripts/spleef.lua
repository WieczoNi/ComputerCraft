-- spleef: wander a cobblestone arena and drop players through the floor.
-- Stays on the platform; only leaves it (one block down) to dig out a player.
-- Needs: diamond pickaxe equipped, some cobblestone in the inventory.
-- Stop with Ctrl+T.
local FLOOR = "minecraft:cobblestone"
local TURN_CHANCE = 0.15 -- chance per step to wander in a new direction
local REFILL_DELAY = 3   -- seconds before the 2x2 hole gets filled again

local drops, steps = 0, 0

local function log(msg)
  print(("[%s] %s"):format(textutils.formatTime(os.time(), true), msg))
end

local function onFloor()
  local ok, b = turtle.inspectDown()
  return ok and b.name == FLOOR
end

local function selectFloor()
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == FLOOR then
      turtle.select(i)
      return true
    end
  end
  return false
end

local function turnRandom()
  if math.random() < 0.5 then turtle.turnLeft() else turtle.turnRight() end
end

-- What is in front: "block", "entity" or "empty".
-- A failed place with no block there means an entity is standing in the way.
local function probe()
  if turtle.inspect() then return "block" end
  if not selectFloor() then error("out of " .. FLOOR, 0) end
  if turtle.place() then
    turtle.dig()
    return "empty"
  end
  return "entity"
end

local function retry(fn, tries)
  for _ = 1, tries or 20 do
    if fn() then return true end
    sleep(0.3)
  end
  return false
end

local function fwd()
  return retry(function()
    if turtle.forward() then return true end
    if turtle.detect() then turtle.dig() end
    return false
  end, 40)
end

local function isFloor(inspect)
  local ok, b = inspect()
  return ok and b.name == FLOOR
end

local function placeUpRetry()
  return retry(function() return selectFloor() and turtle.placeUp() end)
end

-- Tour the three far cells of the 2x2 from one block below the floor, calling
-- act() under each: from our hole (T) down, under the target (P), on to the
-- cell behind it, right, back, and home again. Ends in our hole facing P.
--   F2  F2R
--   P   PR      (P = block under the target)
--   T   TR
local function tourBelow(act)
  if not retry(function() return turtle.down() or (turtle.digDown() and false) end) then
    error("cannot get below the floor", 0)
  end
  local ok = fwd() and fwd()                         -- under F2
  if ok then act() turtle.turnRight() ok = fwd() end -- under F2R
  if ok then act() turtle.turnRight() ok = fwd() end -- under PR
  if ok then act() ok = fwd() end                    -- under TR
  if ok then turtle.turnRight() ok = fwd() end       -- under T
  if not ok then error("lost below the floor", 0) end
  if not retry(turtle.up, 40) then error("stuck below the floor", 0) end
  turtle.turnRight()                                 -- facing P again
end

-- Open a 2x2 hole under whoever is in front, wait, then put the floor back.
local function spleef()
  log("Target spotted, going under")
  if not turtle.digDown() or not turtle.down() then
    log("Could not get into the floor")
    return
  end
  local dug = {}
  local n = 0
  tourBelow(function()
    n = n + 1
    if isFloor(turtle.inspectUp) and turtle.digUp() then dug[n] = true end
  end)
  -- The target's own block goes last, from the side, so nobody lands on us.
  local digP = isFloor(turtle.inspect) and turtle.dig()
  drops = drops + 1
  log(("Floor gone! (drop #%d)"):format(drops))

  sleep(REFILL_DELAY)
  if digP then retry(function() return selectFloor() and turtle.place() end) end
  n = 0
  tourBelow(function()
    n = n + 1
    if dug[n] then placeUpRetry() end
  end)
  if not retry(turtle.up, 40) then error("stuck in the floor", 0) end
  if selectFloor() then turtle.placeDown() end
  log("Floor repaired")
end

local function step()
  local what = probe()
  if what == "entity" then
    spleef()
    turnRandom()
  elseif what == "block" then
    turnRandom()
  else
    if not turtle.forward() then
      turnRandom()
      return
    end
    steps = steps + 1
    if not onFloor() then
      -- Edge of the arena or a hole: go back and pick another direction.
      if not retry(turtle.back) then error("stranded off the platform", 0) end
      turnRandom()
    elseif math.random() < TURN_CHANCE then
      turnRandom()
    end
  end
end

math.randomseed(os.epoch("utc"))
if not onFloor() then
  printError("Put me on the " .. FLOOR .. " arena first.")
  return
end
if not selectFloor() then
  printError("I need some " .. FLOOR .. " in my inventory.")
  return
end
term.clear()
term.setCursorPos(1, 1)
log("SPLEEF BOT ONLINE. Run.")
while true do
  if turtle.getFuelLevel() < 20 then error("out of fuel", 0) end
  step()
end
