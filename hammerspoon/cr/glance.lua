-- cr.glance — every reminder, on screen, in one keypress.
--
-- The dashboard is a browser tab: fine for reviewing, useless for the actual
-- question, which is "what am I on the hook for?" asked twenty times a day
-- mid-task. Anything that costs a context switch to answer doesn't get asked,
-- and a reminder you never check is a reminder you don't trust.
--
-- So: command + option + shift + R, glance, press again. Same panel language
-- as the hotkey cheatsheet — a corner, draggable, position remembered.
--
-- Read-only on purpose. Acting on a reminder means Done / Snooze / Too early,
-- and those decisions belong on the card that fires or in the dashboard, where
-- there's room to see what you're deciding about. This answers one question.

local log = require("cr.log")

local M = { visible = false }

local canvas, timer
local dragTap, dragDX, dragDY, dragged
local W, PAD, ROW = 330, 16, 40

local function savedPos()
  local p = hs.settings.get("cr.glance.pos")
  if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then return p end
  return nil
end

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

local function palette()
  if hs.host.interfaceStyle() == "Dark" then
    return {
      bg = { hex = "#12131A", alpha = 0.95 }, stroke = { white = 1, alpha = 0.12 },
      head = { hex = "#7AA2F7" }, text = { hex = "#E6E9F2" }, dim = { hex = "#8A90A2" },
      soon = { hex = "#E0AF68" }, crit = { hex = "#F7768E" }, ok = { hex = "#9ECE6A" },
      rule = { white = 1, alpha = 0.08 },
    }
  end
  return {
    bg = { hex = "#FFFFFF", alpha = 0.98 }, stroke = { white = 0, alpha = 0.14 },
    head = { hex = "#2B5FD9" }, text = { hex = "#1F2430" }, dim = { hex = "#6B7280" },
    soon = { hex = "#C77D1A" }, crit = { hex = "#D64560" }, ok = { hex = "#4E8C2F" },
    rule = { white = 0, alpha = 0.08 },
  }
end

-- The left column answers "when", so a column of these scans as a schedule
-- rather than as prose you have to read to find the clock.
local function whenFor(r)
  if r.dueAt then
    local left = r.dueAt - os.time()
    local clock = (os.date("%I:%M", r.dueAt):gsub("^0", "")) .. os.date("%p", r.dueAt):lower()
    local rel
    if left <= 0 then rel = "now"
    elseif left < 90 then rel = left .. "s"
    elseif left < 5400 then rel = math.floor(left / 60 + 0.5) .. " min"
    elseif left < 129600 then rel = string.format("%.0f hr", left / 3600)
    else rel = math.floor(left / 86400 + 0.5) .. "d" end
    if os.date("%x", r.dueAt) ~= os.date("%x") then
      clock = os.date("%a ", r.dueAt) .. clock
    end
    return clock, rel, (left <= 900)
  end
  local map = { pending = "waiting", armed = "watching", cooldown = "watching",
                ready = "any moment", fired = "reminded" }
  return map[r.state] or r.state, nil, false
end

local function truncate(s, n)
  s = s or ""
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

