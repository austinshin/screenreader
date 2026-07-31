-- cr.condition — split "what to remind me" from "when to surface it".
--
-- The brief's own examples all carry the trigger inside the sentence:
--
--   "remind me to look into embeddings after I finish watching this video"
--   "once I'm done testing the gate, remind me to share progress in #eng"
--   "when I wrap up this conversation on Slack, remind me to update Megan"
--
-- The tail is a *condition*, not part of the task. Left in, it becomes the
-- text on the card — and a card that fires when you close the video and then
-- says "after I finish watching this video" is telling you something you can
-- already see, in place of the thing you actually wanted to remember.
--
-- What the condition names ("this video", "this conversation on Slack") is
-- almost always the thing already on screen, which is what the reminder binds
-- to anyway. So v1 uses it two ways: strip it from the task text, and keep it
-- verbatim so the decision log can show the sentence next to the window it
-- resolved to. That pairing is what makes a wrong binding visible instead of
-- mysterious.

local M = {}

-- Ordered: longest/most specific first, since "done with" also matches "done".
-- Lua patterns have no alternation, so each phrasing is its own entry.
local LEADING = {   -- condition first: "once I'm done X, remind me to Y"
  "^once i'?m? ?a?m? done[^,]*,%s*",
  "^once i finish[^,]*,%s*",
  "^after i'?m? ?a?m? done[^,]*,%s*",
  "^after i finish[^,]*,%s*",
  "^when i'?m? ?a?m? done[^,]*,%s*",
  "^when i finish[^,]*,%s*",
  "^when i wrap up[^,]*,%s*",
  "^after this[^,]*,%s*",
  "^when this[^,]*,%s*",
}

local TRAILING = {  -- condition last: "remind me to Y after I finish X"
  "%s+once i'?m? ?a?m? done .*$",
  "%s+once i finish .*$",
  "%s+after i'?m? ?a?m? done .*$",
  "%s+after i finish .*$",
  "%s+after i'?m? done .*$",
  "%s+when i'?m? ?a?m? done .*$",
  "%s+when i finish .*$",
  "%s+when i wrap up .*$",
  "%s+when i close .*$",
  "%s+after i close .*$",
  "%s+after this .*$",
  "%s+when this .*$",
  "%s+once this .*$",
  "%s+after i'?m? out of .*$",
}

-- text → cleanText, conditionPhrase|nil
function M.extract(text)
  local lower = text:lower()
  for _, pat in ipairs(LEADING) do
    local s, e = lower:find(pat)
    if s then
      local phrase = text:sub(s, e):gsub("[%s,]+$", "")
      local rest = text:sub(e + 1)
      if #rest >= 3 then return rest, phrase end
    end
  end
  for _, pat in ipairs(TRAILING) do
    local s, e = lower:find(pat)
    if s then
      local phrase = text:sub(s, e):gsub("^%s+", "")
      local rest = text:sub(1, s - 1):gsub("[%s,]+$", "")
      if #rest >= 3 then return rest, phrase end
    end
  end
  return text, nil
end

return M
