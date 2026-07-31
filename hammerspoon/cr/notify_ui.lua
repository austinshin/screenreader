-- cr.notify_ui — custom canvas notification card + toast.
--
-- Why not hs.notify as the primary surface: action buttons only render if the
-- user sets Hammerspoon's notification style to "Alerts" in System Settings,
-- and additionalActions has known glitches. A canvas card guarantees the
-- Done / Snooze / Too early buttons, supports hover-to-pin, and is fully
-- styleable with zero settings dependencies. Trade-off: a missed card doesn't
-- land in Notification Center — the event log and remote channels cover that.

local config = require("cr.config")
local log = require("cr.log")

local M = {}

local active = {} -- live cards, oldest first; new cards stack below

local function palette()
  if hs.host.interfaceStyle() == "Dark" then
    return {
      bg      = { hex = "#1C1D26", alpha = 0.97 },
      stroke  = { white = 1, alpha = 0.10 },
      title   = { hex = "#FFFFFF" },
      body    = { hex = "#B8BCC8" },
      btnBg   = { white = 1, alpha = 0.09 },
      btnText = { hex = "#E6E9F2" },
      accents = { info = { hex = "#7AA2F7" }, warn = { hex = "#E0AF68" }, success = { hex = "#9ECE6A" } },
    }
  end
  return {
    bg      = { hex = "#FFFFFF", alpha = 0.98 },
    stroke  = { white = 0, alpha = 0.12 },
    title   = { hex = "#1A1A1A" },
    body    = { hex = "#555555" },
    btnBg   = { white = 0, alpha = 0.06 },
    btnText = { hex = "#222222" },
    accents = { info = { hex = "#3B6FE0" }, warn = { hex = "#C77D1A" }, success = { hex = "#4E8C2F" } },
  }
end

local function stackOffset()
  local y = 0
  for _, card in ipairs(active) do
    y = y + card.height + 10
  end
  return y
end

