-- sign: "Lava Factory", a winking face and a strip of glowing lava on the attached monitor.
-- Run in the background by the ccbridge agent: set ccbridge.autorun { "sign.lua" }. Ignores Ctrl+T.
local WINK_EVERY = 20  -- seconds between winks
-- Wink animation as {lid stage, seconds}: 0 open, 1-2 closing, 3 shut.
local WINK = { { 1, 0.2 }, { 2, 0.2 }, { 3, 2.0 }, { 2, 0.2 }, { 1, 0.2 } }
local FRAME = 0.2      -- seconds per lava frame

-- 8x8 face from the skin (head front + hat layer), indices into FACE_COLOURS.
local FACE_COLOURS = { 0x131519, 0x19181f, 0x1e1e28, 0xca9239, 0xdfbf48, 0x593b27, 0x79533a, 0x000000, 0x9c6131, 0x966c48, 0x774625, 0xb9855a, 0x6c6c6c }
local FACE = {
  { 1, 2, 2, 3, 3, 2, 2, 1 },
  { 2, 3, 3, 3, 3, 3, 3, 2 },
  { 3, 4, 4, 5, 5, 4, 4, 3 },
  { 6, 7, 8, 6, 6, 8, 6, 9 },
  { 9, 7, 6, 7, 6, 10, 7, 9 },
  { 9, 11, 8, 6, 10, 8, 7, 9 },
  { 4, 12, 8, 8, 8, 8, 6, 4 },
  { 4, 4, 10, 13, 10, 10, 4, 4 },
}
local WINK_EYE = { x = 6, y = 4 } -- the eye on the viewer's right
local SKIN = 6                    -- colour of the closed eyelid
-- Face colours used for the lava, darkest to brightest after sorting: near-black
-- hair shades for the cooled crust, browns for embers, gold for the hottest spots.
local LAVA_COLOURS = { 1, 3, 6, 11, 7, 10, 9, 12, 4, 5 }

-- 5-wide glyphs; rows 1-7 sit on the baseline, rows 8-9 are descenders.
local GLYPHS = {
  L = { "#....", "#....", "#....", "#....", "#....", "#....", "#####" },
  F = { "#####", "#....", "#....", "####.", "#....", "#....", "#...." },
  a = { ".....", ".....", ".###.", "....#", ".####", "#...#", ".####" },
  v = { ".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.." },
  c = { ".....", ".....", ".###.", "#....", "#....", "#...#", ".###." },
  t = { ".#...", ".#...", "####.", ".#...", ".#...", ".#..#", "..##." },
  o = { ".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###." },
  r = { ".....", ".....", "#.##.", "##..#", "#....", "#....", "#...." },
  y = { ".....", ".....", "#...#", "#...#", "#...#", ".####", "....#", "....#", ".###." },
}
local LINES = { "Lava", "Factory" }

local mon
local hex = "0123456789abcdef"
local sin, floor = math.sin, math.floor

-- Palette slots: 0 text (pulses), 1..13 face, 14 eyelid line, 15 background.
local TEXT, LID, BG = "0", "e", "f"
local faceSlots, lavaRamp, lum = {}, {}, {}
local function setupPalette()
  local colour = mon.isColour()
  for i, rgb in ipairs(FACE_COLOURS) do
    local r, g, b = colours.unpackRGB(rgb)
    lum[i] = 0.299 * r + 0.587 * g + 0.114 * b
    if not colour then
      -- Greyscale by luminance, stretched so skin, band and hair stay apart;
      -- the darkest hair sits just above black so the head outline still reads.
      local v = rgb == 0 and 0 or math.min(1, 0.12 + 0.88 * math.max(0, (lum[i] - 0.08) / 0.65) ^ 1.6)
      r, g, b = v, v, v
    end
    mon.setPaletteColour(bit32.lshift(1, i), r, g, b)
    faceSlots[i] = hex:sub(i + 1, i + 1)
  end
  mon.setPaletteColour(bit32.lshift(1, 14), 0.75, 0.75, 0.75)
  mon.setPaletteColour(colours.white, 1, 1, 1)
  mon.setPaletteColour(colours.black, 0, 0, 0)
  local sorted = { table.unpack(LAVA_COLOURS) }
  table.sort(sorted, function(a, b) return lum[a] < lum[b] end)
  lavaRamp = {}
  for i, c in ipairs(sorted) do lavaRamp[i] = faceSlots[c] end
