-- cr.dictate — push-to-talk capture. Hold a key, speak, release.
--
-- This replaces the wake-word path (cr.voice) as the default, and the reason
-- is worth stating precisely, because it is not "Whisper is more accurate".
--
-- Every capture bug this project has had came from the same root: an always-on
-- streaming recognizer never tells you where an utterance begins or ends. So
-- cr.voice had to *guess* both, and every guess needed a mechanism —
--
--   wake word + 12 known mishearings   guessing where the command starts
--   settle timer                       guessing where it ends
--   boundCommand's 16-word cap         guessing again, when the timer was wrong
--   sameThing content overlap          undoing a duplicate the revisions caused
--   cooldown                           undoing the duplicates that survived
--
-- — and each mechanism had its own failure mode. The live demo that produced
-- two reminders from one sentence was three of them interacting.
--
-- A held key answers both questions exactly. You press when you start and
-- release when you stop, so none of that machinery has to exist. This module
-- is deliberately not built on voice._ingest: reusing it would drag the
-- guessing back in behind a different door.
--
-- One correctness gain beyond the deletions: cr.voice binds the reminder to
-- whatever was on screen when the settle timer *fired*, up to 2.5s after you
-- stopped talking. This snapshots at key-down, so a reminder binds to the
-- window you were looking at when you decided to speak about it.
--
--   key-down ─► snapshot context ─► cr-rec ──► 16kHz mono wav
--   key-up   ─► SIGTERM ─► whisper-cli ─► _clean ─► reminders.add
--
-- Everything after _clean is the shared creation path, so time parsing and
-- screen conditions behave identically to every other input method.

local config = require("cr.config")
local log = require("cr.log")
local observer = require("cr.observer")
local reminders = require("cr.reminders")
local listening = require("cr.listening")

local M = { state = "idle" }

-- Tasks are held on M because hs.task objects are garbage collected mid-flight
-- otherwise — the same lesson cr.screen_text records at its own task call.
M._recTask, M._whisperTask = nil, nil
M._snapAtPress, M._wavPath = nil, nil
M._startedAt, M._peakDb = nil, nil
local capTimer, hudTimer

local function cfg()
  return config.dictate or {}
end

local function projectDir()
  return config.projectDir or (os.getenv("HOME") .. "/.hammerspoon")
end

-- Audio goes to ~/Library/Logs, never the project directory: that lives under
-- ~/Documents, which is TCC-protected, and a recorder that trips a permission
-- dialog on write is a recorder that loses the utterance. cr.voice records the
-- same reasoning for its transcript log.
local function audioDir()
  local d = os.getenv("HOME") .. "/Library/Logs/cr-voice"
  hs.fs.mkdir(d)
  return d
end

local function recorderPath()
  if cfg().recorder then return cfg().recorder end
  local swift = projectDir() .. "/bin/cr-rec"
  if hs.fs.attributes(swift) then return swift end
  for _, p in ipairs({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }) do
    if hs.fs.attributes(p) then return p end
  end
  return nil
end

local function modelPath()
  return cfg().model or (projectDir() .. "/models/ggml-base.en.bin")
end

local function whisperPath()
  return cfg().whisper or "/opt/homebrew/bin/whisper-cli"
end

-- Reports what is missing rather than just "unavailable": each of these has a
-- different one-line fix, and a single "voice doesn't work" would hide which.
function M.available()
  if not recorderPath() then
    return false, "no recorder — run ./setup.sh to build bin/cr-rec"
  end
  if not hs.fs.attributes(whisperPath()) then
    return false, "whisper-cli missing — brew install whisper-cpp"
  end
  if not hs.fs.attributes(modelPath()) then
    return false, "speech model missing — run ./setup.sh"
  end
  return true
end

function M.busy()
  return M.state ~= "idle"
end

function M.enabled()
  local capture = require("cr.capture")
  return capture.mode() == "ptt"
end

-- capture ---------------------------------------------------------------------

local function stopTimers()
  if capTimer then capTimer:stop(); capTimer = nil end
  if hudTimer then hudTimer:stop(); hudTimer = nil end
end

local function killTasks()
  for _, t in ipairs({ M._recTask, M._whisperTask }) do
    if t then pcall(function() if t:isRunning() then t:terminate() end end) end
  end
  M._recTask, M._whisperTask = nil, nil
end

function M.cancel(reason)
  if M.state == "idle" then return end
  stopTimers()
  killTasks()
  if M._wavPath and not (cfg().keepFailedAudio == false) then
    os.remove(M._wavPath)
  end
  M.state = "idle"
  M._wavPath = nil
  listening.hide()
  log.append({ event = "dictate.cancelled", reason = reason })
end

