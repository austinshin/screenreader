-- cr.listening — the live transcription HUD.
--
-- Speaking into a room and getting silence back is the worst moment in a voice
-- interface: you cannot tell whether it is deaf, thinking, or already wrong,
-- so you repeat yourself, which produces a second reminder. A mic indicator in
-- a menu bar answers "is the mic on" — the question is actually "did it hear
-- *me*, and did it hear me *right*", and only showing the words answers that.
--
-- Three states, deliberately distinct so the answer is legible at a glance:
--
--   listening   wake word heard, no command yet — "I'm yours, keep going"
--   capturing   a command is forming — shows the parsed task and time as they
--               resolve, so a misheard word is visible *before* it is saved
--   created     what was saved, then fades
--
-- Bottom-centre, because that's where the eye already is for dictation, and
-- because the top-right corner belongs to the reminder cards.

local config = require("cr.config")

local M = { state = nil }

local canvas, hideTimer
local W = 460

local function palette()
  if hs.host.interfaceStyle() == "Dark" then
    return {
      bg = { hex = "#14151D", alpha = 0.95 }, stroke = { white = 1, alpha = 0.14 },
      dim = { hex = "#8A90A2" }, text = { hex = "#E9ECF5" },
      live = { hex = "#7AA2F7" }, ok = { hex = "#9ECE6A" },
    }
  end
  return {
    bg = { hex = "#FFFFFF", alpha = 0.98 }, stroke = { white = 0, alpha = 0.14 },
    dim = { hex = "#6B7280" }, text = { hex = "#161821" },
    live = { hex = "#3B6FE0" }, ok = { hex = "#4E8C2F" },
  }
end

local function ensure(h)
  local scr = hs.screen.mainScreen():frame()
  if not canvas then
    canvas = hs.canvas.new({ x = scr.x + (scr.w - W) / 2, y = scr.y + scr.h - h - 90,
                             w = W, h = h })
    canvas:level("status")
    canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
    canvas:clickActivating(false)
    canvas:show(0.12)
  else
    local f = canvas:frame()
    canvas:frame({ x = f.x, y = scr.y + scr.h - h - 90, w = W, h = h })
  end
end

-- heard: the raw transcript so far. task/when: the parsed result, once there
-- is one. Showing both is the point — the raw line is what it heard, the
-- parsed line is what it understood, and they are different failures.
local function render(status, heard, task, when, done)
  local pal = palette()
  local pad = 16
  local hasParse = task ~= nil and task ~= ""
  local h = pad + 18 + (heard and 34 or 0) + (hasParse and 40 or 0) + pad - 4
  ensure(h)
  while #canvas > 0 do canvas:removeElement(1) end

  canvas[#canvas + 1] = {
    type = "rectangle", action = "strokeAndFill",
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
    fillColor = pal.bg, strokeColor = pal.stroke, strokeWidth = 1,
  }
  -- a dot that is filled while listening and hollow once saved
  canvas[#canvas + 1] = {
    type = "circle", action = "fill",
    fillColor = done and pal.ok or pal.live,
    center = { x = pad + 5, y = pad + 6 }, radius = 4.5,
  }
  canvas[#canvas + 1] = {
    type = "text", text = status, textSize = 11.5,
    textColor = done and pal.ok or pal.live,
    frame = { x = pad + 18, y = pad - 3, w = W - pad * 2 - 18, h = 16 },
  }

  local y = pad + 18
  if heard then
    local shown = heard
    if #shown > 96 then shown = "…" .. shown:sub(#shown - 93) end
    canvas[#canvas + 1] = {
      type = "text", text = '"' .. shown .. '"', textSize = 13, textColor = pal.dim,
      frame = { x = pad, y = y, w = W - pad * 2, h = 32 },
    }
    y = y + 34
  end
  if hasParse then
    canvas[#canvas + 1] = {
      type = "text", text = "→ " .. task, textSize = 15, textColor = pal.text,
      frame = { x = pad, y = y, w = W - pad * 2, h = 20 },
    }
    if when then
      canvas[#canvas + 1] = {
        type = "text", text = "   " .. when, textSize = 11.5, textColor = pal.dim,
        frame = { x = pad, y = y + 20, w = W - pad * 2, h = 16 },
      }
    end
  end
end

local function autoHide(secs)
  if hideTimer then hideTimer:stop() end
  hideTimer = hs.timer.doAfter(secs, function() M.hide() end)
end

-- wake word heard, nothing said yet
function M.listening()
  if config.voice and config.voice.hud == false then return end
  M.state = "listening"
  render("listening…", nil, nil, nil, false)
  autoHide(12)   -- a wake word with no command shouldn't leave a panel up
end

-- transcript growing; task/when are nil until they parse
function M.capturing(heard, task, when)
  if config.voice and config.voice.hud == false then return end
  M.state = "capturing"
  render(task and "heard you" or "listening…", heard, task, when, false)
  autoHide(12)
end

function M.created(task, when)
  if config.voice and config.voice.hud == false then return end
  M.state = "created"
  render("saved", nil, task, when, true)
  autoHide(2.6)
end

function M.rejected(reason)
  if config.voice and config.voice.hud == false then return end
  M.state = "rejected"
  render(reason or "didn't catch that", nil, nil, nil, false)
  autoHide(2.2)
end

function M.hide()
  if hideTimer then hideTimer:stop(); hideTimer = nil end
  M.state = nil
  if canvas then
    local c = canvas; canvas = nil
    c:hide(0.15)
    hs.timer.doAfter(0.2, function() c:delete() end)
  end
end

return M