end

local layout
local function computeLayout()
  local w, h = mon.getSize()
  local py = math.max(1, floor((h - 4) / 8)) -- face pixel: py rows ...
  local px = math.max(1, floor(py * 1.5 + 0.5)) -- ... px cols (chars are 6x9)
  local faceW, faceH = px * 8, py * 8
  local margin = math.max(1, floor(w / 40))
  local faceX = w - faceW - margin * 2 + 1
  local faceY = floor((h - faceH) / 2) + 1
  local band = math.max(3, floor(h / 6)) -- lava rows at the bottom of the text side
  layout = { w = w, h = h, px = px, py = py, faceX = faceX, faceY = faceY, margin = margin, band = band }
end

-- Turn one cell's six subpixel colours (blit digits) into a teletext char + fg + bg.
-- The bottom-right subpixel is always the background colour.
local function cell(sub, light, dark)
  local fg, bg = light, dark
  if sub[6] == light then fg, bg = dark, light end
  local n = 0
  for i = 1, 5 do
    if sub[i] == fg then n = n + bit32.lshift(1, i - 1) end
  end
  return string.char(128 + n), fg, bg
end

-- Text: draw glyphs into a subpixel bitmap (2x3 per character cell) and blit it.
local function drawText()
  local L = layout
  local rows = L.h - L.band
  local areaW = (L.faceX - 1 - L.margin * 2) * 2 -- subpixels available
  local areaH = rows * 3
  local widest = 0
  for _, s in ipairs(LINES) do widest = math.max(widest, #s * 6 - 1) end
  local lineH, gap = 9, 3 -- glyph rows incl. descender, gap between lines
  local totalH = (#LINES - 1) * (lineH + gap) + lineH
  local s = math.max(1, math.min(floor(areaW / widest), floor((areaH - 12) / totalH)))
  local ox = L.margin * 2 + floor((areaW - widest * s) / 2)
  local oy = floor((areaH - totalH * s) / 2)

  local bits = {}
  for li, str in ipairs(LINES) do
    local top = oy + (li - 1) * (lineH + gap) * s
    for ci = 1, #str do
      local left = ox + (ci - 1) * 6 * s
      for gy, row in ipairs(GLYPHS[str:sub(ci, ci)] or {}) do
        for gx = 1, 5 do
          if row:sub(gx, gx) == "#" then
            for dy = 0, s - 1 do
              local y = top + (gy - 1) * s + dy
              bits[y] = bits[y] or {}
              for dx = 0, s - 1 do bits[y][left + (gx - 1) * s + dx] = true end
            end
          end
        end
      end
    end
  end

  local sub = {}
  for cy = 1, rows do
    local text, fg, bg = {}, {}, {}
    for cx = 1, L.faceX - 1 do
      local x0, y0 = (cx - 1) * 2, (cy - 1) * 3
      for i = 0, 5 do
        local r = bits[y0 + floor(i / 2)]
        sub[i + 1] = (r and r[x0 + i % 2]) and TEXT or BG
      end
      text[cx], fg[cx], bg[cx] = cell(sub, TEXT, BG)
    end
    mon.setCursorPos(1, cy)
    mon.blit(table.concat(text), table.concat(fg), table.concat(bg))
  end
end

-- Lava strip: a rippling surface over slowly churning heat, quantised to the ramp.
local function drawLava(t)
  local L = layout
  local ramp, n = lavaRamp, #lavaRamp
  local top = L.h - L.band + 1
  local sub = {}
  for cy = 0, L.band - 1 do
    local text, fg, bg = {}, {}, {}
    for cx = 1, L.faceX - 1 do
      local light, dark = 0, 99
      for i = 0, 5 do
        local x = (cx - 1) * 2 + i % 2
        local y = cy * 3 + floor(i / 2)
        local surface = 2.5 + 1.6 * sin(x * 0.09 + t * 0.7) + 0.9 * sin(x * 0.27 - t * 1.4)
        local k = 0
        if y >= surface then
          -- Mostly dark crust; only the peaks of the noise glow, plus a hot rim at the top.
          local noise = 0.5 * sin(x * 0.17 + y * 0.6 + t * 0.8)
            + 0.3 * sin(x * 0.05 - t * 0.5 + y * 0.25)
            + 0.2 * sin(x * 0.31 + y * 0.9 - t * 1.3)
          local heat = 0.1 + 0.9 * math.max(0, (noise + 0.15) / 1.15) ^ 2.2
          if y - surface < 1.2 then heat = math.max(heat, 0.85) end
          k = math.max(1, math.min(n, floor(heat * n + 0.5)))
        end
        sub[i + 1] = k
        if k > light then light = k end
        if k < dark then dark = k end
      end
      -- Each cell can only show two colours: snap every subpixel to the nearer one.
      local lc = light == 0 and BG or ramp[light]
      local dc = dark == 0 and BG or ramp[dark]
      for i = 1, 6 do
        sub[i] = (sub[i] - dark >= light - sub[i]) and lc or dc
      end
      text[cx], fg[cx], bg[cx] = cell(sub, lc, dc)
    end
    mon.setCursorPos(1, top + cy)
    mon.blit(table.concat(text), table.concat(fg), table.concat(bg))
  end
end

local function drawFace()
  local L = layout
  for fy = 1, 8 do
    for r = 1, L.py do
      local row = {}
      for fx = 1, 8 do row[fx] = faceSlots[FACE[fy][fx]]:rep(L.px) end
      local bg = table.concat(row)
      mon.setCursorPos(L.faceX, L.faceY + (fy - 1) * L.py + r - 1)
      mon.blit((" "):rep(#bg), bg, bg)
    end
  end
end

-- Redraw just the winking eye. The light lid line slides down one step per stage:
-- skin above it, the open eye below it until stage 3, where the eye is shut.
local function drawEye(stage)
  local L = layout
  local eye = faceSlots[FACE[WINK_EYE.y][WINK_EYE.x]]
  local lidRow = stage > 0 and math.max(1, floor(stage * (L.py - 1) / 3 + 0.5)) or 0
  for r = 1, L.py do
    local c = eye
    if stage > 0 then
      if r == lidRow then c = LID
      elseif r < lidRow or stage == 3 then c = faceSlots[SKIN] end
    end
    local bg = c:rep(L.px)
    mon.setCursorPos(L.faceX + (WINK_EYE.x - 1) * L.px, L.faceY + (WINK_EYE.y - 1) * L.py + r - 1)
    mon.blit((" "):rep(#bg), bg, bg)
  end
end

-- Which lid stage the wink is at, `t` seconds after it started (nil once it is over).
local function winkStage(t)
  for _, step in ipairs(WINK) do
    if t < step[2] then return step[1] end
    t = t - step[2]
  end
end

-- Text glows along with the lava.
local function pulse(t)
  local v = 0.82 + 0.18 * sin(t * 1.3)
  mon.setPaletteColour(colours.white, v, v, v)
end

-- Sleep that Ctrl+T cannot interrupt, but wakes early on monitor changes.
local function wait(secs)
  local id = os.startTimer(secs)
  while true do
    local ev, a = os.pullEventRaw()
    if ev == "timer" and a == id then return "timer" end
    if ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then return "redraw" end
  end
end

local function run()
  mon.setTextScale(0.5)
  setupPalette()
  computeLayout()
  mon.setBackgroundColour(colours.black)
  mon.clear()
  drawText()
  drawFace()
  local start = os.clock()
  local nextWink, stage = start + WINK_EVERY, 0
  while true do
    local now = os.clock()
    drawLava(now - start)
    pulse(now - start)
    if now >= nextWink then
      local want = winkStage(now - nextWink) or 0
      if want ~= stage then
        drawEye(want)
        stage = want
      end
      if want == 0 then nextWink = now + WINK_EVERY end
    end
    if wait(FRAME) == "redraw" then return end
  end
end

while true do
  mon = peripheral.find("monitor")
  if mon then
    local ok, err = pcall(run)
    if not ok then printError("sign: " .. tostring(err)) end
  end
  wait(2)
end
