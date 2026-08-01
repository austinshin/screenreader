-- cr.watchfor — conditions about the world, not about you.
--
-- The existing trigger answers one shape: "once I'm done with THIS". That maps
-- cleanly onto window presence — the thing leaves the screen, you're done, fire.
-- Structured, cheap, and reliable, because window titles are real data.
--
-- "merge the PR after the tests run" is a different animal. The subject isn't
-- you, it's the tests; the event isn't a window closing, it's *text on screen
-- changing state*. That means OCR instead of titles, and probabilistic
-- matching instead of an identity check. Strictly harder, strictly noisier,
-- and the only way to cover the conditions people actually say.
--
-- THE SAME PRINCIPLE CARRIES OVER, and it is the whole reason this works:
-- edge-triggered, never level-triggered. "Tests passed" is very likely already
-- on screen when you say the sentence — the last run's output is still sitting
-- in the terminal. A level check fires instantly on stale output and looks
-- broken. So a content condition must first see the subject *pending*, and
-- only then see it *finished*:
--
--     ARMED ──sees "running"──▶ SEEN_PENDING ──sees "passed"──▶ FIRE
--
-- Limitation worth stating plainly: OCR reads the focused window, so a test
-- run in a background terminal is invisible until you look at it. In practice
-- you do look — but a reminder that depends on you glancing at the thing is a
-- weaker promise than one that doesn't, and it should be described that way.

local M = {}

-- "after the tests run" → subject "tests". Deliberately narrow: a condition
-- whose subject can't be named can't be watched, and guessing produces a
-- reminder that fires on nothing in particular.
local LEAD = {
  "after the ([%w%s%-_%.]+) ",
  "once the ([%w%s%-_%.]+) ",
  "when the ([%w%s%-_%.]+) ",
  "after ([%w%s%-_%.]+) finish",
  "once ([%w%s%-_%.]+) finish",
  "when ([%w%s%-_%.]+) finish",
}

-- Verbs that mean "this thing has a running state and a finished state".
local COMPLETION_VERBS = {
  run = true, runs = true, ran = true, finish = true, finishes = true,
  finished = true, complete = true, completes = true, completed = true,
  pass = true, passes = true, passed = true, build = true, builds = true,
  deploy = true, deploys = true, ["end"] = true, ends = true, done = true,
  succeed = true, succeeds = true, land = true, lands = true, merge = true,
}

local STOP_SUBJ = { the = true, a = true, an = true, my = true, this = true, that = true }

-- Evidence that the subject is *in progress*. Seeing this is what arms the
-- condition, and is what stops stale output from firing it immediately.
local PENDING = {
  "running", "building", "deploying", "in progress", "pending", "queued",
  "compiling", "installing", "waiting", "started", "executing", "%.%.%.",
}

-- Evidence that it is *over*. Deliberately includes failure: "after the tests
-- run" means when they stop running, not when they succeed — a reminder that
-- only fires on green would silently never arrive on the day it matters most.
local DONE = {
  "passed", "failed", "failing", "succeeded", "success", "complete", "completed",
  "finished", "done", "error", "errors", "✓", "✗", "✔", "✘",
  "%d+ passed", "%d+ failed", "exit code", "exit status",
  "ran %d+ test", "tests?:", "build succeeded", "build failed",
  "no tests", "all checks", "checks passed", "checks failed",
}

local function norm(s)
  return (s or ""):lower()
end

-- text → { subject = "tests", phrase = "after the tests run" } or nil
function M.parse(text)
  local t = norm(text)
  for _, pat in ipairs(LEAD) do
    local s, e, subj = t:find(pat)
    if subj then
      -- the word right after the subject decides whether this is a completion
      local tail = t:sub(e):match("^%s*(%a+)") or t:sub(s, e):match("(%a+)%s*$")
      subj = subj:gsub("^%s+", ""):gsub("%s+$", "")
      -- drop leading articles so "the tests" and "tests" are one subject
      local first = subj:match("^(%a+)")
      if first and STOP_SUBJ[first] then
        subj = subj:gsub("^%a+%s+", "")
      end
      if #subj >= 2 and #subj <= 40 and (COMPLETION_VERBS[tail or ""] or COMPLETION_VERBS[subj:match("(%a+)$") or ""]) then
        -- cut the condition out of the task text
        local phrase = text:sub(s):gsub("%s+$", "")
        local task = text:sub(1, s - 1):gsub("[%s,]+$", "")
        if #task >= 3 then
          return { subject = subj, phrase = phrase, task = task }
        end
      end
    end
  end
  return nil
end

local function anyMatch(haystack, list)
  for _, p in ipairs(list) do
    if haystack:find(p) then return p end
  end
  return nil
end

-- Does this capture say the subject is running, finished, or neither?
-- Returns "pending" | "done" | nil, and the evidence line.
function M.classify(captureText, subject)
  local subj = norm(subject)
  -- the head word carries the identity: "unit tests" still matches "tests"
  local head = subj:match("(%a+)$") or subj
  for line in (captureText or ""):gmatch("[^\n]+") do
    local l = norm(line)
    if l:find(head, 1, true) or l:find(subj, 1, true) then
      if anyMatch(l, DONE) then return "done", line:sub(1, 120) end
      if anyMatch(l, PENDING) then return "pending", line:sub(1, 120) end
    end
  end
  -- A finished run often stops naming the subject at all ("12 passed, 0
  -- failed"), so accept a strong completion line near a subject we already saw
  -- pending. Checked by the caller, which knows whether that happened.
  for line in (captureText or ""):gmatch("[^\n]+") do
    local l = norm(line)
    if l:find("%d+ passed") or l:find("%d+ failed") or l:find("exit code")
       or l:find("build succeeded") or l:find("build failed") then
      return "done_generic", line:sub(1, 120)
    end
  end
  return nil, nil
end

-- Feed one OCR capture to every reminder waiting on content. Called from the
-- capture hook; returns the reminders that just became satisfied.
function M.evaluate(captureText, reminders, log)
  local fired = {}
  for _, r in ipairs(reminders) do
    local w = r.watchFor
    if w and r.state == "pending" or (w and r.state == "armed") then
      local kind, evidence = M.classify(captureText, w.subject)
      if kind == "pending" and not w.seenPending then
        w.seenPending = true
        w.pendingAt = os.time()
        w.evidence = evidence
        if log then
          log.append({ event = "watchfor.pending", id = r.id,
                       subject = w.subject, evidence = evidence })
        end
      elseif (kind == "done" or (kind == "done_generic" and w.seenPending))
             and w.seenPending then
        w.doneAt = os.time()
        w.evidence = evidence
        fired[#fired + 1] = { reminder = r, evidence = evidence }
        if log then
          log.append({ event = "watchfor.done", id = r.id,
                       subject = w.subject, evidence = evidence })
        end
      end
    end
  end
  return fired
end

return M
