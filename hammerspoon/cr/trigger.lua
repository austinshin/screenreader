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

local function fire(r, snap, gate)
  reminders.setState(r, "fired", gate)
  log.append({ event = "trigger.fired", id = r.id, text = r.text, gate = gate })
  notifier.notify({
    title = "Reminder",
    body = r.text,
    icon = "⏰",
    urgency = "info",
    meta = { id = r.id, referent = r.referent and r.referent.label },
    actions = {
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
          r.snoozeUntil = os.time() + cfg().snoozeMinutes * 60
          reminders.setState(r, "snoozed")
          log.append({ event = "feedback", value = "snooze", id = r.id })
        end,
      },
      {
        label = "Too early",
        fn = function()
          -- the false-positive button: user is NOT done with the thing.
          -- back to PENDING — re-arms on next sighting, full cycle again.
          r.absent = 0
          reminders.setState(r, "pending", "too_early")
          log.append({ event = "feedback", value = "too_early", id = r.id })
        end,
      },
    },
  })
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

function M.start()
  if M.running then return end
  M.running = true
  observer.subscribeTick(M.tick)
  log.append({ event = "trigger.start" })
end

return M
