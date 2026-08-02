-- cr.keys — always-on hotkey cheatsheet.
--
-- Every capability here is behind a chord, and a chord you can't remember is a
-- capability you don't have. This is the panel that fixes that: it sits in a
-- corner and lists them.
--
-- It also shows live state next to the toggles — whether the mic is listening,
-- whether watch mode is capturing, how many suggestions are queued — so it
-- doubles as the status readout. A legend that only lists keys goes stale in
-- your head; one that tells you what's currently ON gets read.
--
-- Toggle: ⌃⌥⌘K or menu bar. Sticky via hs.settings (survives reload/reboot).

local log = require("cr.log")

local M = { visible = false }

local canvas, timer
local dragTap, dragDX, dragDY, dragged
-- ROW has to clear BOTH lines of a row (label + chord) plus a gap, or each
-- chord ends up crowding the next row's label and the whole panel reads as one
-- undifferentiated block. 15 (label) + 14 (chord) + 9 (gap).
local W, ROW, PAD = 290, 38, 17

local function savedPos()
  local p = hs.settings.get("cr.keys.pos")
  if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then return p end
  return nil
end

-- Keep the panel on a screen that actually exists: monitors get unplugged and
-- a position saved on a second display would otherwise strand it off-canvas.
local function clampToScreen(x, y, w, h)
  local best
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:frame()
    if x + w > f.x and x < f.x + f.w and y + h > f.y and y < f.y + f.h then best = f; break end
  end
  local f = best or hs.screen.mainScreen():frame()
  return math.max(f.x, math.min(x, f.x + f.w - w)),
         math.max(f.y, math.min(y, f.y + f.h - h))
end

-- Drag: the tap lives only for the duration of one drag — created on mouse
-- down, torn down on mouse up. Worth stating explicitly because an *always-on*
-- eventtap in this config is what once made typing drop characters
-- system-wide: Hammerspoon is single-threaded, so a permanent tap starves on
-- every OCR capture or AppleScript call. A tap that exists for the second you
-- are holding the mouse cannot do that.
local function startDrag()
  if not canvas then return end
  local f = canvas:frame()
  local m = hs.mouse.absolutePosition()
  dragDX, dragDY, dragged = m.x - f.x, m.y - f.y, false
  if dragTap then dragTap:stop() end
  dragTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp,
  }, function(e)
    if not canvas then
      if dragTap then dragTap:stop(); dragTap = nil end
      return false
    end
    if e:getType() == hs.eventtap.event.types.leftMouseDragged then
      dragged = true
      local p = hs.mouse.absolutePosition()
      local cf = canvas:frame()
      canvas:frame({ x = p.x - dragDX, y = p.y - dragDY, w = cf.w, h = cf.h })
    else
      dragTap:stop(); dragTap = nil
      local cf = canvas:frame()
      hs.settings.set("cr.keys.pos", { x = cf.x, y = cf.y })
      log.append({ event = "keys.moved", x = math.floor(cf.x), y = math.floor(cf.y) })
    end
    return false -- never swallow: other apps still need these events
  end)
  dragTap:start()
end

local function palette()
  if hs.host.interfaceStyle() == "Dark" then
    return {
      bg = { hex = "#12131A", alpha = 0.93 }, stroke = { white = 1, alpha = 0.12 },
      head = { hex = "#7AA2F7" }, key = { hex = "#E6E9F2" }, label = { hex = "#9AA0B2" },
      on = { hex = "#9ECE6A" }, off = { white = 1, alpha = 0.22 },
    }
  end
  return {
    bg = { hex = "#FFFFFF", alpha = 0.97 }, stroke = { white = 0, alpha = 0.14 },
    head = { hex = "#2B5FD9" }, key = { hex = "#1F2430" }, label = { hex = "#6B7280" },
    on = { hex = "#4E8C2F" }, off = { white = 0, alpha = 0.20 },
  }
end