local function render()
  if not canvas then return end
  local reminders = require("cr.reminders")
  local tier = require("cr.tier")
  local pal = palette()

  local list = {}
  for _, r in ipairs(reminders.active()) do list[#list + 1] = r end
  -- loudest first, then soonest: what can hurt you is always at the top
  table.sort(list, function(a, b)
    local ta, tb = a.tier or 2, b.tier or 2
    if ta ~= tb then return ta < tb end
    return (a.dueAt or math.huge) < (b.dueAt or math.huge)
  end)

  while #canvas > 0 do canvas:removeElement(1) end
  local h = PAD + 22 + math.max(#list, 1) * ROW + PAD - 8

  canvas[#canvas + 1] = {
    id = "bg", type = "rectangle", action = "strokeAndFill",
    roundedRectRadii = { xRadius = 13, yRadius = 13 },
    fillColor = pal.bg, strokeColor = pal.stroke, strokeWidth = 1,
    trackMouseDown = true, trackMouseUp = true,
  }
  canvas[#canvas + 1] = {
    type = "text", text = "Reminders", textSize = 11.5, textColor = pal.head,
    frame = { x = PAD, y = PAD - 4, w = W - PAD * 2 - 60, h = 16 },
  }
  canvas[#canvas + 1] = {
    type = "text", text = (#list == 0 and "none" or tostring(#list)),
    textSize = 10.5, textColor = pal.dim, textAlignment = "right",
    frame = { x = W - PAD - 60, y = PAD - 3, w = 60, h = 14 },
  }

  local y = PAD + 22
  if #list == 0 then
    canvas[#canvas + 1] = {
      type = "text", text = "Nothing on your plate.", textSize = 12,
      textColor = pal.dim, frame = { x = PAD, y = y + 6, w = W - PAD * 2, h = 18 },
    }
  end

  for i, r in ipairs(list) do
    if i > 1 then
      canvas[#canvas + 1] = {
        type = "rectangle", action = "fill", fillColor = pal.rule,
        frame = { x = PAD, y = y - 5, w = W - PAD * 2, h = 1 },
      }
    end
    local top, rel, soon = whenFor(r)
    local crit = (r.tier or 2) == tier.CRITICAL
    canvas[#canvas + 1] = {
      type = "text", text = top, textSize = 11.5,
      textColor = crit and pal.crit or (soon and pal.soon or pal.dim),
      textAlignment = "right",
      frame = { x = PAD, y = y + 1, w = 74, h = 15 },
    }
    if rel then
      canvas[#canvas + 1] = {
        type = "text", text = rel, textSize = 9.5, textColor = pal.dim,
        textAlignment = "right",
        frame = { x = PAD, y = y + 16, w = 74, h = 13 },
      }
    end
    canvas[#canvas + 1] = {
      type = "text", text = truncate(r.text, 34), textSize = 13, textColor = pal.text,
      frame = { x = PAD + 84, y = y, w = W - PAD * 2 - 84, h = 18 },
    }
    -- Where it's bound only matters when the binding is the trigger — and
    -- "why hasn't it fired" matters more than "what is it bound to", since the
    -- binding is visible in the reminder's own words and the countdown isn't.
    -- Falls back to the binding when there's nothing to explain.
    local sub = require("cr.reminders").waiting(r)
      or (not r.dueAt and r.referent and r.referent.label)
    if sub then
      canvas[#canvas + 1] = {
        type = "text", text = truncate(sub, 46), textSize = 9.5,
        textColor = pal.dim,
        frame = { x = PAD + 84, y = y + 18, w = W - PAD * 2 - 84, h = 13 },
      }
    end
    y = y + ROW
  end

  local f = canvas:frame()
  if math.abs(f.h - h) > 1 then
    local x, ny = f.x, f.y
    if not savedPos() then
      local scr = hs.screen.mainScreen():frame()
      x, ny = scr.x + scr.w - W - 20, scr.y + 40
    end
    x, ny = clampToScreen(x, ny, W, h)
    canvas:frame({ x = x, y = ny, w = W, h = h })
  end
end

-- Same short-lived tap as the cheatsheet: created on mouse down, destroyed on
-- mouse up. A permanent eventtap in this config starves on OCR captures and
-- drops keystrokes system-wide; one that lives for a drag cannot.
local function startDrag()
  if not canvas then return end
  local f, m = canvas:frame(), hs.mouse.absolutePosition()
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
      local p, cf = hs.mouse.absolutePosition(), canvas:frame()
      canvas:frame({ x = p.x - dragDX, y = p.y - dragDY, w = cf.w, h = cf.h })
    else
      dragTap:stop(); dragTap = nil
      local cf = canvas:frame()
      hs.settings.set("cr.glance.pos", { x = cf.x, y = cf.y })
    end
    return false
  end)
  dragTap:start()
end

function M.show()
  if canvas then canvas:delete() end
  local scr = hs.screen.mainScreen():frame()
  local p = savedPos()
  local x = p and p.x or (scr.x + scr.w - W - 20)
  local y = p and p.y or (scr.y + 40)
  x, y = clampToScreen(x, y, W, 200)
  canvas = hs.canvas.new({ x = x, y = y, w = W, h = 200 })
  canvas:level("status")
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:mouseCallback(function(_, msg, id)
    if id ~= "bg" then return end
    if msg == "mouseDown" then startDrag()
    elseif msg == "mouseUp" and not dragged then M.hide() end
  end)
  render()
  canvas:show(0.12)
  M.visible = true
  -- countdowns go stale fast; a glance panel showing "in 5 min" ten minutes
  -- later is worse than not showing a time at all
  if timer then timer:stop() end
  timer = hs.timer.doEvery(5, render)
  log.append({ event = "glance.show" })
end

function M.hide()
  if dragTap then dragTap:stop(); dragTap = nil end
  if timer then timer:stop(); timer = nil end
  if canvas then
    local c = canvas; canvas = nil
    c:hide(0.12)
    hs.timer.doAfter(0.15, function() c:delete() end)
  end
  M.visible = false
end

function M.toggle()
  if M.visible then M.hide() else M.show() end
end

return M
