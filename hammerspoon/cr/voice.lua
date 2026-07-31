-- cr.voice — wake-phrase voice input: "hey wispr, remind me to <x>".
--
-- Continuous on-device speech recognition via the `hear` CLI (a thin wrapper
-- around Apple's SFSpeechRecognizer; github.com/sveinbjornt/hear).
--
-- WHY LAUNCHD, NOT hs.task: a child process's mic/speech permission request is
-- attributed to its responsible process. Spawned from Hammerspoon that means
-- Hammerspoon — whose Info.plist has no NSSpeechRecognitionUsageDescription,
-- so macOS kills the child on the spot (SIGABRT, exit 6). Running hear as a
-- launchd agent makes hear its own responsible process; it embeds both usage
-- descriptions, so the permission prompts appear (once) attributed to "hear".
-- hear streams growing partial transcripts to a log file (it fflushes per
-- write); we tail the file and parse each update for wake phrase + command,
-- firing once the utterance stops changing (settle timer = finality signal).
--
-- Audio never leaves the machine (-d forces on-device recognition), matching
-- the local-only story of the OCR pipeline. The mic is held open while
-- enabled, so this is a sticky opt-out toggle (⌃⌥⌘M) like watch mode.

local config = require("cr.config")
local log = require("cr.log")
local observer = require("cr.observer")
local reminders = require("cr.reminders")
local ui = require("cr.notify_ui")

local M = { running = false }

local LABEL = "cr.voice.hear"

local buf = ""                 -- partial transcript line carried between polls
local offset = 0               -- how far into the transcript file we've read
local candidate = nil          -- latest parsed reminder text, awaiting settle
local settleTimer, pollTimer, healthTimer
local lastFired = { text = "", at = 0 }

-- What SFSpeechRecognizer tends to make of "wispr". Matched against
-- normalized text (lowercased, punctuation stripped).
local WAKE = {
  "hey wispr", "hey whisper", "hey wisper", "hey whispr",
  "hey whispers", "a whisper", "hey vesper",
}

local function cfg()
  return config.voice or {}
end

-- NOT the project logs/ dir: that lives under ~/Documents, which is
-- TCC-protected — launchd can't open StandardOutPath there (spawn fails with
-- EX_CONFIG). ~/Library/Logs is the conventional, unprotected home for this.
local function logsDir()
  return os.getenv("HOME") .. "/Library/Logs/cr-voice"
end

local function transcriptPath() return logsDir() .. "/voice-transcript.log" end
local function stderrPath()     return logsDir() .. "/voice-hear.err" end

local function plistPath()
  return os.getenv("HOME") .. "/Library/LaunchAgents/" .. LABEL .. ".plist"
end

local function uid()
  return (hs.execute("id -u") or ""):match("%d+") or "501"
end

local function norm(s)
  return (s:lower():gsub("%p", " "):gsub("%s+", " "):gsub("^%s", ""))
end

-- Extract the reminder text from one transcript line, or nil.
-- "hey wispr remind me to do the laundry" → "do the laundry"
function M._parse(line)
  local t = norm(line)
  local wakeEnd
  for _, w in ipairs(WAKE) do
    local _, e = t:find(w, 1, true)
    if e then wakeEnd = e; break end
  end
  if not wakeEnd then return nil end
  local rest = t:sub(wakeEnd + 1)
  local text = rest:match("remind me to (.+)$")
    or rest:match("remind me (.+)$")
    or rest:match("reminder to (.+)$")
  if text then
    text = text:match("^%s*(.-)%s*$")
    if #text >= 3 then return text end
  end
  return nil
end