-- opts: { title, body, icon, urgency = "info"|"warn"|"success",
--         duration, sticky, actions = { { label, fn }, ... }, onDismiss }
--
-- sticky = true: the card never times out and ignores clicks on its body —
-- only an action button or the ✕ closes it. A fired reminder that vanishes on
-- its own has failed at the one job it had, and the failure is invisible: you
-- can't miss what you never saw. Guesses (suggestions) stay timed, because an
-- offer that won't go away is nagging rather than helpful.
function M.show(opts)
  opts = opts or {}
  local pal = palette()
  local W, pad = config.card.width, 14
  local sticky = opts.sticky or (opts.duration ~= nil and opts.duration <= 0)

  local body = opts.body or ""
  if #body > 180 then body = body:sub(1, 177) .. "…" end
  local lines = math.max(1, math.min(3, math.ceil(#body / 46)))
  local bodyH = lines * 17
  local hasActions = opts.actions and #opts.actions > 0
  local H = pad + 20 + 6 + bodyH + (hasActions and 46 or pad)

  local screen = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({
    x = screen.x + screen.w - W - config.card.margin,
    y = screen.y + config.card.margin + stackOffset(),
    w = W, h = H,
  })

  local card = { canvas = c, height = H, timer = nil, done = false }

  c:level("status")
  c:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)

  c[#c + 1] = {
    id = "bg", type = "rectangle", action = "strokeAndFill",
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
    fillColor = pal.bg, strokeColor = pal.stroke, strokeWidth = 1,
    trackMouseUp = true, trackMouseEnterExit = true,
  }
  c[#c + 1] = {
    type = "rectangle", action = "fill",
    roundedRectRadii = { xRadius = 2, yRadius = 2 },
    fillColor = pal.accents[opts.urgency or "info"] or pal.accents.info,
    frame = { x = 0, y = 12, w = 4, h = H - 24 },
  }
  c[#c + 1] = {
    type = "text", text = opts.icon or "🔔", textSize = 20,
    frame = { x = pad, y = pad - 2, w = 30, h = 28 },
  }
  c[#c + 1] = {
    type = "text", text = opts.title or "", textSize = 14, textColor = pal.title,
    -- leave room for the ✕ when there is one
    frame = { x = pad + 34, y = pad - 1, w = W - pad * 2 - 34 - (sticky and 20 or 0), h = 20 },
  }
  if sticky then
    -- the only way to lose a sticky card without answering it
    c[#c + 1] = {
      id = "close", type = "text", text = "✕", textSize = 13,
      textColor = pal.body, textAlignment = "center", trackMouseUp = true,
      frame = { x = W - pad - 16, y = pad - 1, w = 18, h = 18 },
    }
  end
  c[#c + 1] = {
    type = "text", text = body, textSize = 12.5, textColor = pal.body,
    frame = { x = pad + 34, y = pad + 21, w = W - pad * 2 - 34, h = bodyH + 4 },
  }

  local function dismiss(reasonEvent)
    if card.done then return end
    card.done = true
    if card.timer then card.timer:stop(); card.timer = nil end
    for i, k in ipairs(active) do
      if k == card then table.remove(active, i); break end
    end
    c:hide(0.25)
    hs.timer.doAfter(0.3, function() c:delete() end)
    if reasonEvent then log.append({ event = reasonEvent, title = opts.title }) end
    if opts.onDismiss then pcall(opts.onDismiss, reasonEvent) end
  end
  card.dismiss = dismiss

  local actionFns = {}
  if hasActions then
    local bx = W - pad
    for i = #opts.actions, 1, -1 do
      local a = opts.actions[i]
      local bw = 26 + math.floor(7.2 * #a.label)
      bx = bx - bw
      local id = "btn" .. i
      c[#c + 1] = {
        id = id, type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        fillColor = pal.btnBg, trackMouseUp = true,
        frame = { x = bx, y = H - 40, w = bw, h = 28 },
      }
      c[#c + 1] = {
        id = id .. "t", type = "text", text = a.label, textSize = 12,
        textColor = pal.btnText, textAlignment = "center", trackMouseUp = true,
        frame = { x = bx, y = H - 40 + 6, w = bw, h = 18 },
      }
      actionFns[id], actionFns[id .. "t"] = a, a
      bx = bx - 8
    end
  end

  c:mouseCallback(function(_, msg, id)
    if msg == "mouseEnter" then
      -- hover pins the card
      if card.timer then card.timer:stop(); card.timer = nil end
    elseif msg == "mouseExit" then
      if not sticky and not card.done and not card.timer then
        card.timer = hs.timer.doAfter(3, function() dismiss("card.timeout") end)
      end
    elseif msg == "mouseUp" then
      local a = actionFns[id]
      if a then
        log.append({ event = "card.action", label = a.label, title = opts.title })
        if a.fn then pcall(a.fn) end
        dismiss(nil)
      elseif id == "close" then
        dismiss("card.closed")
      elseif id == "bg" and not sticky then
        -- a body click closes a passing card, but must not silently discard a
        -- sticky one: answering it is the whole point
        dismiss("card.dismissed")
      end
    end
  end)

  active[#active + 1] = card
  c:show(0.2)
  if not sticky then
    card.timer = hs.timer.doAfter(opts.duration or config.card.duration,
      function() dismiss("card.timeout") end)
  end
  return card
end

-- brief centered confirmation flash (e.g. echo after creating a reminder)
function M.toast(text, secs)
  hs.alert.show(text, { radius = 10, textSize = 15 }, hs.screen.mainScreen(), secs or 1.6)
end

-- how many cards are on screen right now (smoke tests, `hs -c`, debugging)
function M.activeCount()
  return #active
end

function M.dismissAll()
  local guard = 0
  while #active > 0 and guard < 20 do
    guard = guard + 1
    active[#active].dismiss("card.dismissed")
  end
end

return M
