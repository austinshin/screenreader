-- cr.config — tunables for the Contextual Reminders prototype.
-- Everything user-adjustable lives here; modules read this table at call time,
-- so edits + hs.reload() take effect immediately.

local M = {
  -- observer
  pollInterval   = 5,    -- seconds between context samples
  heartbeatEvery = 12,   -- log a heartbeat every N unchanged polls (~1/min)

  -- presence routing
  idleThreshold  = 180,  -- seconds without input before the user counts as "away"
  remoteWhenAway = true, -- mirror notifications to remote channels when away
  remoteChannels = { "discord" },

  -- trigger state machine
  trigger = {
    absentSamples = 6,   -- consecutive absent samples before "really gone" (~30s at 5s poll)
    maxReadyWait  = 90,  -- seconds READY waits for a context switch before firing anyway
    snoozeMinutes = 10,
  },

  -- delivery
  defaultChannels = { "card" },
  card = {
    width    = 380,
    duration = 12,       -- seconds before auto-dismiss (hover to pin)
    margin   = 16,
  },

  -- browsers we can ask for the active tab (bundle id → applescript dialect)
  browsers = {
    ["com.google.Chrome"]          = "chrome",
    ["com.brave.Browser"]          = "chrome",
    ["com.microsoft.edgemac"]      = "chrome",
    ["com.vivaldi.Vivaldi"]        = "chrome",
    ["company.thebrowser.Browser"] = "chrome",  -- Arc
    ["com.apple.Safari"]           = "safari",
  },

  -- filled in by cr.init from this file's location
  projectDir = nil,
}

return M
