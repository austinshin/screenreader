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

-- The ask, phrased as an offer rather than an assertion. The system is
-- guessing; the copy should say so, quote the evidence it guessed from, and
-- make declining as easy as accepting. A suggestion that reads as a decision
-- ("Reminder created") spends trust it hasn't earned.
function M.showCard(c)
  local where = (c.app and c.app ~= "" and c.app ~= "?") and (" in " .. c.app) or ""
  local quote = c.evidence or c.action
  if #quote > 120 then quote = quote:sub(1, 117) .. "…" end
  ui.show({
    title = "I noticed something" .. where,
    body = string.format('"%s"\n\nWant a reminder to: %s?', quote, c.action),
    icon = "💡",
    urgency = "warn",
    duration = 20,
    actions = {
      { label = "Yes",      fn = function() accept(c) end },
      { label = "Not mine", fn = function() dismiss(c, "not_mine") end },
      { label = "No",       fn = function() dismiss(c, "dismiss") end },
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

-- Review flow ---------------------------------------------------------------
-- Medium-confidence candidates are never worth an interruption individually,
-- but they are worth *a* moment. The digest batches them into one low-cost
-- ask ("I noticed N things — review?") at a moment the user is already
-- context-switching, and the chooser turns reviewing into a fast keyboard
-- pass. This is the cheap lane: being wrong here costs a keystroke, not trust,
-- which is what makes it safe to surface guesses the card lane can't justify.

function M.review()
  if #M.inbox == 0 then
    ui.toast("Nothing in the suggestion inbox", 1.4)
    return
  end
  local chooser
  chooser = hs.chooser.new(function(choice)
    if not choice then return end
    local c = M.inbox[choice.idx]
    if not c then return end
    if choice.action == "add" then accept(c) else dismiss(c, "dismiss") end
    hs.timer.doAfter(0.2, function() M.review() end) -- keep going through the list
  end)
  local rows = {}
  for i, c in ipairs(M.inbox) do
    rows[#rows + 1] = {
      text = c.action,
      subText = string.format("%.2f · %s · ⏎ add  ·  ⌘⏎ dismiss", c.score or 0, c.source or "?"),
      idx = i,
      action = "add",
    }
  end
  chooser:choices(rows)
  chooser:placeholderText("Suggestions — Enter adds a reminder, ⌘Enter dismisses")
  chooser:rightClickCallback(function(row)
    local c = M.inbox[row]
    if c then dismiss(c, "dismiss"); chooser:hide(); hs.timer.doAfter(0.2, M.review) end
  end)
  chooser:show()
end

-- Batched ask. Deliberately not per-item: one interruption for N guesses.
function M.digest()
  local n = #M.inbox
  if n == 0 then return end
  local preview = {}
  for i = 1, math.min(3, n) do
    local a = M.inbox[i].action
    preview[#preview + 1] = "• " .. ((#a > 58) and (a:sub(1, 55) .. "…") or a)
  end
  log.append({ event = "suggestion.digest", count = n })
  ui.show({
    title = string.format("I noticed %d thing%s you might want reminders for",
      n, n == 1 and "" or "s"),
    body = table.concat(preview, "\n") .. (n > 3 and ("\n… and " .. (n - 3) .. " more") or ""),
    icon = "🗂",
    urgency = "info",
    duration = 18,
    actions = {
      { label = "Review", fn = function() M.review() end },
      { label = "Clear",  fn = function()
          for _, c in ipairs(M.inbox) do M.feedback(c, "dismiss") end
          M.inbox = {}
          if M.onChange then pcall(M.onChange) end
        end },
      { label = "Later" },
    },
  })
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

-- Auto-digest: fires when the user comes back from being away and enough has
-- piled up. Returning from idle is the cheapest possible interruption moment —
-- they are already context-switching, so the digest costs almost nothing.
local lastDigest = 0

local function maybeDigest()
  local d = config.suggestions
  if #M.inbox < d.digestMin then return end
  if os.time() - lastDigest < d.digestCooldown then return end
  if hs.host.idleTime() > 5 then return end -- only right as they return
  lastDigest = os.time()
  M.digest()
end

function M.start()
  if M.running then return end
  if config.suggestions.enabled == false then
    log.append({ event = "suggestions.disabled" })
    return
  end
  M.running = true
  seekToEnd()
  timer = hs.timer.doEvery(config.suggestions.pollInterval, function()
    poll()
    maybeDigest()
  end)
  local obs = require("cr.observer")
  obs.subscribe(function(snap)
    -- returning from a real absence is the digest's natural moment
    if snap.reason == "wake" then maybeDigest() end
  end)
  log.append({ event = "suggestions.start", cursor = cursor })
end

function M.stop()
  if not M.running then return end
  M.running = false
  if timer then timer:stop(); timer = nil end
end

return M
