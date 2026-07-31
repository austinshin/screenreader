-- cr.trigger — the per-reminder state machine ("the guard").
--
-- The observer samples a LEVEL (what's on screen); this module detects EDGES
-- (the thing a reminder cares about just ended). Completion conditions are
-- edge-triggered: you must see the activity happening, then see it stop —
-- otherwise "not watching the video" is trivially true and fires instantly.
--
--   PENDING ──seen──▶ ARMED ──absent──▶ COOLDOWN ──absent × N──▶ READY ──gate──▶ FIRED
--                       ▲                  │ present                │ present
--                       └──────────────────┴──────── re-arm ────────┘
--
-- Gates for firing (never mid-focus): an app-switch/wake tick, or a max-wait
-- backstop so a reminder can't sit READY forever.

local config = require("cr.config")
local log = require("cr.log")
local matcher = require("cr.matcher")
local reminders = require("cr.reminders")
local notifier = require("cr.notifier")
local observer = require("cr.observer")
local tier = require("cr.tier")

local M = { running = false }

-- wired by cr.init (e.g. menubar badge refresh); called after any state change
M.onStateChange = nil

local function cfg()
  return config.trigger
end

-- The card for a fired reminder. Built separately from fire() so an unanswered
-- reminder can be put back on screen without re-firing it.
local function cardFor(r, timed)
  local actions = {
    {
      label = "Done",
      fn = function()
        reminders.setState(r, "done", "user")
        log.append({ event = "feedback", value = "done", id = r.id })
      end,
    },
    {
      label = "Snooze",
      fn = function()
        if r.dueAt then
          -- timed reminder: push the clock, back onto the schedule
          r.dueAt = os.time() + cfg().snoozeMinutes * 60
          reminders.setState(r, "scheduled", "snoozed")
        else
          r.snoozeUntil = os.time() + cfg().snoozeMinutes * 60
          reminders.setState(r, "snoozed")
        end
        log.append({ event = "feedback", value = "snooze", id = r.id })
      end,
    },
  }
  if not timed then
    actions[#actions + 1] = {
      label = "Too early",
      fn = function()
        -- the false-positive button: user is NOT done with the thing.
        -- back to PENDING — re-arms on next sighting, full cycle again.
        r.absent = 0
        reminders.setState(r, "pending", "too_early")
        log.append({ event = "feedback", value = "too_early", id = r.id })
      end,
    }
  end
  return {
    title = "Reminder",
    body = r.text,
    icon = "⏰",
    urgency = "info",
    sticky = true, -- waits for an answer; see cr.notify_ui
    meta = { id = r.id, referent = r.referent and r.referent.label },
    actions = actions,
  }
end

-- Why this reminder is arriving at this moment, in the terms the user would
-- use. The two paths have genuinely different answers: a clock reminder fires
-- because a time arrived, a contextual one because it watched an activity end.
local function whyNow(r, snap, gate)
  if gate == "time" then
    local late = os.time() - (r.dueAt or os.time())
    return string.format("the time you set arrived (%s)%s",
      os.date("%I:%M %p", r.dueAt or os.time()):gsub("^0", ""),
      late > 2 and string.format(" — %ds later than set, checked once a second", late) or "")
  end
  local where = r.referent and r.referent.label or "?"
  if gate == "max-wait" then
    return string.format('you left "%s" and stayed away, and nothing interrupted for %ds — '
      .. "fired rather than wait longer", where, cfg().maxReadyWait)
  end
  return string.format('you left "%s" and stayed away for %d checks (~%ds), then %s — '
    .. "waited for that seam so this didn't land mid-task",
    where, cfg().absentSamples, cfg().absentSamples * (config.pollInterval or 5),
    gate == "wake" and "you came back from idle" or "you switched apps")
end

local function fire(r, snap, gate)
  reminders.setState(r, "fired", gate)
  log.append({ event = "trigger.fired", id = r.id, text = r.text, gate = gate,
               tier = r.tier })

  -- Ambient never gets a card. This is the whole point of the tier: something
  -- you asked to "keep an eye on" should be findable, not interruptive, and a
  -- card that must be dismissed is an interruption whatever its contents say.
  -- It still fires and still lands in the dashboard and menu bar.
  if (r.tier or tier.UPCOMING) == tier.AMBIENT then
    log.append({ event = "trigger.silent", id = r.id, reason = "ambient tier" })
    require("cr.why").note("reminder surfaced quietly", r.text, {
      { "why now", whyNow(r, snap, gate) },
      { "attention", "ambient — no card, by design. It's in the dashboard and menu bar." },
    })
    return
  end
  local payload = cardFor(r, gate == "time")
  local chans = r.channels
  if (r.tier or 2) == tier.CRITICAL then
    payload.urgency = "warn"
    payload.icon = "🚨"
    -- critical reaches you wherever you are, not only where it fired
    chans = { "card", "system" }
    for _, c in ipairs(r.channels or {}) do
      if c ~= "card" and c ~= "system" then chans[#chans + 1] = c end
    end
    local s_ = hs.sound.getByName("Sosumi"); if s_ then s_:play() end
  end
  local channels = notifier.notify(payload, { channels = chans })
  require("cr.why").note("reminder fired", r.text, {
    { "why now", whyNow(r, snap, gate) },
    { "set", os.date("%I:%M %p", r.createdAt or os.time()):gsub("^0", "")
        .. (r.whenPhrase and (' from "' .. r.whenPhrase .. '"') or "") },
    { "delivered to", table.concat(channels or r.channels or { "card" }, " + ") },
    { "waiting on", "you — the card stays up until you answer it" },
  })
end

-- A sticky card only survives as long as the process drawing it. Hammerspoon
-- reloads (and reboots), and the reminder underneath stays "fired" with
-- nothing on screen — dismissed by accident rather than by the user. Put those
-- back up on start. Local card only: the remote channels already delivered
-- once, and re-pinging Discord on every reload would be its own bug.
function M.restoreFired()
  local n = 0
  for _, r in ipairs(reminders.active()) do
    if r.state == "fired" then
      n = n + 1
      notifier.notify(cardFor(r, r.dueAt ~= nil), { channels = { "card" } })
    end
  end
  if n > 0 then log.append({ event = "trigger.restored", count = n }) end
end

-- Tier is a property of the reminder *right now*, so it is recomputed rather
-- than remembered. "Take out the trash" is ambient in the afternoon, upcoming
-- in the evening, and critical the night before collection — nothing about the
-- reminder changed except how close the consequence got.
local function retier(r, snap)
  local from = r.tier or tier.UPCOMING
  local to, why = from, nil

  if r.dueAt then
    local left = r.dueAt - os.time()
    if left <= 600 and from > tier.CRITICAL then
      to, why = tier.CRITICAL, "under ten minutes away"
    elseif left <= 3600 and from > tier.UPCOMING then
      to, why = tier.UPCOMING, "within the hour"
    end
  elseif r.referent and from == tier.AMBIENT and matcher.matches(r.referent, snap) then
    -- something you were only tracking is now in front of you
    to, why = tier.INCONTEXT, "the thing it's about is on screen now"
  elseif from == tier.INCONTEXT and r.state == "pending"
      and os.time() - (r.createdAt or os.time()) > 86400 then
    -- a context that hasn't come back in a day isn't going to interrupt well
    to, why = tier.AMBIENT, "its context hasn't appeared in a day"
  end

  if to ~= from then
    r.tier, r.tierWhy = to, why
    r.tierHistory = r.tierHistory or {}
    r.tierHistory[#r.tierHistory + 1] = { t = os.time(), from = from, to = to, why = why }
    reminders.persist()
    log.append({ event = "tier.moved", id = r.id, from = from, to = to, why = why })
    require("cr.why").note(
      to < from and "reminder got louder" or "reminder got quieter", r.text, {
        { "moved", string.format("%s → %s", tier.LABEL[from].name, tier.LABEL[to].name) },
        { "because", why },
        { "now", tier.LABEL[to].note },
      })
    if M.onStateChange then pcall(M.onStateChange) end
  end
end

-- Timed reminders bypass the FSM entirely: they fire on the clock, wherever
-- the user is. Checked every second for demo-friendly precision.
local function checkDue()
  local now = os.time()
  for _, r in ipairs(reminders.active()) do
    if r.state == "scheduled" and r.dueAt and now >= r.dueAt then
      local ok, err = pcall(fire, r, observer.current or {}, "time")
      if not ok then
        log.append({ event = "trigger.error", id = r.id, error = tostring(err) })
      end
      if M.onStateChange then pcall(M.onStateChange) end
    end
  end
end

local function step(r, snap)
  local present = matcher.matches(r.referent, snap)

  if r.state == "pending" then
    if present then
      r.absent = 0
      reminders.setState(r, "armed")
    end

  elseif r.state == "armed" then
    if not present then
      r.absent = 1
      reminders.setState(r, "cooldown")
    end

  elseif r.state == "cooldown" then
    if present then
      -- brief tab-away, not "done" — the debounce doing its job
      r.absent = 0
      reminders.setState(r, "armed", "rearmed")
    else
      r.absent = (r.absent or 0) + 1
      if r.absent >= cfg().absentSamples then
        r.readyAt = os.time()
        reminders.setState(r, "ready")
      end
    end

  elseif r.state == "ready" then
    if present then
      -- came back before we fired: definitely not done
      r.absent = 0
      reminders.setState(r, "armed", "returned")
    else
      local gate
      if tier.bypassesSeamGate(r.tier) then
        -- The one tier allowed to interrupt mid-focus. Everything else waiting
        -- for a natural break is the promise that makes this tolerable to
        -- leave running; critical is the stated exception, not an oversight.
        gate = "critical"
      elseif snap.reason == "app-switch" or snap.reason == "wake" then
        gate = snap.reason
      elseif os.time() - (r.readyAt or 0) >= cfg().maxReadyWait then
        gate = "max-wait"
      end
      if gate then fire(r, snap, gate) end
    end

  elseif r.state == "snoozed" then
    if os.time() >= (r.snoozeUntil or 0) then
      r.readyAt = os.time()
      reminders.setState(r, "ready", "snooze-elapsed")
    end
  end
end

-- Exported for scripted tests and the future replay harness: feed synthetic
-- snapshots through the FSM without waiting for wall-clock time.
function M.tick(snap)
  for _, r in ipairs(reminders.active()) do
    pcall(retier, r, snap)
    local before = r.state
    local ok, err = pcall(step, r, snap)
    if not ok then
      log.append({ event = "trigger.error", id = r.id, error = tostring(err) })
    end
    if r.state ~= before and M.onStateChange then pcall(M.onStateChange) end
  end
end

local dueTimer

function M.start()
  if M.running then return end
  M.running = true
  observer.subscribeTick(M.tick)
  dueTimer = hs.timer.doEvery(1, checkDue)
  log.append({ event = "trigger.start" })
end

return M
