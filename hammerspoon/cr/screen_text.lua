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

-- one human-readable markdown file per capture; filename answers "when, how,
-- and from what": <timestamp>_<mode>_<App>.md (mode: manual | auto)
local function writeReadable(source, ms, text, mode, reason)
  hs.fs.mkdir(capturesDir())
  local slug = (source:match("^[^—]+") or "capture"):gsub("%s+$", ""):gsub("[^%w%-]+", "-")
  local base = string.format("%s/%s_%s_%s",
    capturesDir(), os.date("%Y-%m-%d_%H-%M-%S"), mode or "manual", slug)
  local path = base .. ".md"
  local n = 1
  while hs.fs.attributes(path) do
    n = n + 1
    path = string.format("%s-%d.md", base, n)
  end
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(string.format(
    "# Screen capture — %s\n\n- source: %s\n- mode: %s (%s)\n- duration: %dms\n- chars: %d\n\n---\n\n%s\n",
    os.date("%Y-%m-%d %H:%M:%S"), source, mode or "manual", reason or "hotkey", ms, #text, text))
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
      -- (b) one human-readable markdown file named by timestamp+mode+app
      local readablePath = writeReadable(source, ms, text, opts.mode, opts.reason)
      log.append({
        event = "screen.ocr", source = source, chars = #text, ms = ms,
        mode = opts.mode or "manual", reason = opts.reason or "hotkey",
        file = readablePath,
      })
      local ok, line = pcall(hs.json.encode, {
        ts = os.time(), iso = os.date("%Y-%m-%dT%H:%M:%S"),
        source = source, ms = ms, text = text, file = readablePath,
        mode = opts.mode or "manual", reason = opts.reason or "hotkey",
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

-- persistent watch mode ---------------------------------------------------
-- Auto-OCR whenever the screen context changes (mode 1: "always watching").
-- OFF by default — this is the privacy firehose, so it's strictly opt-in.
-- Guards: a settle delay (no capture until the new context has been stable
-- for N seconds — an app-switching spree yields one capture, not five), a
-- rate limit between captures, and an exclusion list (password managers etc.).

M.watching = false
local watchSubscribed = false
local settleTimer, lastCapturedKey, lastCaptureAt

local function watchKey(snap)
  return (snap.bundle or "") .. "|" .. (snap.title or "") .. "|" .. (snap.url or "")
end

local function onContextChange(snap)
  if not M.watching or not snap then return end
  local w = config.watch
  if snap.bundle and w.excludeBundles[snap.bundle] then return end
  if settleTimer then settleTimer:stop() end
  local key = watchKey(snap)
  settleTimer = hs.timer.doAfter(w.settleSeconds, function()
    local cur = require("cr.observer").current
    if not M.watching or not cur then return end
    if watchKey(cur) ~= key then return end -- already moved on; skip
    if key == lastCapturedKey then return end -- this context already captured
    if lastCaptureAt and (os.time() - lastCaptureAt) < w.minInterval then return end
    lastCapturedKey = key
    lastCaptureAt = os.time()
    M.capture(function() end, { mode = "auto", reason = "context-change" })
  end)
end

function M.startWatch()
  if M.watching then return end
  M.watching = true
  hs.settings.set("cr.watch", true) -- sticky: survives hs.reload() and reboots
  if not watchSubscribed then
    require("cr.observer").subscribe(onContextChange)
    watchSubscribed = true
  end
  log.append({ event = "watch.start" })
  ui.toast("📸 Screen watching ON — auto-OCR on context change", 1.8)
end

function M.stopWatch()
  if not M.watching then return end
  M.watching = false
  hs.settings.set("cr.watch", false)
  if settleTimer then settleTimer:stop(); settleTimer = nil end
  log.append({ event = "watch.stop" })
  ui.toast("📸 Screen watching OFF", 1.5)
end

-- restore the sticky toggle (called from cr.init after everything is loaded)
function M.restoreWatch()
  if hs.settings.get("cr.watch") then M.startWatch() end
end

function M.toggleWatch()
  if M.watching then M.stopWatch() else M.startWatch() end
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
