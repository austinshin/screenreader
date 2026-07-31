-- cr.voice — wake-phrase voice input: "hey screenreader, remind me to <x>".
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
local timeparse = require("cr.timeparse")
local ui = require("cr.notify_ui")
local listening = require("cr.listening")

local M = { running = false }

local LABEL = "cr.voice.hear"

local buf = ""                 -- partial transcript line carried between polls
local offset = 0               -- how far into the transcript file we've read
local candidate = nil          -- latest parsed reminder text, awaiting settle
local settleTimer, pollTimer, healthTimer
local lastFired = { text = "", at = 0 }

-- Matching the whole phrase was too brittle: the recognizer hears the leading
-- "hey" as whatever it likes ("It screenreader remind me to…", "A screen
-- reader…"), so anchoring on it threw away real commands. Only the distinctive
-- token is matched, anywhere in the line — "hey" never carried signal.
--
-- "screenreader" is two dictionary words, so the recognizer almost always
-- writes it with a space and sometimes swaps one half for a rhyme. Listing the
-- mishearings is not sloppiness — an exact-match wake word fails silently and
-- leaves you repeating yourself at a machine that heard something adjacent.
-- The upside over the old word: two syllables of real English are much harder
-- to trip by accident than a single odd token.
local WAKE = {
  "screenreader", "screen reader", "screen readers", "screenreaders",
  "screen leader", "screen rider", "screen writer", "screenwriter",
  "scream reader", "green reader", "screen redder", "screen reeder",
}

-- Words a sentence can end on when the recognizer cuts an utterance early:
-- "send a video later in" — the time was still coming.
local DANGLING = {
  ["in"] = true, ["at"] = true, ["by"] = true, ["on"] = true, ["for"] = true,
  ["to"] = true, ["around"] = true, ["about"] = true, ["like"] = true,
  ["until"] = true, ["till"] = true, ["before"] = true, ["after"] = true,
}

local function trimDangling(s)
  local out = s
  while true do
    local head, last = out:match("^(.-)%s+(%a+)$")
    if head and DANGLING[last] then out = head else break end
  end
  return out
end

-- Does this line look like nothing but a time? ("like 12 pm", "in 5 minutes")
-- Used to reattach a time the recognizer split into its own utterance.
local function timeOnly(t)
  if #t > 34 then return nil end
  local body = t:gsub("^%s*like%s+", ""):gsub("^%s*", "")
  local hasDigit = body:match("%d")
  local hasUnit = body:match("%f[%a](am|pm|minutes?|mins?|hours?|hrs?|seconds?|secs?|o'?clock)%f[%A]")
    or body:match("%f[%a]tomorrow%f[%A]") or body:match("%f[%a]tonight%f[%A]")
  if not (hasDigit or hasUnit) then return nil end
  -- a bare clock time needs a preposition for cr.timeparse to see it
  if body:match("^%d") then return "at " .. body end
  return body
end

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

-- Was the wake word said? Separate from _parse because the HUD has to appear
-- the moment you're heard — waiting for a complete command means the panel
-- shows up after you've already finished talking, which is too late to be the
-- feedback it exists to be.
function M._wakeAt(line)
  local t = norm(line)
  local at
  for _, w in ipairs(WAKE) do
    local _, e = t:find(w, 1, true)
    if e and (not at or e < at) then at = e end
  end
  return at
end

-- Extract the reminder text from one transcript line, or nil.
-- "it screen reader remind me to do the laundry" → "do the laundry"
function M._parse(line)
  local t = norm(line)
  local wakeEnd
  for _, w in ipairs(WAKE) do
    local _, e = t:find(w, 1, true)
    if e and (not wakeEnd or e < wakeEnd) then wakeEnd = e end
  end
  if not wakeEnd then return nil end
  local rest = t:sub(wakeEnd + 1)
  local text = rest:match("remind me to (.+)$")
    or rest:match("remind me (.+)$")
    or rest:match("reminder to (.+)$")
    or rest:match("remember to (.+)$")
  if text then
    text = trimDangling(text:match("^%s*(.-)%s*$"))
    if #text >= 3 then return text end
  end
  return nil
end

-- Where a spoken command stops and the conversation resumes.
--
-- "remind me to X" has no terminator, so on a live call it captured the task
-- *and the next forty seconds of talking*. Two rules, both cheap:
--
--   1. A time phrase ends the command. "…grocery list in five minutes ok
--      because we're on a call…" — everything after "in five minutes" is
--      drift. This is the strong signal, because someone who states a time is
--      finished stating the task.
--   2. Failing that, cap the length. Spoken reminders are short; a
--      sixteen-word one is already unusual and a fifty-word one is a
--      transcript, not a task.
local function boundCommand(text)
  local _, _, phrase = timeparse.extract(text)
  if phrase then
    local _, e = text:lower():find(phrase:lower(), 1, true)
    if e then text = text:sub(1, e) end
  end
  local n, out = 0, {}
  for w in text:gmatch("%S+") do
    n = n + 1
    if n > 16 then break end
    out[#out + 1] = w
  end
  return (table.concat(out, " "):gsub("%s+$", ""))
end

-- Content words, for comparing two renderings of the same sentence.
local function sig(s)
  local set = {}
  for w in norm(s):gmatch("%a+") do
    if #w > 2 then set[w] = true end
  end
  return set
end

-- The recognizer revises as it goes: the second rendering of one utterance is
-- not a prefix-extension of the first, it is an edit of it ("and it would" →
-- "and then it would"). A prefix check misses that entirely, which is how one
-- sentence became two reminders. Compare content instead.
local function sameThing(a, b)
  local sa, sb = sig(a), sig(b)
  local na, nb, shared = 0, 0, 0
  for w in pairs(sa) do na = na + 1; if sb[w] then shared = shared + 1 end end
  for _ in pairs(sb) do nb = nb + 1 end
  if na == 0 or nb == 0 then return false end
  return shared / math.min(na, nb) >= 0.6
end

local function fire(text)
  local now = os.time()
  text = boundCommand(text)
  -- Dupe guard: within the cooldown, anything that is recognizably the same
  -- sentence is the same reminder — whether it extends the last one or edits it.
  if now - lastFired.at < (cfg().cooldownSeconds or 8)
      and (text:sub(1, #lastFired.text) == lastFired.text
           or sameThing(text, lastFired.text)) then
    log.append({ event = "voice.duplicate_suppressed", text = text, prior = lastFired.text })
    return
  end
  lastFired = { text = text, at = now }
  local r = reminders.add(text, observer.current, { via = "voice" })
  log.append({ event = "voice.captured", text = text, created = r ~= nil })
  local chime = hs.sound.getByName("Glass")
  if chime then chime:play() end
  if r then
    -- Hand off rather than double up: the HUD's job was live feedback while
    -- you spoke, and it ends the moment there is something to confirm. The
    -- card is the receipt, in the same corner and style as the reminders
    -- themselves, so two surfaces never say the same thing at once.
    listening.hide()
    reminders.confirm(r)
  else
    listening.rejected("couldn't attach that to anything on screen")
  end
end

local function arm()
  if settleTimer then settleTimer:stop() end
  settleTimer = hs.timer.doAfter(cfg().settleSeconds or 1.5, function()
    local c = candidate
    candidate = nil
    if c then fire(c) end
  end)
end

-- Feed one transcript line through parse + settle. Exposed for testing.
function M._ingest(line)
  local text = M._parse(line)

  -- Show what was heard as it arrives. The raw line and the parsed task are
  -- both displayed because they fail differently: the recognizer can mishear a
  -- word, or hear it correctly and the parser can misread it, and you can only
  -- tell which by seeing both.
  local wake = M._wakeAt(line)
  if wake then
    local heard = line:sub(wake + 1):gsub("^%s+", "")
    if text then
      local task, due = timeparse.extract(boundCommand(text))
      listening.capturing(heard, task, due and timeparse.fmtDue(due) or nil)
    elseif #heard < 3 then
      listening.listening()
    else
      listening.capturing(heard, nil, nil)
    end
  end

  if not text then
    -- The recognizer ends an utterance wherever it hears a pause, which lands
    -- mid-sentence often enough to matter: "…remind me to send a video later
    -- in" / "Like 12 PM" was one thought split in two, and dropping the second
    -- half silently loses the time. If a time-shaped fragment lands while a
    -- command is still settling, it belongs to that command.
    local tail = candidate and timeOnly(norm(line))
    if tail then
      candidate = candidate .. " " .. tail
      log.append({ event = "voice.merged_tail", tail = tail, text = candidate })
      arm()
    end
    return
  end
  if text == candidate then return end
  candidate = text
  arm()
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
  -- Roll, don't wipe. This log was truncated on every start, so when a live
  -- demo produced two reminders from one sentence the input that caused it was
  -- already gone — the one bug class that most needs evidence had none. Keep a
  -- bounded tail instead: recent enough to debug, bounded enough not to become
  -- an archive of everything said near the machine.
  local keep = {}
  local rf = io.open(transcriptPath(), "r")
  if rf then
    for line in rf:lines() do keep[#keep + 1] = line end
    rf:close()
  end
  local wf = io.open(transcriptPath(), "w")
  if wf then
    local from = math.max(1, #keep - 400)
    for i = from, #keep do wf:write(keep[i], "\n") end
    wf:write(os.date("--- session start %Y-%m-%d %H:%M:%S ---"), "\n")
    wf:close()
  end
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
  ui.toast('🎙 voice on — "hey screenreader, remind me to …"', 2)
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

-- Test seams. The settle timer is the only thing standing between _ingest and
-- a reminder, and a test should not have to sleep through it.
function M._settleNow()
  if settleTimer then settleTimer:stop(); settleTimer = nil end
  local c = candidate
  candidate = nil
  if c then fire(c) end
end

function M._resetForTest()
  if settleTimer then settleTimer:stop(); settleTimer = nil end
  candidate, buf = nil, ""
  lastFired = { text = "", at = 0 }
end

function M.toggle()
  if M.running then M.stop() else M.start() end
end

function M.restore()
  if hs.settings.get("cr.voice") ~= false then M.start() end -- default on
end

return M