function M.startRecording()
  if not M.enabled() then return end
  if M.state ~= "idle" then
    -- A second press while recording is almost always a key-up that never
    -- arrived (Carbon can drop a release if the modifiers break first). Treat
    -- it as the release rather than ignoring it, so the next attempt works
    -- instead of the module being wedged until the watchdog.
    if M.state == "recording" or M.state == "starting" then
      log.append({ event = "dictate.press_while_recording", action = "treated as release" })
      return M.stopRecording()
    end
    listening.rejected("still transcribing…")
    return
  end

  local ok, why = M.available()
  if not ok then
    listening.rejected(why)
    log.append({ event = "dictate.unavailable", reason = why })
    return
  end

  -- Bind to what you were looking at when you decided to speak, not to
  -- wherever you end up when the transcript comes back.
  M._snapAtPress = observer.current
  M._startedAt = hs.timer.secondsSinceEpoch()
  M._peakDb = nil
  M._wavPath = string.format("%s/ptt-%d.wav", audioDir(), os.time())
  M.state = "starting"
  listening.recording(0, nil, false)

  local maxSeconds = cfg().maxSeconds or 20
  local bin = recorderPath()
  local args
  if bin:match("ffmpeg$") then
    args = { "-nostdin", "-hide_banner", "-loglevel", "error",
             "-f", "avfoundation", "-i", ":default",
             "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
             "-t", tostring(maxSeconds), "-y", M._wavPath }
  else
    args = { M._wavPath, tostring(maxSeconds) }
  end

  M._recTask = hs.task.new(bin, function(code, _, se)
    -- exit 77 is cr-rec's "microphone denied": a different fix from every
    -- other failure, so it gets its own message rather than "didn't catch it"
    if code == 77 then
      M.state = "idle"
      stopTimers()
      listening.rejected("microphone denied — System Settings › Privacy › Microphone")
      log.append({ event = "dictate.mic_denied" })
      return
    end
    if code ~= 0 and M.state ~= "transcribing" then
      M.state = "idle"
      stopTimers()
      listening.rejected("recorder failed")
      log.append({ event = "dictate.recorder_failed", code = code,
                   stderr = tostring(se):sub(1, 200) })
    end
  end, function(_, so)
    -- streaming callback: READY flips the HUD live, LVL drives the level read
    if so and so:find("READY", 1, true) and M.state == "starting" then
      M.state = "recording"
    end
    for lvl in (so or ""):gmatch("LVL (-?%d+%.?%d*)") do
      M._peakDb = tonumber(lvl)
    end
    return true
  end, args)

  if not M._recTask or not M._recTask:start() then
    M.state = "idle"
    listening.rejected("could not start the recorder")
    log.append({ event = "dictate.recorder_start_failed", bin = bin })
    return
  end
  -- ffmpeg has no READY handshake; treat it as live immediately
  if bin:match("ffmpeg$") then M.state = "recording" end

  hudTimer = hs.timer.doEvery(0.25, function()
    if M.state ~= "recording" and M.state ~= "starting" then return end
    listening.recording(hs.timer.secondsSinceEpoch() - M._startedAt,
                        M._peakDb, M.state == "recording")
  end)

  -- Watchdog for a key-up that never arrives. Without it a dropped release
  -- means the mic stays open indefinitely, which is the one property this
  -- whole design exists to avoid.
  capTimer = hs.timer.doAfter(maxSeconds + 0.5, function()
    if M.state == "recording" or M.state == "starting" then
      log.append({ event = "dictate.capped", seconds = maxSeconds })
      M.stopRecording(true)
    end
  end)

  log.append({ event = "dictate.recording", bin = bin,
               bound = M._snapAtPress and M._snapAtPress.title })
end

function M.stopRecording(capped)
  if M.state ~= "recording" and M.state ~= "starting" then return end
  stopTimers()

  local held = hs.timer.secondsSinceEpoch() - (M._startedAt or 0)
  -- A tap rather than a hold is a fumbled keystroke, not a reminder. Bailing
  -- here costs nothing; transcribing it would cost a second and produce noise.
  if held < (cfg().minSeconds or 0.35) and not capped then
    log.append({ event = "dictate.too_short", held = held })
    return M.cancel("too short")
  end

  M.state = "transcribing"
  listening.transcribing()
  local wav = M._wavPath
  if M._recTask then pcall(function() M._recTask:terminate() end) end

  -- The recorder needs a moment after SIGTERM to write the RIFF sizes; reading
  -- the file before that yields a header claiming zero samples.
  hs.timer.doAfter(0.25, function()
    M._transcribeFile(wav, function(text, err)
      if err then
        M.state = "idle"
        listening.rejected(err)
        log.append({ event = "dictate.transcribe_failed", error = err })
        return
      end
      M._onTranscript(text, wav)
    end)
  end)
end

