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
local timeparse = require("cr.timeparse")
local condition = require("cr.condition")
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

-- opts: { dueAt, channels, via } — all optional. A time expression inside the
-- text ("… in 5 minutes", "… at 3pm") is extracted here so every creation
-- path — voice, hotkey, suggestion accept — understands time the same way.
function M.add(text, snap, opts)
  opts = opts or {}
  local original = text   -- kept verbatim for the decision log
  -- the trigger clause is not part of the task: strip it, keep it for the log
  local body, cond = condition.extract(text)
  if cond then text = body end
  local clean, dueAt, phrase = timeparse.extract(text)
  dueAt = dueAt or opts.dueAt
  if phrase then text = clean end

  local ref = matcher.bind(snap)
  if not ref then
    if dueAt then
      -- timed reminders don't need a screen referent; record where it was set
      ref = { kind = "time", label = "anywhere", boundAt = os.time() }
    else
      log.append({ event = "reminder.rejected", reason = "no bindable context", text = text })
      return nil
    end
  end
  local r = {
    id = string.format("r%d%03d", os.time(), math.random(999)),
    text = text,
    createdAt = os.time(),
    referent = ref,
    dueAt = dueAt,            -- epoch; nil for purely contextual reminders
    whenPhrase = phrase,      -- the words the time came from, verbatim
    condPhrase = cond,        -- the words the screen condition came from
    channels = opts.channels or { "card" }, -- default: notification on this Mac
    via = opts.via,
    -- timed reminders fire on the clock; deictic ones are usually born ARMED
    -- (the thing is on screen right now), else PENDING until first sighting
    state = dueAt and "scheduled"
      or (matcher.matches(ref, snap) and "armed" or "pending"),
    absent = 0,
  }
  M.items[#M.items + 1] = r
  M.persist()
  log.append({
    event = "reminder.created", id = r.id, text = text, via = opts.via,
    state = r.state, referent = ref.label, dueAt = dueAt, channels = r.channels,
  })

  -- the readable half: how the sentence became a time, or why it didn't
  local why = require("cr.why")
  why.note("reminder created", r.text, {
    { "heard", string.format('"%s"  (%s)', original, opts.via or "?") },
    { "created at", os.date("%I:%M:%S %p", r.createdAt):gsub("^0", "") },
    dueAt
      and { "time", string.format('matched "%s" → triggers %s',
              phrase or "?", timeparse.fmtDue(dueAt)) }
      or  { "time", "no time phrase found → this one waits on context, not the clock" },
    cond and { "condition", string.format('you said "%s" → resolved to what was on screen: %s',
      cond, ref.label or "?") } or nil,
    dueAt
      and { "place", "not used — a timed reminder fires wherever you are" }
      or  { "place", "bound to " .. (ref.label or "?")
              .. " · fires once you're done with it" },
    { "delivery", table.concat(r.channels or { "card" }, " + ") },
  })
  return r
end

-- One-line summary of when/where/how a reminder will surface — shared by the
-- voice toast, the hotkey toast, and logs so every path tells the same story.
function M.describe(r)
  local parts = {}
  if r.dueAt then
    parts[#parts + 1] = "⏰ " .. (timeparse.fmtDue(r.dueAt) or "")
    parts[#parts + 1] = "📍 set from " .. (r.referent and r.referent.label or "?")
  elseif r.state == "pending" then
    parts[#parts + 1] = "⏳ arms on first sighting"
    parts[#parts + 1] = "📍 " .. (r.referent and r.referent.label or "?")
  else
    parts[#parts + 1] = "👁 fires when you're done with"
    parts[#parts + 1] = "📍 " .. (r.referent and r.referent.label or "?")
  end
  parts[#parts + 1] = "📣 " .. table.concat(r.channels or { "card" }, "+")
  return table.concat(parts, " · ")
end

function M.setChannels(id, channels)
  local r = M.get(id)
  if not r or type(channels) ~= "table" or #channels == 0 then return false end
  r.channels = channels
  M.persist()
  log.append({ event = "reminder.channels", id = id, channels = channels })
  return true
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
    'Fires when you\'re done with THIS — or add a time ("… in 5 minutes", "… at 3pm").\n\nTHIS = ' .. boundTo,
    "", "Remind me", "Cancel")
  if button ~= "Remind me" or not text or text == "" then return end
  local r = M.add(text, snap, { via = "hotkey" })
  if r then
    ui.toast('"' .. r.text .. '" — ' .. M.describe(r), 3.2)
  else
    ui.toast("⚠️ Nothing bindable on screen — reminder not created", 2.2)
  end
end

return M