local function fire(text)
  local now = os.time()
  -- Dupe guard: the same utterance keeps growing after we fire ("buy milk" →
  -- "buy milk and eggs"), so inside the cooldown window we also skip any
  -- candidate that extends what we just created.
  if now - lastFired.at < (cfg().cooldownSeconds or 8)
      and text:sub(1, #lastFired.text) == lastFired.text then
    return
  end
  lastFired = { text = text, at = now }
  local r = reminders.add(text, observer.current, { via = "voice" })
  log.append({ event = "voice.captured", text = text, created = r ~= nil })
  local chime = hs.sound.getByName("Glass")
  if chime then chime:play() end
  if r then
    -- r.text has the time phrase stripped; describe() = when · where · how
    ui.toast('🎙 "' .. r.text .. '" — ' .. reminders.describe(r), 3.5)
  else
    ui.toast('🎙 heard "' .. text .. '" — ⚠️ nothing bindable on screen', 3)
  end
end

-- Feed one transcript line through parse + settle. Exposed for testing.
function M._ingest(line)
  local text = M._parse(line)
  if not text or text == candidate then return end
  candidate = text
  if settleTimer then settleTimer:stop() end
  settleTimer = hs.timer.doAfter(cfg().settleSeconds or 1.5, function()
    local c = candidate
    candidate = nil
    if c then fire(c) end
  end)
end

-- Read whatever hear appended to the transcript since the last poll.
local function readNew()
  local f = io.open(transcriptPath(), "r")
  if not f then return end
  local size = f:seek("end")
  if size < offset then offset = 0 end -- file truncated/recreated
  if size == offset then f:close(); return end
  f:seek("set", offset)
  local chunk = f:read("*a") or ""
  offset = f:seek()
  f:close()
  buf = buf .. chunk
  while true do
    local nl = buf:find("\n", 1, true)
    if not nl then break end
    local line = buf:sub(1, nl - 1)
    buf = buf:sub(nl + 1)
    if line ~= "" then M._ingest(line) end
  end
end

local function writePlist()
  local bin = cfg().binary or "/opt/homebrew/bin/hear"
  local plist = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array>
    <string>%s</string>
    <string>-d</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict></plist>
]], LABEL, bin, transcriptPath(), stderrPath())
  local f = io.open(plistPath(), "w")
  if not f then return false end
  f:write(plist)
  f:close()
  return true
end

function M.start()
  if M.running then return end
  local bin = cfg().binary or "/opt/homebrew/bin/hear"
  if not hs.fs.attributes(bin) then
    ui.toast("voice: `hear` not found at " .. bin, 3)
    return
  end
  M.running = true
  hs.settings.set("cr.voice", true) -- sticky: survives hs.reload() and reboots
  hs.fs.mkdir(logsDir())
  io.open(transcriptPath(), "w"):close() -- truncate: old transcript is stale
  buf, offset, candidate = "", 0, nil
  if not writePlist() then
    ui.toast("voice: cannot write " .. plistPath(), 3)
    M.running = false
    return
  end
  -- bootout first so a previously-loaded agent never runs with a stale plist
  hs.execute(string.format("launchctl bootout gui/%s/%s 2>/dev/null", uid(), LABEL))
  hs.execute(string.format("launchctl bootstrap gui/%s '%s' 2>/dev/null", uid(), plistPath()))
  pollTimer = hs.timer.doEvery(0.35, readNew)
  -- If hear isn't alive shortly after start, permissions are the usual reason.
  healthTimer = hs.timer.doAfter(4, function()
    local out = hs.execute("pgrep -x hear")
    if M.running and (not out or out == "") then
      ui.toast("🎙 hear isn't running — allow Microphone + Speech Recognition "
        .. 'for "hear" in System Settings, then toggle ⌃⌥⌘M', 6)
      log.append({ event = "voice.health", ok = false })
    end
  end)
  log.append({ event = "voice.agent_start" })
  ui.toast('🎙 voice on — "hey wispr, remind me to …"', 2)
end

function M.stop()
  if not M.running then return end
  M.running = false
  hs.settings.set("cr.voice", false)
  if settleTimer then settleTimer:stop() end
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  if healthTimer then healthTimer:stop(); healthTimer = nil end
  hs.execute(string.format("launchctl bootout gui/%s/%s 2>/dev/null", uid(), LABEL))
  os.remove(plistPath()) -- or launchd would resurrect it at next login
  log.append({ event = "voice.agent_stop" })
  ui.toast("🎙 voice off", 1.5)
end

function M.toggle()
  if M.running then M.stop() else M.start() end
end

function M.restore()
  if hs.settings.get("cr.voice") ~= false then M.start() end -- default on
end

return M
