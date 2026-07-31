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

local function fire(r, snap, gate)
  reminders.setState(r, "fired", gate)
  log.append({ event = "trigger.fired", id = r.id, text = r.text, gate = gate })
  notifier.notify(cardFor(r, gate == "time"), { channels = r.channels })
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
      if snap.reason == "app-switch" or snap.reason == "wake" then
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