-- Chords come from cr.hotkeys, never from a copy kept here. They are
-- user-editable now, so a hardcoded list would start printing chords that no
-- longer work — a cheatsheet that lies is worse than none.
--
-- Built at render time rather than declared once, because the state column is
-- half the value. `state` is nil (nothing), true/false (dot), or a string.
local function rows()
  local ok, screenText = pcall(require, "cr.screen_text")
  local okV, capture = pcall(require, "cr.capture")
  local okS, suggestions = pcall(require, "cr.suggestions")
  local okH, hotkeys = pcall(require, "cr.hotkeys")
  local watching = ok and screenText.watching or false
  -- which of the three capture modes is live, spelled out — a dot could only
  -- say on/off, and "off" and "wake word" are very different situations
  local mode = okV and capture.label() or nil
  local queued = okS and #suggestions.inbox or 0

  local state = {
    voice = mode,
    watch = watching,
    review = queued > 0 and tostring(queued) or nil,
  }
  local after = { voice = true, viewer = true }  -- separator follows these

  local out = {}
  if not okH then
    return { { label = "hotkeys unavailable", chord = "check the Hammerspoon console" } }
  end
  -- the spoken path has no chord, so it is stated rather than bound
  local list = hotkeys.list()
  for i, b in ipairs(list) do
    -- "hold" has to be visible: pressing and releasing a hold binding does
    -- nothing useful, so a cheatsheet that prints it like every other chord is
    -- telling you something that won't work.
    local chord = b.hold and ("hold " .. b.chord) or b.chord
    out[#out + 1] = { label = b.label, chord = chord, state = state[b.id] }
    if after[b.id] and i < #list then out[#out + 1] = { sep = true } end
  end
  return out
end

local function render()
  if not canvas then return end
  local pal, list = palette(), rows()
  while #canvas > 0 do canvas:removeElement(1) end

  canvas[#canvas + 1] = {
    id = "bg", type = "rectangle", action = "strokeAndFill",
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
    fillColor = pal.bg, strokeColor = pal.stroke, strokeWidth = 1,
    trackMouseDown = true, trackMouseUp = true,
  }
  canvas[#canvas + 1] = {
    type = "text", text = "Contextual Reminders", textSize = 11.5,
    textColor = pal.head, frame = { x = PAD, y = PAD - 3, w = W - PAD * 2 - 60, h = 16 },
  }
  canvas[#canvas + 1] = {
    type = "text", text = "drag to move", textSize = 9.5, textColor = pal.off,
    textAlignment = "right",
    frame = { x = W - PAD - 70, y = PAD - 1, w = 70, h = 14 },
  }

  local y = PAD + 27
  for _, r in ipairs(list) do
    if r.sep then
      canvas[#canvas + 1] = {
        type = "rectangle", action = "fill", fillColor = pal.stroke,
        frame = { x = PAD, y = y - 8, w = W - PAD * 2, h = 1 },
      }
      y = y + 9
    else
      -- action first (what you want), chord underneath (how to get it)
      canvas[#canvas + 1] = {
        type = "text", text = r.label, textSize = 12, textColor = pal.key,
        frame = { x = PAD, y = y, w = W - PAD * 2 - 20, h = 16 },
      }
      canvas[#canvas + 1] = {
        type = "text", text = r.chord, textSize = 10, textColor = pal.label,
        frame = { x = PAD, y = y + 15, w = W - PAD * 2 - 20, h = 14 },
      }
      if r.state ~= nil then
        if type(r.state) == "string" then
          canvas[#canvas + 1] = {
            type = "text", text = r.state, textSize = 10.5, textColor = pal.on,
            textAlignment = "right",
            frame = { x = W - PAD - 24, y = y + 6, w = 24, h = 14 },
          }
        else
          canvas[#canvas + 1] = {
            type = "circle", action = "fill",
            fillColor = r.state and pal.on or pal.off,
            center = { x = W - PAD - 5, y = y + 13 }, radius = 3.5,
          }
        end
      end
      y = y + ROW
    end
  end

  local h = y + PAD - 10
  local f = canvas:frame()
  if math.abs(f.h - h) > 1 then
    -- Once you've placed it, the top-left corner is the anchor and only the
    -- height changes. Unplaced, it stays pinned to the bottom-left corner.
    local x, ny
    if savedPos() then
      x, ny = f.x, f.y
    else
      local scr = hs.screen.mainScreen():frame()
      x, ny = scr.x + 16, scr.y + scr.h - h - 16
    end
    x, ny = clampToScreen(x, ny, W, h)
    canvas:frame({ x = x, y = ny, w = W, h = h })
  end
end

function M.show()
  if canvas then canvas:delete() end
  local scr = hs.screen.mainScreen():frame()
  local p = savedPos()
  local x = p and p.x or (scr.x + 16)
  local y = p and p.y or (scr.y + scr.h - 340)
  x, y = clampToScreen(x, y, W, 320)
  canvas = hs.canvas.new({ x = x, y = y, w = W, h = 320 })
  canvas:level("status")
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:mouseCallback(function(_, msg, id)
    if id ~= "bg" then return end
    if msg == "mouseDown" then
      startDrag()
    elseif msg == "mouseUp" and not dragged then
      M.hide() -- a click dismisses; a drag must not, or moving it would close it
    end
  end)
  render()
  canvas:show(0.15)
  M.visible = true
  hs.settings.set("cr.keys", true)
  -- cheap: a dozen text elements, and it makes the state column trustworthy
  if timer then timer:stop() end
  timer = hs.timer.doEvery(2, render)
  log.append({ event = "keys.show" })
end

function M.hide()
  if dragTap then dragTap:stop(); dragTap = nil end
  if timer then timer:stop(); timer = nil end
  if canvas then canvas:hide(0.15); local c = canvas; canvas = nil
    hs.timer.doAfter(0.2, function() c:delete() end)
  end
  M.visible = false
  hs.settings.set("cr.keys", false)
  log.append({ event = "keys.hide" })
end

function M.toggle()
  if M.visible then M.hide() else M.show() end
end

function M.restore()
  if hs.settings.get("cr.keys") then M.show() end
end

return M
