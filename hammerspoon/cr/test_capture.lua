-- cr.test_capture — replay recorded transcripts through the voice pipeline.
--
--     hs -c 'require("cr.test_capture").run()'
--
-- Capture is the part of this prototype that has to be boring and reliable. It
-- isn't the hypothesis — the hypothesis is whether screen context can pick the
-- right moment — but if capturing a reminder is flaky you never build the
-- habit, never use the thing daily, and never get to test the hypothesis at
-- all. So it gets the same treatment as the gate: recorded real input, an
-- expected result, and a number that regresses loudly.
--
-- Every case below is a real transcript sequence taken from
-- ~/Library/Logs/cr-voice/voice-transcript.log, including the one that
-- produced two reminders from one sentence during a live demo. `hear` streams
-- a growing line per update, so a case is the list of updates, and the
-- assertion is on what the pipeline *would* create at the end.

local voice = require("cr.voice")

local M = {}

-- { name, {transcript lines…}, expected reminders (nil = none) }
local CASES = {
  {
    "one command, one reminder",
    { "hey screen reader remind me to",
      "hey screen reader remind me to water",
      "hey screen reader remind me to water the plants" },
    { "water the plants" },
  },
  {
    -- the live-demo failure: the utterance never ended, and the recognizer
    -- revised earlier words so the prefix-based dupe guard missed
    "rambling on a call still yields one reminder",
    -- Reconstructed: the stored reminders are verbatim, but the wake word that
    -- must have preceded them is inferred, because the transcript log was
    -- being truncated on every start (fixed — it now keeps a rolling tail).
    { "hey screen reader do remind me to create a grocery list in like five minutes ok because",
      "hey screen reader do remind me to create a grocery list in like five minutes ok because it s because we re on the call right now it would trigger and it would show and it would create a reminder what are you using for transcription you just have",
      "hey screen reader do remind me to create a grocery list in like five minutes because it s because we re on the call right now it would trigger and it would show and then it would create a reminder what are you using for transcription you just have like something" },
    { "create a grocery list in like five minutes" },
  },
  {
    "utterance split across two lines keeps its time",
    { "it screen reader remind me to send a video later in", "like 12 PM" },
    { "send a video later at 12 pm" },
  },
  {
    "no wake word, nothing captured",
    { "so anyway i was saying remind me that it never works" },
    nil,
  },
  {
    "wake word without a command is not a reminder",
    { "have you tried a screen reader yet" },
    nil,
  },
}

-- Drive _parse/_ingest without touching the real reminder store: the pipeline
-- is exercised, the side effect is captured.
local function simulate(lines)
  local created = {}
  local realAdd = require("cr.reminders").add
  require("cr.reminders").add = function(text) created[#created + 1] = text; return nil end
  local okAll = pcall(function()
    for _, l in ipairs(lines) do voice._ingest(l) end
    voice._settleNow()   -- fire whatever is pending, without waiting on a timer
  end)
  require("cr.reminders").add = realAdd
  if not okAll then return { "<error>" } end
  return created
end

function M.run()
  local pass, fail, out = 0, 0, {}
  for _, c in ipairs(CASES) do
    local name, lines, want = c[1], c[2], c[3]
    voice._resetForTest()
    local got = simulate(lines)
    local wantN = want and #want or 0
    local ok = #got == wantN
    if ok and want then
      for i, w in ipairs(want) do
        if (got[i] or ""):lower() ~= w:lower() then ok = false end
      end
    end
    if ok then pass = pass + 1
    else
      fail = fail + 1
      out[#out + 1] = string.format("  FAIL  %s\n        want %d %s\n        got  %d %s",
        name, wantN, hs.inspect(want or {}), #got, hs.inspect(got))
    end
  end
  local summary = string.format("capture: %d passed, %d failed", pass, fail)
  return (#out > 0 and (table.concat(out, "\n") .. "\n" .. summary) or summary)
end

return M
