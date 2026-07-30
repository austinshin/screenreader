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
local menubar  = require("cr.menubar")

log.append({ event = "cr.loaded", projectDir = projectDir })

reminders.load()
observer.start()
trigger.start()
menubar.start()
trigger.onStateChange = menubar.refresh

-- hotkeys (⌃⌥⌘ layer; alt+space stays with the file opener)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "r", reminders.promptNew)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "t", notifier.test)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "c", menubar.showCurrentContext)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "s", screenText.demo)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "w", screenText.toggleWatch)

-- global handle for console debugging: hs -c "print(hs.inspect(CR.observer.current))"
M.config, M.log, M.observer, M.ui, M.notifier, M.menubar = config, log, observer, ui, notifier, menubar
M.matcher, M.reminders, M.trigger, M.screenText = matcher, reminders, trigger, screenText
CR = M

print("[cr] Contextual Reminders loaded — project: " .. tostring(projectDir))
print("[cr] hotkeys: ⌃⌥⌘R new reminder · ⌃⌥⌘T test · ⌃⌥⌘C context · ⌃⌥⌘S OCR window")

return M