function M._transcribeFile(wav, cb)
  if not wav or not hs.fs.attributes(wav) then return cb(nil, "no audio recorded") end

  local timeout = hs.timer.doAfter(cfg().transcribeTimeout or 12, function()
    if M._whisperTask then pcall(function() M._whisperTask:terminate() end) end
    cb(nil, "transcription timed out")
  end)

  M._whisperTask = hs.task.new(whisperPath(), function(code, so, se)
    timeout:stop()
    if code ~= 0 then
      return cb(nil, "whisper failed (" .. tostring(code) .. ")")
    end
    log.append({ event = "dictate.transcribed", raw = (so or ""):sub(1, 300),
                 stderr = code ~= 0 and tostring(se):sub(1, 200) or nil })
    cb(so, nil)
  end, {
    "-m", modelPath(), "-f", wav,
    "-l", cfg().language or "en",
    "-nt",   -- no timestamps: stdout becomes the bare transcript
    "-np",   -- no prints: no load banner, no timing table
    "-sns",  -- suppress non-speech tokens ([BLANK_AUDIO] and friends)
    "-mc", "0",  -- no context between segments; stops repetition loops
    "-t", tostring(cfg().threads or 8),
  })
  M._whisperTask:start()
end

-- parse ------------------------------------------------------------------------

-- Whisper emits a leading space, sentence capitalization, and a trailing
-- period — none of which the old `hear` path produced, so this is the only
-- normalization the switch actually adds.
--
-- On silence it does not return nothing; it hallucinates. The training data was
-- captioned video, so an empty clip reliably produces "Thank you." or "you" or
-- "Thanks for watching." Those have to be rejected as *whole strings*: matching
-- them as substrings would eat "thank Ruth for the coffee", which is a real
-- reminder.
local NOISE = {
  ["[blank_audio]"] = true, ["(silence)"] = true, ["[silence]"] = true,
  ["[music]"] = true, ["(upbeat music)"] = true, ["you"] = true,
  ["thank you"] = true, ["thanks for watching"] = true,
  ["thank you for watching"] = true, ["bye"] = true, ["so"] = true,
  ["."] = true, [""] = true, ["oh"] = true, ["hmm"] = true,
}

-- With push-to-talk the whole utterance is the command, so a "remind me to"
-- preamble is politeness rather than syntax — strip it if present, require it
-- never. "Water the plants" is a complete instruction.
local PREAMBLE = {
  "^remind me that ", "^remind me to ", "^remind me ",
  "^reminder to ", "^reminder ", "^remember to ", "^remember ",
  "^note to self,? ", "^make a note to ", "^make a note ",
}

function M._clean(raw)
  local t = (raw or ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  if t == "" then return nil, "didn't catch that" end

  local lowered = t:lower():gsub("[%.!]+$", "")
  if NOISE[lowered] then return nil, "didn't catch that" end
  if #lowered < 3 then return nil, "didn't catch that" end

  t = t:gsub("[%.!]+$", "")
  local low = t:lower()
  for _, p in ipairs(PREAMBLE) do
    local s, e = low:find(p)
    if s then
      t = t:sub(e + 1)
      break
    end
  end
  t = t:match("^%s*(.-)%s*$")
  if t == "" or #t < 3 then return nil, "didn't catch that" end
  return t
end

-- The seam the tests drive: raw whisper stdout in, reminder or nil out.
function M._onTranscript(raw, wav)
  M.state = "idle"
  local text, why = M._clean(raw)
  if not text then
    listening.rejected(why)
    -- Keep the audio when the parse failed. The bug class that most needs
    -- evidence is the one that leaves none; cr.voice keeps a rolling
    -- transcript tail for the same reason.
    if wav and cfg().keepFailedAudio ~= false then
      os.rename(wav, audioDir() .. "/last-failed.wav")
    end
    log.append({ event = "dictate.rejected", raw = (raw or ""):sub(1, 200), reason = why })
    return nil
  end
  if wav then os.remove(wav) end

  local r = reminders.add(text, M._snapAtPress, { via = "dictate" })
  if not r then
    listening.rejected("couldn't attach that to anything on screen")
    return nil
  end
  -- Hand off to the card: the HUD's job was live feedback while you spoke, and
  -- it ends the moment there is something to confirm, so two surfaces never
  -- say the same thing at once.
  listening.hide()
  reminders.confirm(r)
  return r
end

-- Old audio outlives a reload: the Lua state dies with the tasks and the WAV is
-- orphaned. Sweep on load rather than accumulating megabytes of dead captures.
function M.sweep()
  local dir = audioDir()
  local now = os.time()
  for file in hs.fs.dir(dir) do
    if file:match("^ptt%-%d+%.wav$") then
      local p = dir .. "/" .. file
      local a = hs.fs.attributes(p)
      if a and (now - a.modification) > 3600 then os.remove(p) end
    end
  end
end

function M._resetForTest()
  stopTimers()
  killTasks()
  M.state = "idle"
  M._snapAtPress, M._wavPath, M._peakDb = nil, nil, nil
end

return M
