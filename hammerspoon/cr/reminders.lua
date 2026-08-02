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
local watchfor = require("cr.watchfor")
local tier = require("cr.tier")
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
  -- Conditions come in two kinds and they are handled by different modules:
  -- cr.condition covers conditions about *you* ("once I'm done with this"),
  -- which map onto window presence; cr.watchfor covers conditions about the
  -- *world* ("after the tests run"), which map onto text on screen changing
  -- state. They are disjoint by construction, so watchfor is only consulted
  -- when the first found nothing.
  local watch
  if not cond then
    watch = watchfor.parse(text)
    if watch then text = watch.task end
  end
  local clean, dueAt, phrase = timeparse.extract(text)
  dueAt = dueAt or opts.dueAt
  if phrase then text = clean end

  local ref = matcher.bind(snap)
  if not ref then
    if dueAt then
      -- timed reminders don't need a screen referent; record where it was set
      ref = { kind = "time", label = "anywhere", boundAt = os.time() }
    elseif watch then
      -- a content condition watches text, not a window: the subject is the
      -- referent, and it can be satisfied in any app that shows it
      ref = { kind = "content", label = watch.subject, boundAt = os.time() }
    else
      log.append({ event = "reminder.rejected", reason = "no bindable context", text = text })
      return nil
    end
  end
  -- Screen-bound reminders open at "in context"; the words can override that
  -- in either direction. See cr.tier — this is an opening position, not a
  -- verdict; the tier moves as consequence gets nearer or context arrives.
  local isBound = ref.kind ~= "time"
  local tr, trWhy = tier.classify(text, isBound)

  local r = {
    id = string.format("r%d%03d", os.time(), math.random(999)),
    text = text,
    createdAt = os.time(),
    tier = tr,
    tierInitial = tr,
    tierWhy = trWhy,
    referent = ref,
    dueAt = dueAt,            -- epoch; nil for purely contextual reminders
    whenPhrase = phrase,      -- the words the time came from, verbatim
    condPhrase = cond,        -- the words the screen condition came from
    -- a content condition. seenPending starts false on purpose: it is what
    -- makes this edge-triggered, so last run's "12 passed" still on screen
    -- cannot satisfy a condition you just created.
    watchFor = watch and { subject = watch.subject, phrase = watch.phrase,
                           seenPending = false } or nil,
    channels = opts.channels or { "card" }, -- default: notification on this Mac
    via = opts.via,
    -- timed reminders fire on the clock; deictic ones are usually born ARMED
    -- (the thing is on screen right now), else PENDING until first sighting
    -- a content condition always starts pending: it must see the subject
    -- running before it can see it finish
    state = dueAt and "scheduled"
      or (watch and "pending")
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
    { "attention", string.format("%s — %s (%s)",
        tier.LABEL[r.tier].name, tier.LABEL[r.tier].note, r.tierWhy) },
    { "delivery", table.concat(r.channels or { "card" }, " + ") },
  })
  return r
end

-- Confirmation, in the same corner and the same visual language as the
-- reminders themselves — an hs.alert in the middle of the screen was a
-- different-looking object saying a related thing, which reads as a system
-- message rather than as "here is your reminder". Auto-dismisses: this is a
-- receipt, not something to answer, and only reminders earn a sticky card.
function M.confirm(r)
  local tier = require("cr.tier")
  local when = r.dueAt and (timeparse.fmtDue(r.dueAt) or "")
    or (r.state == "pending"
        and ("waits for " .. (r.referent and r.referent.label or "it") .. " to appear")
        or ("when you're done with " .. (r.referent and r.referent.label or "this")))
  ui.show({
    title = "Reminder created · " .. (os.date("%I:%M %p"):gsub("^0", "")),
    lead  = r.text,
    body  = string.format("%s\n%s · %s", when,
              tier.LABEL[r.tier or 2].name,
              table.concat(r.channels or { "card" }, " + ")),
    icon = "✅",
    urgency = "success",
    duration = 5,
  })
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

-- Why this reminder has not fired yet, in one short line.
--
-- This is the fix for the most expensive invisible state in the system: a
-- reminder one check away from firing and a reminder that resets every time you
-- glance back look *identical* from outside. Both just sit there. The FSM knows
-- the difference — it is counting consecutive absent samples — but that count
-- never left the event log, so "why hasn't this fired?" could only be answered
-- by reading state transitions, which is not a thing anyone should have to do.
--
-- Shared by the glance panel and the dashboard so the two cannot drift.
function M.waiting(r)
  local cfg = config.trigger or {}
  local need = cfg.absentSamples or 6
  if r.dueAt and (r.state == "scheduled" or r.state == "snoozed") then
    return nil  -- the clock already answers this; whenFor shows it
  end
  local where = r.referent and r.referent.label or "it"
  if r.state == "pending" then
    return "waiting for " .. where .. " to appear"
  elseif r.state == "armed" then
    return "watching " .. where .. " — you're still on it"
  elseif r.state == "cooldown" then
    local n = r.absent or 0
    return string.format("you left %s · %d of %d checks away", where, n, need)
  elseif r.state == "ready" then
    return "ready — waiting for a natural break"
  end
  return nil
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

  -- Just the question. Nothing about what it's binding to, because that answer
  -- arrives a second later on the confirmation card, where reading it is free —
  -- and putting it here made you read a window title before you could type.
  -- The only case worth a word is having nothing to bind to at all, since then
  -- what you type has to change.
  local message = snap and ""
    or "Nothing on screen to attach this to — include a time."

  local button, text = hs.dialog.textPrompt(
    "What do you want to be reminded of?",
    message,
    "", "Remind me", "Cancel")
  if button ~= "Remind me" or not text or text == "" then return end
  local r = M.add(text, snap, { via = "hotkey" })
  if r then
    M.confirm(r)
  else
    ui.show({ title = "Not created", lead = text,
              body = "Nothing on screen to attach it to — try adding a time.",
              icon = "⚠️", urgency = "warn", duration = 5 })
  end
end

return M
