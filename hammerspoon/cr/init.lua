-- Contextual Reminders — Wispr take-home prototype.
-- Loaded from ~/.hammerspoon/init.lua via require("cr"); everything lives in
-- this repo so the Hammerspoon config only carries a loader stanza.
--
-- Step 1: screen context observer + notification stack.
-- Step 2 (current): deictic reminders + trigger state machine, zero LLM —
--   "remind me <text> when I'm done with THIS" where THIS = current screen.
-- Next: LLM layer for non-deictic conditions + ambiguity judging.

local M = {}

-- resolve the project root from this file's own location
local src = debug.getinfo(1, "S").source:sub(2) -- strip leading "@"
local hsDir = src:match("^(.*)/cr/init%.lua$")
local projectDir = hsDir and hsDir:match("^(.*)/hammerspoon$")

local config = require("cr.config")
config.projectDir = projectDir

local log      = require("cr.log")
local observer = require("cr.observer")
local ui       = require("cr.notify_ui")
local notifier = require("cr.notifier")
local matcher  = require("cr.matcher")
local reminders = require("cr.reminders")
local trigger  = require("cr.trigger")
local screenText = require("cr.screen_text")
local viewer   = require("cr.viewer")
local suggestions = require("cr.suggestions")
local menubar  = require("cr.menubar")
local voice    = require("cr.voice")
local dictate  = require("cr.dictate")
local capture  = require("cr.capture")
local keys     = require("cr.keys")
local glance   = require("cr.glance")
local hotkeys  = require("cr.hotkeys")

log.append({ event = "cr.loaded", projectDir = projectDir })

reminders.load()
observer.start()
trigger.start()
menubar.start()
trigger.onStateChange = menubar.refresh
trigger.restoreFired()    -- unanswered reminders survive a reload
-- Two consumers of every OCR capture: the live viewer, and the content-condition
-- watcher that decides whether "after the tests run" just came true.
screenText.onCapture = function(entry)
  pcall(viewer.update, entry)
  pcall(trigger.onCapture, entry)
end
screenText.restoreWatch() -- sticky ⌃⌥⌘W toggle survives reloads/reboots
viewer.restore()          -- sticky ⌃⌥⌘V viewer panel
suggestions.start()
suggestions.onChange = menubar.refresh
capture.restore()         -- starts at most one voice path: push-to-talk or wake word
keys.restore()            -- sticky ⌃⌥⌘K hotkey cheatsheet

-- Hotkeys: the registry owns the chords, this only says what each one does.
-- Bindings are user-editable from the dashboard's Settings tab and persist to
-- data/hotkeys.json; the cheatsheet and menu bar read the same registry, so a
-- rebind can't leave a stale chord advertised somewhere.
--
-- Carbon hotkeys (hs.hotkey) cost nothing until pressed. An hs.eventtap would
-- allow the fn key but runs a callback on every keystroke on the system, and
-- on this single-threaded config that meant dropped characters while typing
-- anywhere. A modifier you can't have is a smaller problem than a keyboard
-- that doesn't work — so fn is deliberately unsupported.
-- A handler is either a function (tap) or { pressed, released } (hold).
-- Push-to-talk is the only hold binding: the key *is* the utterance boundary,
-- which is what removes the wake word, the settle timer, and the duplicate
-- guards that guessed at those boundaries before.
hotkeys.handlers = {
  reminder = reminders.promptNew,
  glance   = glance.toggle,
  voice    = capture.cycle,
  dictate  = { pressed = dictate.startRecording, released = dictate.stopRecording },
  ocr      = screenText.demo,
  watch    = screenText.toggleWatch,
  viewer   = viewer.toggle,
  review   = suggestions.review,
  context  = menubar.showCurrentContext,
  test     = notifier.test,
  keys     = keys.toggle,
}
hotkeys.load()
hotkeys.apply()

-- global handle for console debugging: hs -c "print(hs.inspect(CR.observer.current))"
M.config, M.log, M.observer, M.ui, M.notifier, M.menubar = config, log, observer, ui, notifier, menubar
M.matcher, M.reminders, M.trigger, M.screenText = matcher, reminders, trigger, screenText
M.viewer, M.suggestions, M.voice, M.keys = viewer, suggestions, voice, keys
M.hotkeys, M.glance = hotkeys, glance
M.dictate, M.capture, M.notification = dictate, capture, require("cr.notification")
CR = M

print("[cr] Contextual Reminders loaded — project: " .. tostring(projectDir))
do -- print the live bindings rather than a hand-maintained copy of them
  local parts = {}
  for _, b in ipairs(hotkeys.list()) do parts[#parts + 1] = b.chord .. " = " .. b.label end
  print("[cr] hotkeys: " .. table.concat(parts, " · "))
end

return M
