-- cr.menubar — status + manual controls in the menu bar.

local observer = require("cr.observer")
local notifier = require("cr.notifier")
local reminders = require("cr.reminders")
local screenText = require("cr.screen_text")
local viewer = require("cr.viewer")
local suggestions = require("cr.suggestions")
local voice = require("cr.voice")
local keys = require("cr.keys")
local ui = require("cr.notify_ui")
local log = require("cr.log")

local M = {}
local mb

local STATE_ICON = {
  pending = "⏳", armed = "👁", cooldown = "⏱",
  ready = "🕐", fired = "🔔", snoozed = "💤",
}

local function truncate(s, n)
  if not s then return "" end
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

local function showCurrentContext()
  local cur = observer.current or {}
  local body = truncate(cur.title or "", 80)
  if cur.url then body = body .. "\n" .. truncate(cur.url, 80) end
  if cur.media and cur.media.title then
    body = body .. "\n♪ " .. truncate(cur.media.title, 60)
      .. (cur.media.playing and " (playing)" or " (paused)")
  end
  ui.show({
    title = cur.app or "No context yet",
    body = body,
    icon = "🖥",
    urgency = "success",
    actions = { { label = "OK" } },
  })
end
M.showCurrentContext = showCurrentContext

local function reminderRows()
  local rows = {}
  for _, r in ipairs(reminders.active()) do
    rows[#rows + 1] = {
      title = string.format("%s %s", STATE_ICON[r.state] or "·", truncate(r.text, 42)),
      menu = {
        { title = "watching: " .. truncate(r.referent and r.referent.label or "?", 55), disabled = true },
        { title = "state: " .. r.state, disabled = true },
        { title = "-" },
        { title = "Mark done", fn = function()
            reminders.setState(r, "done", "menubar")
            M.refresh()
          end },
        { title = "Cancel", fn = function()
            reminders.setState(r, "cancelled", "menubar")
            M.refresh()
          end },
      },
    }
  end
  return rows
end

local function menu()
  local cur = observer.current
  local ctxLine = cur
    and string.format("%s — %s", cur.app or "?", truncate(cur.title or cur.url or "", 40))
    or "no context yet"
  local status = (observer.running and "👁 observing" or "⏸ paused")
    .. (screenText.watching and " · 📸 auto-OCR" or "")
  local items = {
    { title = "Contextual Reminders", disabled = true },
    { title = status .. "  ·  " .. ctxLine, disabled = true },
    { title = "-" },
    { title = "New reminder…   ⌃⌥⌘N", fn = reminders.promptNew },
    {
      title = screenText.watching
        and "Stop screen watching   ⌃⌥⌘W"
        or "Start screen watching (auto-OCR)   ⌃⌥⌘W",
      fn = screenText.toggleWatch,
    },
    {
      title = (voice.running and "Stop" or "Start") .. " voice (\"hey screenreader…\")   ⌃⌥⌘M",
      fn = voice.toggle,
    },
    {
      title = (viewer.visible and "Hide" or "Show") .. " OCR viewer   ⌃⌥⌘V",
      fn = viewer.toggle,
    },
    -- the discoverable route to the cheatsheet: if you've forgotten the chords,
    -- the one place you'll still look is the menu bar
    {
      title = (keys.visible and "Hide" or "Show") .. " hotkey cheatsheet   ⌃⌥⌘K",
      fn = keys.toggle,
    },
  }
  local rows = reminderRows()
  if #rows > 0 then
    items[#items + 1] = { title = "-" }
    for _, row in ipairs(rows) do items[#items + 1] = row end
  end
  local sugg = suggestions.inboxRows()
  if #sugg > 0 then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Suggestions (" .. #sugg .. ")", disabled = true }
    for _, row in ipairs(sugg) do items[#items + 1] = row end
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = {
    title = observer.running and "Pause observer" or "Resume observer",
    fn = function()
      if observer.running then observer.stop() else observer.start() end
    end,
  }
  items[#items + 1] = { title = "Show current context", fn = showCurrentContext }
  items[#items + 1] = { title = "Send test notification", fn = notifier.test }
  items[#items + 1] = {
    title = "Open logs folder",
    fn = function() hs.execute(string.format("open %q", log.dirPath())) end,
  }
  return items
end

-- badge: ◉ plus the count of non-terminal reminders (◉2)
function M.refresh()
  if not mb then return end
  local n = #reminders.active()
  mb:setTitle(n > 0 and ("◉" .. n) or "◉")
end

function M.start()
  if mb then return end
  mb = hs.menubar.new()
  if not mb then return end
  mb:setTooltip("Contextual Reminders")
  mb:setMenu(menu)
  M.refresh()
end

function M.stop()
  if mb then mb:delete(); mb = nil end
end

return M
