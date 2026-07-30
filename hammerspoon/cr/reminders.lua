-- cr.reminders — reminder store + input flow.
--
-- v1 input is one sentence shape: "remind me <text> when I'm done with THIS",
-- where THIS is whatever the observer last saw before the prompt opened.
-- Reminders persist to data/reminders.json so hs.reload() (frequent during
-- dev) never loses state.

local config = require("cr.config")
local log = require("cr.log")
local matcher = require("cr.matcher")
local observer = require("cr.observer")
local ui = require("cr.notify_ui")

local M = { items = {} }

local function dataDir()
  return (config.projectDir or os.getenv("HOME")) .. "/data"
end

local function dataPath()
  return dataDir() .. "/reminders.json"
end

function M.persist()
  hs.fs.mkdir(dataDir())
  local ok, blob = pcall(hs.json.encode, { items = M.items }, true)
  if not ok then return end
  local f = io.open(dataPath(), "w")
  if f then f:write(blob); f:close() end
end

function M.load()
  local f = io.open(dataPath(), "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if ok and type(data) == "table" and type(data.items) == "table" then
    M.items = data.items
    log.append({ event = "reminders.loaded", count = #M.items })
  end
end

function M.add(text, snap)
  local ref = matcher.bind(snap)
  if not ref then
    log.append({ event = "reminder.rejected", reason = "no bindable context", text = text })
    return nil
  end
  local r = {
    id = string.format("r%d%03d", os.time(), math.random(999)),
    text = text,
    createdAt = os.time(),
    referent = ref,
    -- deictic reminders are usually born ARMED (the thing is on screen right
    -- now); if it isn't visible, born PENDING and armed on first sighting
    state = matcher.matches(ref, snap) and "armed" or "pending",
    absent = 0,
  }
  M.items[#M.items + 1] = r
  M.persist()
  log.append({
    event = "reminder.created", id = r.id, text = text,
    state = r.state, referent = ref.label,
  })
  return r
end

function M.setState(r, state, extra)
  local prev = r.state
  r.state = state
  M.persist()
  log.append({ event = "reminder.state", id = r.id, from = prev, to = state, text = r.text, extra = extra })
end

function M.active()
  local out = {}
  for _, r in ipairs(M.items) do
    if r.state ~= "done" and r.state ~= "cancelled" then out[#out + 1] = r end
  end
  return out
end

function M.get(id)
  for _, r in ipairs(M.items) do
    if r.id == id then return r end
  end
end

-- Input flow. The referent comes from the observer's LAST snapshot, captured
-- before the dialog opens — the dialog steals focus, and the dialog itself
-- must never become "this".
function M.promptNew()
  local snap = observer.current
  local boundTo = snap
    and ((snap.app or "?") .. " — " .. (snap.tab or snap.title or snap.url or "untitled"))
    or "nothing (observer has no context yet)"
  local button, text = hs.dialog.textPrompt(
    "New contextual reminder",
    'When you\'re done with THIS, you get reminded.\n\nTHIS = ' .. boundTo,
    "", "Watch it", "Cancel")
  if button ~= "Watch it" or not text or text == "" then return end
  local r = M.add(text, snap)
  if r then
    ui.toast((r.state == "armed" and "👁 Watching: " or "⏳ Will arm on first sighting: ")
      .. r.referent.label, 2.2)
  else
    ui.toast("⚠️ Nothing bindable on screen — reminder not created", 2.2)
  end
end

return M
