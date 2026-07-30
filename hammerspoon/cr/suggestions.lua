-- cr.suggestions — surface extracted candidates and collect the labels.
--
-- The Python service (service/extract.py) writes scored candidates to
-- data/candidates.jsonl. This module tails that file and routes each candidate
-- by score into one of three lanes:
--
--   >= fireThreshold   a card, now (interrupt)
--   >= inboxThreshold  the menu-bar inbox, silent (no interrupt)
--   below              never written by the service
--
-- Accept / Dismiss / Not mine are the labels the learning layer trains on:
-- every press appends a feedback row carrying the candidate's feature vector,
-- which `extract.py --learn` turns into per-feature multipliers. The tiering
-- matters as much as the labels — a medium-confidence candidate can be wrong
-- for free in the inbox, which is what makes collecting labels cheap.

local config = require("cr.config")
local log = require("cr.log")
local ui = require("cr.notify_ui")
local reminders = require("cr.reminders")
local observer = require("cr.observer")

local M = { inbox = {}, running = false }

local timer
local cursor = 0 -- lines consumed from candidates.jsonl

local function candidatesPath()
  return (config.projectDir or "") .. "/data/candidates.jsonl"
end

local function feedbackPath()
  return (config.projectDir or "") .. "/data/feedback.jsonl"
end

-- The label. `value` is one of accept | dismiss | not_mine | too_early.
function M.feedback(c, value)
  local ok, line = pcall(hs.json.encode, {
    ts = os.time(),
    iso = os.date("%Y-%m-%dT%H:%M:%S"),
    id = c.id,
    value = value,
    action = c.action,
    kind = c.kind,
    app = c.app,
    score = c.score,
    backend = c.backend,
    features = c.features,
  })
  if ok then
    local f = io.open(feedbackPath(), "a")
    if f then f:write(line, "\n"); f:close() end
  end
  log.append({ event = "suggestion.feedback", value = value, id = c.id, score = c.score })
end

local function removeFromInbox(c)
  for i, x in ipairs(M.inbox) do
    if x.id == c.id then table.remove(M.inbox, i); return end
  end
end

-- Accept turns the candidate into a real reminder bound to the current screen,
-- so it flows through the same trigger FSM as a hand-made one.
local function accept(c)
  M.feedback(c, "accept")
  removeFromInbox(c)
  local r = reminders.add(c.action, observer.current)
  if r then
    ui.toast("👁 Watching: " .. r.referent.label, 2)
  else
    ui.toast("⚠️ Nothing bindable on screen — not created", 2)
  end
  if M.onChange then pcall(M.onChange) end
end

local function dismiss(c, value)
  M.feedback(c, value or "dismiss")
  removeFromInbox(c)
  if M.onChange then pcall(M.onChange) end
end

function M.showCard(c)
  ui.show({
    title = "Suggested reminder  ·  " .. string.format("%.2f", c.score or 0),
    body = c.action .. "\n\n" .. (c.source or ""),
    icon = "💡",
    urgency = "warn",
    duration = 20,
    actions = {
      { label = "Add",      fn = function() accept(c) end },
      { label = "Not mine", fn = function() dismiss(c, "not_mine") end },
      { label = "Dismiss",  fn = function() dismiss(c, "dismiss") end },
    },
  })
end

local function ingest(c)
  local t = config.suggestions
  if (c.score or 0) >= t.fireThreshold then
    log.append({ event = "suggestion.card", id = c.id, score = c.score })
    M.showCard(c)
  else
    M.inbox[#M.inbox + 1] = c
    log.append({ event = "suggestion.inbox", id = c.id, score = c.score })
  end
  if M.onChange then pcall(M.onChange) end
end

local function poll()
  local f = io.open(candidatesPath(), "r")
  if not f then return end
  local n = 0
  for line in f:lines() do
    n = n + 1
    if n > cursor and line ~= "" then
      local ok, c = pcall(hs.json.decode, line)
      if ok and type(c) == "table" and c.action then ingest(c) end
    end
  end
  f:close()
  cursor = n
end

-- On start, skip whatever is already in the file: those were produced before
-- this session and replaying them would spam cards on every reload.
local function seekToEnd()
  local f = io.open(candidatesPath(), "r")
  if not f then cursor = 0; return end
  local n = 0
  for _ in f:lines() do n = n + 1 end
  f:close()
  cursor = n
end

function M.inboxRows()
  local rows = {}
  for _, c in ipairs(M.inbox) do
    rows[#rows + 1] = {
      title = string.format("💡 %.2f  %s", c.score or 0,
        (#c.action > 44) and (c.action:sub(1, 43) .. "…") or c.action),
      menu = {
        { title = c.source or "", disabled = true },
        { title = "kind: " .. (c.kind or "?") .. "  ·  via " .. (c.backend or "?"), disabled = true },
        { title = "-" },
        { title = "Add as reminder", fn = function() accept(c) end },
        { title = "Not mine",        fn = function() dismiss(c, "not_mine") end },
        { title = "Dismiss",         fn = function() dismiss(c, "dismiss") end },
      },
    }
  end
  return rows
end

function M.start()
  if M.running then return end
  M.running = true
  seekToEnd()
  timer = hs.timer.doEvery(config.suggestions.pollInterval, poll)
  log.append({ event = "suggestions.start", cursor = cursor })
end

function M.stop()
  if not M.running then return end
  M.running = false
  if timer then timer:stop(); timer = nil end
end

return M
