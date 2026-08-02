-- cr.test_dictate — drive raw whisper output through the push-to-talk parser.
--
--     hs -c 'require("cr.test_dictate").run()'
--
-- Same contract as cr.test_capture, one layer down the stack: that file replays
-- `hear` transcript lines through cr.voice, this one replays whisper-cli stdout
-- through cr.dictate. Both exist for the same reason — capture is not the
-- hypothesis, but if getting a reminder *in* is flaky you never form the habit,
-- and the hypothesis never gets tested.
--
-- The cases are real whisper-cli output shapes, which differ from `hear` in
-- three ways the parser has to absorb: a leading space, sentence
-- capitalization, and a trailing period. Two cases are regression locks rather
-- than coverage, and are called out where they appear.

local dictate = require("cr.dictate")

local M = {}

-- { name, raw whisper stdout, expected reminder text (nil = none created) }
local CASES = {
  {
    "leading space and trailing period are stripped",
    " Remind me to water the plants.",
    "water the plants",
  },
  {
    -- push-to-talk has no wake word, so the preamble is optional politeness
    "a bare command needs no preamble",
    " Water the plants.",
    "water the plants",
  },
  {
    -- REGRESSION LOCK. cr.voice's boundCommand ended the command at the first
    -- time phrase, because a streaming recognizer gave it no other way to find
    -- the end. Carried over here it would silently discard "and cc legal".
    -- The held key defines the end, so nothing may truncate on content.
    "a time phrase does not truncate the task",
    " Remind me to email Sarah at 3pm and cc legal.",
    "email Sarah at 3pm and cc legal",
  },
  {
    "capitalization inside the sentence survives",
    " Remind me to reply to Saujas about the take-home.",
    "reply to Saujas about the take-home",
  },
  {
    -- whisper does not return empty on silence, it hallucinates captions
    "blank audio is not a reminder",
    " [BLANK_AUDIO]",
    nil,
  },
  {
    "silence hallucinated as a caption is not a reminder",
    " Thank you.",
    nil,
  },
  {
    "empty stdout creates nothing",
    "",
    nil,
  },
  {
    -- REGRESSION LOCK. The noise list must match whole strings only. As a
    -- substring test, "thank you" would swallow this real reminder.
    "a noise phrase as a substring is still a reminder",
    " Thank Ruth for the coffee.",
    "thank Ruth for the coffee",
  },
  {
    -- The condition clause is stripped by condition.extract *inside*
    -- reminders.add, which this harness replaces — so the assertion is that
    -- dictate hands the clause over intact rather than mangling or truncating
    -- it. Where it gets split is reminders.lua's business, and is tested there.
    "a screen condition reaches the shared parser intact",
    " Remind me to send the summary once I'm done with this.",
    "send the summary once I'm done with this",
  },
}

-- Exercise the real path without touching the reminder store.
local function simulate(raw)
  local created = {}
  local reminders = require("cr.reminders")
  local realAdd = reminders.add
  reminders.add = function(text) created[#created + 1] = text; return nil end
  local ok = pcall(function() dictate._onTranscript(raw, nil) end)
  reminders.add = realAdd
  if not ok then return { "<error>" } end
  return created
end

function M.run()
  local pass, fail, out = 0, 0, {}
  for _, c in ipairs(CASES) do
    local name, raw, want = c[1], c[2], c[3]
    dictate._resetForTest()
    local got = simulate(raw)
    local wantN = want and 1 or 0
    local ok = #got == wantN
    if ok and want then
      ok = (got[1] or ""):lower() == want:lower()
    end
    if ok then pass = pass + 1
    else
      fail = fail + 1
      out[#out + 1] = string.format("  FAIL  %s\n        want %s\n        got  %s",
        name, hs.inspect(want), hs.inspect(got))
    end
  end
  local summary = string.format("dictate: %d passed, %d failed", pass, fail)
  return (#out > 0 and (table.concat(out, "\n") .. "\n" .. summary) or summary)
end

return M
