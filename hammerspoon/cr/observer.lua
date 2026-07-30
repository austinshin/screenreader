-- cr.observer — screen context observer.
-- Samples "what is the user looking at" using the cheap rungs of the sensing
-- ladder: frontmost app + focused window title (rung 1), browser tab URL/title
-- via AppleScript (rung 2), media playback state via media-control or
-- nowplaying-cli when installed (rung 3). No screenshots, no OCR — those are
-- later rungs, added only if a real use case demands them.
--
-- Emits context.change events to subscribers (the future trigger engine) and
-- writes every change + a periodic heartbeat to the JSONL event log.

local config = require("cr.config")
local log = require("cr.log")

local M = { current = nil, previous = nil, running = false }

local subscribers = {}
local tickSubscribers = {}
local timer, appWatcher, sleepWatcher
local lastKey
local pollsSinceLog = 0

-- media state (optional; requires `brew install media-control` or nowplaying-cli;
-- note nowplaying-cli is broken on macOS 15.4+ — media-control is the one to use)
local mediaCache, mediaTask, mediaTool, mediaStyle
for _, cand in ipairs({
  { "/opt/homebrew/bin/media-control", "media-control" },
  { "/usr/local/bin/media-control",    "media-control" },
  { "/opt/homebrew/bin/nowplaying-cli", "nowplaying" },
  { "/usr/local/bin/nowplaying-cli",    "nowplaying" },
}) do
  if hs.fs.attributes(cand[1]) then
    mediaTool, mediaStyle = cand[1], cand[2]
    break
  end
end

local function refreshMedia()
  if not mediaTool then return end
  if mediaTask and mediaTask:isRunning() then return end
  local args = (mediaStyle == "media-control") and { "get" }
    or { "get", "title", "playbackRate" }
  -- async: the result lands in mediaCache for the *next* poll, which is fine
  -- at a 5s cadence
  mediaTask = hs.task.new(mediaTool, function(exitCode, stdOut)
    mediaCache = nil
    if exitCode ~= 0 or not stdOut or stdOut == "" then return end
    if mediaStyle == "media-control" then
      local ok, data = pcall(hs.json.decode, stdOut)
      if ok and type(data) == "table" and data.title then
        mediaCache = { title = data.title, playing = data.playing == true }
      end
    else
      local lines = {}
      for line in stdOut:gmatch("[^\n]+") do lines[#lines + 1] = line end
      if lines[1] and lines[1] ~= "null" then
        mediaCache = { title = lines[1], playing = (lines[2] or ""):match("^1") ~= nil }
      end
    end
  end, args)
  mediaTask:start()
end

-- browser active tab -------------------------------------------------------
-- First query per browser triggers a one-time macOS Automation permission
-- prompt ("Hammerspoon wants to control …") — approve it once.

local CHROME_SCRIPT = [[
tell application id "%s"
	if (count of windows) > 0 then
		set t to active tab of front window
		return {URL of t, title of t}
	end if
end tell
]]

local SAFARI_SCRIPT = [[
tell application "Safari"
	if (count of documents) > 0 then
		return {URL of front document, name of front document}
	end if
end tell
]]

local function browserInfo(bundle)
  local kind = config.browsers[bundle]
  if not kind then return nil, nil end
  local script = (kind == "safari") and SAFARI_SCRIPT
    or string.format(CHROME_SCRIPT, bundle)
  local pcallOk, ok, obj = pcall(hs.osascript.applescript, script)
  if pcallOk and ok and type(obj) == "table" and type(obj[1]) == "string" and obj[1] ~= "" then
    return obj[1], (type(obj[2]) == "string" and obj[2] or nil)
  end
  return nil, nil
end

-- sampling ------------------------------------------------------------------

local function takeSnapshot(reason)
  local app = hs.application.frontmostApplication()
  local win = hs.window.focusedWindow()
  local bundle = app and app:bundleID() or nil
  local url, tabTitle
  if bundle then url, tabTitle = browserInfo(bundle) end
  return {
    event  = "context",
    reason = reason,
    app    = app and app:name() or nil,
    bundle = bundle,
    title  = win and win:title() or nil,
    url    = url,
    tab    = tabTitle,
    media  = mediaCache,
    idle   = math.floor(hs.host.idleTime()),
  }
end

-- what counts as "the context changed": app, window title, tab URL, or the
-- media play/pause edge (pausing a video IS a signal for completion triggers)
local function keyOf(s)
  return table.concat({
    s.app or "", s.title or "", s.url or "",
    s.media and (s.media.playing and "playing" or "paused") or "",
  }, "|")
end

local function poll(reason)
  refreshMedia()
  local snap = takeSnapshot(reason or "timer")
  local key = keyOf(snap)
  pollsSinceLog = pollsSinceLog + 1
  if key ~= lastKey then
    snap.event = "context.change"
    log.append(snap)
    pollsSinceLog = 0
    lastKey = key
    M.previous = M.current
    M.current = snap
    for _, fn in ipairs(subscribers) do pcall(fn, snap, M.previous) end
  else
    M.current = snap
    if pollsSinceLog >= config.heartbeatEvery then
      snap.event = "context.heartbeat"
      log.append(snap)
      pollsSinceLog = 0
    end
  end
  for _, fn in ipairs(tickSubscribers) do pcall(fn, snap) end
end

-- public api ------------------------------------------------------------------

-- fn(currentSnapshot, previousSnapshot) — called on every context change
function M.subscribe(fn)
  subscribers[#subscribers + 1] = fn
end

-- fn(snapshot) — called on EVERY poll, changed or not. The trigger engine
-- needs unchanged samples too: cooldown counts consecutive absent samples,
-- and "user stayed in the same app" produces no change events.
function M.subscribeTick(fn)
  tickSubscribers[#tickSubscribers + 1] = fn
end

function M.poll(reason)
  poll(reason or "manual")
end

function M.start()
  if M.running then return end
  M.running = true
  timer = hs.timer.doEvery(config.pollInterval, function() poll("timer") end)
  appWatcher = hs.application.watcher.new(function(_, event, _)
    if event == hs.application.watcher.activated then poll("app-switch") end
  end)
  appWatcher:start()
  sleepWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidUnlock
      or event == hs.caffeinate.watcher.systemDidWake then
      poll("wake")
    end
  end)
  sleepWatcher:start()
  log.append({ event = "observer.start", mediaTool = mediaTool or "none" })
  poll("start")
end

function M.stop()
  if not M.running then return end
  M.running = false
  if timer then timer:stop(); timer = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  if sleepWatcher then sleepWatcher:stop(); sleepWatcher = nil end
  log.append({ event = "observer.stop" })
end

return M
