-- cr.viewer — live OCR viewer panel.
--
-- A toggleable always-on-screen HUD showing what the OCR actually read: the
-- most recent capture's text, its source, mode, timing, and paging through
-- recent history. This is the transparency surface for a tool that reads your
-- screen — "what does it see?" should never require opening a log file.
--
-- Toggle: ⌃⌥⌘V or menu bar. Sticky via hs.settings (survives reload/reboot).

local config = require("cr.config")
local log = require("cr.log")

local M = { visible = false }

local canvas
local history = {}   -- newest first
local cursor = 1     -- which history entry is displayed
local MAX_HISTORY = 25
local MAX_CHARS = 6000

local function palette()
  if hs.host.interfaceStyle() == "Dark" then
    return {
      bg = { hex = "#12131A", alpha = 0.95 }, stroke = { white = 1, alpha = 0.12 },
      head = { hex = "#7AA2F7" }, meta = { hex = "#8A90A2" },
      body = { hex = "#D5D9E4" }, btn = { white = 1, alpha = 0.10 },
      btnText = { hex = "#E6E9F2" },
    }
  end
  return {
    bg = { hex = "#FFFFFF", alpha = 0.97 }, stroke = { white = 0, alpha = 0.14 },
    head = { hex = "#2B5FD9" }, meta = { hex = "#6B7280" },
    body = { hex = "#1F2430" }, btn = { white = 0, alpha = 0.07 },
    btnText = { hex = "#1F2430" },
  }
end

local function currentEntry()
  return history[cursor]
end

local function render()
  if not canvas then return end
  local pal = palette()
  local e = currentEntry()
  local w = canvas:frame().w
  local h = canvas:frame().h

  -- rebuild elements from scratch: simpler than diffing, cheap at this size
  while #canvas > 0 do canvas:removeElement(1) end

  canvas[#canvas + 1] = {
    id = "bg", type = "rectangle", action = "strokeAndFill",
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
    fillColor = pal.bg, strokeColor = pal.stroke, strokeWidth = 1,
    trackMouseUp = true,
  }

  local title = e
    and string.format("📖 %s  ·  %s", e.mode or "manual", e.source or "?")
    or "📖 OCR viewer — waiting for a capture…"
  canvas[#canvas + 1] = {
    type = "text", text = title, textSize = 12.5, textColor = pal.head,
    textFont = "Menlo-Bold",
    frame = { x = 14, y = 11, w = w - 130, h = 34 },
  }

  local meta = e
    and string.format("%s   %d chars   %dms%s   [%d/%d]",
      e.iso or "", #(e.text or ""), e.ms or 0,
      e.repeats and string.format("   ×%d unchanged", e.repeats) or "",
      cursor, #history)
    or "toggle with ⌃⌥⌘V  ·  captures land in logs/captures/"
  canvas[#canvas + 1] = {
    type = "text", text = meta, textSize = 10.5, textColor = pal.meta,
    textFont = "Menlo",
    frame = { x = 14, y = 44, w = w - 28, h = 16 },
  }

  -- header buttons: ‹ › ✕
  local bx = w - 104
  for _, b in ipairs({ { "prev", "‹" }, { "next", "›" }, { "close", "✕" } }) do
    canvas[#canvas + 1] = {
      id = b[1], type = "rectangle", action = "fill",
      roundedRectRadii = { xRadius = 6, yRadius = 6 }, fillColor = pal.btn,
      trackMouseUp = true, frame = { x = bx, y = 10, w = 28, h = 24 },
    }
    canvas[#canvas + 1] = {
      id = b[1] .. "t", type = "text", text = b[2], textSize = 13,
      textColor = pal.btnText, textAlignment = "center", trackMouseUp = true,
      frame = { x = bx, y = 13, w = 28, h = 20 },
    }
    bx = bx + 32
  end

  canvas[#canvas + 1] = {
    type = "rectangle", action = "fill", fillColor = pal.stroke,
    frame = { x = 14, y = 64, w = w - 28, h = 1 },
  }

  local text = e and (e.text or "") or
    "Nothing captured yet.\n\n⌃⌥⌘S  capture the focused window now\n⌃⌥⌘W  toggle persistent screen watching"
  if #text > MAX_CHARS then text = text:sub(1, MAX_CHARS) .. "\n\n… (truncated)" end
  canvas[#canvas + 1] = {
    type = "text", text = text, textSize = 11, textColor = pal.body,
    textFont = "Menlo",
    frame = { x = 14, y = 72, w = w - 28, h = h - 84 },
  }
end

local function build()
  local scr = hs.screen.mainScreen():frame()
  local w = 430
  local h = math.min(math.floor(scr.h * 0.82), 900)
  canvas = hs.canvas.new({ x = scr.x + 16, y = scr.y + 16, w = w, h = h })
  canvas:level("status")
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:mouseCallback(function(_, msg, id)
    if msg ~= "mouseUp" then return end
    if id == "close" or id == "closet" then
      M.hide()
    elseif id == "prev" or id == "prevt" then
      if cursor < #history then cursor = cursor + 1; render() end
    elseif id == "next" or id == "nextt" then
      if cursor > 1 then cursor = cursor - 1; render() end
    end
  end)
  render()
end

-- called by cr.screen_text after every successful capture
function M.update(entry)
  -- unchanged re-capture: refresh the top entry's timestamp instead of
  -- filling history with identical copies
  if entry.unchanged and history[1] then
    history[1].iso = entry.iso
    history[1].ms = entry.ms
    history[1].repeats = (history[1].repeats or 1) + 1
    if M.visible and cursor == 1 then render() end
    return
  end
  table.insert(history, 1, entry)
  while #history > MAX_HISTORY do table.remove(history) end
  cursor = 1
  if M.visible then render() end
end

function M.show()
  if M.visible then return end
  M.visible = true
  hs.settings.set("cr.viewer", true)
  if not canvas then build() else render() end
  canvas:show(0.15)
  log.append({ event = "viewer.show" })
end

function M.hide()
  if not M.visible then return end
  M.visible = false
  hs.settings.set("cr.viewer", false)
  if canvas then canvas:hide(0.15) end
  log.append({ event = "viewer.hide" })
end

function M.toggle()
  if M.visible then M.hide() else M.show() end
end

function M.restore()
  if hs.settings.get("cr.viewer") then M.show() end
end

return M
