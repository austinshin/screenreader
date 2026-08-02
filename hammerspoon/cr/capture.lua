-- cr.capture — which voice path is live. Exactly one, or none.
--
-- There are two ways to speak a reminder: hold a key (cr.dictate) or say a
-- wake word (cr.voice). They must never both run, and the reason is not that
-- something crashes — macOS is happy to have two microphone clients. It is
-- that `hear` would transcribe your push-to-talk utterance too, and if
-- anything in it resembled the wake word you would get a *second reminder*.
-- That is precisely the bug push-to-talk was built to eliminate, arriving by a
-- new route.
--
-- Two booleans can represent "both on", so this is one tri-state instead:
-- the invalid state cannot be written down. Switching modes stops the other
-- path as part of the switch rather than as a thing the caller must remember.

local log = require("cr.log")

local M = {}

local KEY = "cr.capture.mode"   -- "ptt" | "wake" | "off"

local function migrate()
  -- cr.voice was a sticky boolean before this module existed. An existing
  -- `true` means the user had chosen the wake word; anything else becomes
  -- push-to-talk, which is the new default.
  local old = hs.settings.get("cr.voice")
  if old ~= nil then
    hs.settings.set(KEY, old and "wake" or "ptt")
    hs.settings.clear("cr.voice")
    log.append({ event = "capture.migrated", from = tostring(old) })
  end
end

function M.mode()
  local m = hs.settings.get(KEY)
  if m ~= "ptt" and m ~= "wake" and m ~= "off" then return "ptt" end
  return m
end

-- Returns the mode actually reached, which may differ from the one asked for:
-- selecting a path whose dependencies are missing degrades to "off" and says
-- why, rather than reporting success and staying silent when a key is held.
function M.set(mode)
  if mode ~= "ptt" and mode ~= "wake" and mode ~= "off" then return M.mode() end
  local voice = require("cr.voice")
  local dictate = require("cr.dictate")

  if mode ~= "wake" and voice.running then pcall(voice.stop) end
  if mode ~= "ptt" and dictate.busy() then pcall(dictate.cancel, "mode change") end

  if mode == "ptt" then
    local ok, why = dictate.available()
    if not ok then
      hs.settings.set(KEY, "off")
      log.append({ event = "capture.mode_failed", want = "ptt", reason = why })
      hs.alert.show("Push-to-talk unavailable: " .. (why or "?"))
      return "off"
    end
  elseif mode == "wake" then
    if not voice.start() then
      hs.settings.set(KEY, "off")
      log.append({ event = "capture.mode_failed", want = "wake" })
      return "off"
    end
  end

  hs.settings.set(KEY, mode)
  log.append({ event = "capture.mode", mode = mode })
  return mode
end

function M.label()
  local m = M.mode()
  if m == "ptt" then return "Hold a key to speak" end
  if m == "wake" then return 'Wake word ("hey screenreader")' end
  return "Voice off"
end

-- Cycle for the menu bar / hotkey: ptt → wake → off → ptt
function M.cycle()
  local order = { ptt = "wake", wake = "off", off = "ptt" }
  local reached = M.set(order[M.mode()] or "ptt")
  hs.alert.show(M.label())
  return reached
end

-- Called once at load. Starts at most one path.
function M.restore()
  migrate()
  local m = M.mode()
  if m == "wake" then
    require("cr.voice").start()
  elseif m == "ptt" then
    local dictate = require("cr.dictate")
    dictate.sweep()
    local ok, why = dictate.available()
    if not ok then
      log.append({ event = "capture.degraded", reason = why })
    end
  end
  log.append({ event = "capture.restored", mode = m })
  return m
end

return M
