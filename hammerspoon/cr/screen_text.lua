-- cr.screen_text — on-demand window/screen OCR ("grab everything and
-- transcribe it into a data stream").
--
-- Pipeline: hs.window:snapshot() → PNG → bin/cr-ocr (Apple Vision, fully
-- on-device) → text. Requires Screen Recording permission for Hammerspoon.
--
-- Deliberately ON-DEMAND, not wired into the 5s observer poll: continuous
-- full-screen OCR is a cost and privacy firehose. The trigger engine will
-- request OCR only when a reminder needs content-level evidence (rung 5 of
-- the sensing ladder). Full text goes to a SEPARATE log stream
-- (logs/ocr-*.jsonl) — it contains everything the user reads; the main event
-- log stays shareable.

local config = require("cr.config")
local log = require("cr.log")
local ui = require("cr.notify_ui")

local M = {}

local function binPath()
  return (config.projectDir or "") .. "/bin/cr-ocr"
end

local function tmpDir()
  return (config.projectDir or os.getenv("HOME")) .. "/tmp"
end

local function ocrLogPath()
  return (config.projectDir or os.getenv("HOME")) .. "/logs/ocr-" .. os.date("%Y-%m-%d") .. ".jsonl"
end

local function capturesDir()
  return (config.projectDir or os.getenv("HOME")) .. "/logs/captures"
end

-- one human-readable markdown file per capture, filename = timestamp + app
local function writeReadable(source, ms, text)
  hs.fs.mkdir(capturesDir())
  local slug = (source:match("^[^—]+") or "capture"):gsub("%s+$", ""):gsub("[^%w%-]+", "-")
  local base = string.format("%s/%s_%s", capturesDir(), os.date("%Y-%m-%d_%H-%M-%S"), slug)
  local path = base .. ".md"
  local n = 1
  while hs.fs.attributes(path) do
    n = n + 1
    path = string.format("%s-%d.md", base, n)
  end
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(string.format(
    "# Screen capture — %s\n\n- source: %s\n- duration: %dms\n- chars: %d\n\n---\n\n%s\n",
    os.date("%Y-%m-%d %H:%M:%S"), source, ms, #text, text))
  f:close()
  return path
end

function M.available()
  return hs.fs.attributes(binPath()) ~= nil
end

-- capture(callback[, opts]) — async; callback(text) or callback(nil, err).
-- Default: the focused window. opts.win = specific window; opts.screen = true
-- for the entire main screen.
function M.capture(callback, opts)
  opts = opts or {}
  if not M.available() then
    callback(nil, "bin/cr-ocr missing — build it: swiftc -O ocr/cr-ocr.swift -o bin/cr-ocr")
    return
  end

  local img, source
  if opts.screen then
    img = hs.screen.mainScreen():snapshot()
    source = "screen"
  else
    local win = opts.win or hs.window.focusedWindow()
    if not win then callback(nil, "no focused window") return end
    img = win:snapshot()
    local app = win:application()
    source = (app and app:name() or "?") .. " — " .. (win:title() or "")
  end

  if not img then
    callback(nil, "snapshot failed — grant Screen Recording to Hammerspoon "
      .. "(System Settings → Privacy & Security → Screen Recording), then restart Hammerspoon")
    return
  end

  hs.fs.mkdir(tmpDir())
  local shot = string.format("%s/shot-%d.png", tmpDir(), os.time())
  if not img:saveToFile(shot) then
    callback(nil, "could not save snapshot")
    return
  end

  local started = hs.timer.secondsSinceEpoch()
  -- retained on M: hs.task objects are GC'd mid-flight otherwise
  M._task = hs.task.new(binPath(), function(exitCode, stdOut, stdErr)
    os.remove(shot)
    local ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000)
    if exitCode == 0 then
      local text = stdOut or ""
      -- two outputs per capture: (a) machine-readable JSONL stream,
      -- (b) one human-readable markdown file named by timestamp
      local readablePath = writeReadable(source, ms, text)
      log.append({
        event = "screen.ocr", source = source, chars = #text, ms = ms,
        file = readablePath,
      })
      local ok, line = pcall(hs.json.encode, {
        ts = os.time(), iso = os.date("%Y-%m-%dT%H:%M:%S"),
        source = source, ms = ms, text = text, file = readablePath,
      })
      if ok then
        local f = io.open(ocrLogPath(), "a")
        if f then f:write(line, "\n"); f:close() end
      end
      callback(text)
    else
      log.append({ event = "screen.ocr.error", source = source, error = stdErr })
      callback(nil, (stdErr and stdErr ~= "") and stdErr or ("cr-ocr exit " .. tostring(exitCode)))
    end
  end, { shot })
  M._task:start()
end

-- hotkey demo: OCR the focused window, show a preview card
function M.demo()
  M.capture(function(text, err)
    if not text then
      ui.show({
        title = "OCR failed", body = tostring(err),
        icon = "⚠️", urgency = "warn", actions = { { label = "OK" } },
      })
      return
    end
    ui.show({
      title = string.format("OCR — %d chars captured", #text),
      body = text:gsub("%s+", " "):sub(1, 160),
      icon = "📝",
      urgency = "success",
      actions = { { label = "OK" } },
    })
  end)
end

return M
