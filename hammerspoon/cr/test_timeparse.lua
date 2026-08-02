-- cr.test_timeparse — drive reminder phrasings through the time parser.
--
--     hs -c 'require("cr.test_timeparse").run()'
--
-- Same contract as cr.test_dictate, one module over: real phrasings in,
-- assertions on the task text and trigger time out. timeparse earns this
-- harness by its failure mode: it fails *silently*, falling back to a
-- contextual reminder — which is how "at 130" once became "four seconds from
-- now", and how "buy milk today" once crashed extraction outright (a
-- multi-value find truncated by `or`; the regression lock below).
--
-- Times are asserted structurally (month, day, hour, "in the future") rather
-- than as absolute epochs, so the suite passes at any time of day.

local timeparse = require("cr.timeparse")

local M = {}

-- Each case: { name, input, check(clean, at, phrase) → ok, detail }
local CASES = {
  {
    "a plain task passes through untouched",
    "reply to the thread",
    function(clean, at)
      if at then return false, "found a time in a sentence without one" end
      if clean ~= "reply to the thread" then return false, "text changed: " .. clean end
      return true
    end,
  },
  {
    -- REGRESSION LOCK. `find(a) or find(b)` truncates a multi-value return to
    -- one value, so the end index came back nil and cut() crashed on it — the
    -- reminder was silently lost. And once un-crashed, a bare "today" after
    -- 9am must not resolve to a time already past, or it fires on creation.
    '"today" parses, and never lands in the past',
    "buy milk today",
    function(clean, at)
      if clean ~= "buy milk" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      if at <= os.time() then return false, "scheduled in the past" end
      if at - os.time() > 86400 then return false, "more than a day out: " .. os.date("%c", at) end
      return true
    end,
  },
  {
    '"tonight" means this evening, and never the past',
    "water the plants tonight",
    function(clean, at)
      if clean ~= "water the plants" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      if at <= os.time() then return false, "scheduled in the past" end
      if at - os.time() > 86400 then return false, "more than a day out: " .. os.date("%c", at) end
      return true
    end,
  },
  {
    -- the "four seconds from now" incident: speech drops the colon
    '"at 130" reads as 1:30, next occurrence',
    "get on a meeting at 130",
    function(clean, at)
      if clean ~= "get on a meeting" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      if at <= os.time() then return false, "scheduled in the past" end
      local d = os.date("*t", at)
      if d.min ~= 30 or (d.hour % 12) ~= 1 then
        return false, "not 1:30: " .. os.date("%H:%M", at)
      end
      return true
    end,
  },
  {
    -- date and time are independent halves; the one-pattern version matched
    -- "at 5pm", dropped the date, and fired the same afternoon
    '"at 5pm august 1" keeps both halves',
    "send it at 5pm august 1",
    function(clean, at)
      if clean ~= "send it" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      local d = os.date("*t", at)
      if d.month ~= 8 or d.day ~= 1 or d.hour ~= 17 then
        return false, "wrong moment: " .. os.date("%c", at)
      end
      return true
    end,
  },
  {
    '"at 4" means the next 4 o\'clock',
    "call the vet at 4",
    function(clean, at)
      if clean ~= "call the vet" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      if at <= os.time() then return false, "scheduled in the past" end
      local d = os.date("*t", at)
      if (d.hour % 12) ~= 4 or d.min ~= 0 then
        return false, "not 4 o'clock: " .. os.date("%H:%M", at)
      end
      return true
    end,
  },
  {
    -- speech pads numbers with hedges; losing the phrase loses the time
    "relative time with filler survives",
    "stretch in like five minutes",
    function(clean, at)
      if clean ~= "stretch" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      local delta = at - os.time()
      if delta < 290 or delta > 310 then
        return false, "expected ~300s out, got " .. tostring(delta)
      end
      return true
    end,
  },
  {
    -- cutting the phrase must also take its connective: "pay rent on" is not
    -- a task anyone set
    "a dangling connective is trimmed with the date",
    "pay rent on august 1",
    function(clean, at)
      if clean ~= "pay rent" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      local d = os.date("*t", at)
      if d.month ~= 8 or d.day ~= 1 or d.hour ~= 9 then
        return false, "wrong moment: " .. os.date("%c", at)
      end
      return true
    end,
  },
  {
    -- an explicit time is the user's own words: if it already passed, firing
    -- late and saying so beats silently moving it to the evening
    '"today" with an explicit time keeps that time',
    "submit the report today at 11:59pm",
    function(clean, at)
      if clean ~= "submit the report" then return false, "task: " .. tostring(clean) end
      if not at then return false, "no time extracted" end
      local d = os.date("*t", at)
      if d.hour ~= 23 or d.min ~= 59 then
        return false, "wrong time: " .. os.date("%H:%M", at)
      end
      return true
    end,
  },
}

function M.run()
  local pass, fail, out = 0, 0, {}
  for _, c in ipairs(CASES) do
    local name, input, check = c[1], c[2], c[3]
    local okCall, clean, at, phrase = pcall(timeparse.extract, input)
    local ok, detail
    if okCall then
      ok, detail = check(clean, at, phrase)
    else
      ok, detail = false, "threw: " .. tostring(clean)
    end
    if ok then pass = pass + 1
    else
      fail = fail + 1
      out[#out + 1] = string.format('  FAIL  %s\n        "%s" — %s',
        name, input, detail or "?")
    end
  end
  local summary = string.format("timeparse: %d passed, %d failed", pass, fail)
  return (#out > 0 and (table.concat(out, "\n") .. "\n" .. summary) or summary)
end

return M
