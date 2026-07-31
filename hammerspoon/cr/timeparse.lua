-- cr.timeparse — pull a time expression out of reminder text.
--
--   "water the plants in 5 minutes"  → "water the plants", now+300, "in 5 minutes"
--   "call mom at 3pm"                → "call mom", today 15:00 (or tomorrow), "at 3pm"
--   "stretch in half an hour"        → "stretch", now+1800, "in half an hour"
--
-- Input arrives two ways: typed (any case, punctuation) and voice-transcribed
-- (lowercased, punctuation stripped, numbers usually digits but sometimes
-- words). Matching happens on a lowercased copy; the span is removed from the
-- ORIGINAL string so typed text keeps its casing.

local M = {}

local WORD_NUMS = {
  a = 1, an = 1, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6,
  seven = 7, eight = 8, nine = 9, ten = 10, fifteen = 15, twenty = 20,
  thirty = 30, forty = 40, fifty = 50, sixty = 60, ninety = 90,
}

local UNIT_SECONDS = {
  second = 1, seconds = 1, sec = 1, secs = 1,
  minute = 60, minutes = 60, min = 60, mins = 60,
  hour = 3600, hours = 3600, hr = 3600, hrs = 3600,
  day = 86400, days = 86400,
}

local function num(tok)
  return tonumber(tok) or WORD_NUMS[tok]
end

-- Remove [s..e] from text and tidy whitespace/dangling connectors.
local function cut(text, s, e)
  local out = (text:sub(1, s - 1) .. " " .. text:sub(e + 1))
  out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  out = out:gsub("[%s,]+$", "")
  return out
end

-- next occurrence of hour:min; if am/pm omitted, pick the soonest future one
local function clockTime(h, min, ampm)
  min = min or 0
  local now = os.time()
  local t = os.date("*t", now)
  local function at(hour)
    return os.time({ year = t.year, month = t.month, day = t.day,
                     hour = hour, min = min, sec = 0 })
  end
  if ampm == "pm" and h < 12 then h = h + 12 end
  if ampm == "am" and h == 12 then h = 0 end
  local when = at(h)
  if not ampm and h <= 12 then
    -- "at 5" → 5am or 5pm, whichever comes next
    if when <= now and h + 12 < 24 then when = at(h + 12) end
  end
  if when <= now then when = when + 86400 end -- tomorrow
  return when
end

-- Each rule: pattern over the lowercased text + a resolver for its captures.
-- Ordered: more specific first.
local RULES = {
  { pat = "in half an hour", fn = function() return os.time() + 1800 end },
  { pat = "in (%w+) and a half (%a+)", fn = function(n, unit)
      local v, u = num(n), UNIT_SECONDS[unit]
      if v and u then return os.time() + math.floor(v * u + u / 2) end
    end },
  { pat = "in (%w+) (%a+)", fn = function(n, unit)
      local v, u = num(n), UNIT_SECONDS[unit]
      if v and u then return os.time() + v * u end
    end },
  { pat = "tomorrow at (%d%d?):?(%d?%d?) ?([ap]?m?)", fn = function(h, mi, ap)
      local when = clockTime(tonumber(h), tonumber(mi), ap ~= "" and ap or nil)
      local t = os.date("*t")
      local tomorrow = os.time({ year = t.year, month = t.month, day = t.day + 1,
                                 hour = 0, min = 0, sec = 0 })
      while when < tomorrow do when = when + 86400 end
      return when
    end },
  { pat = "tomorrow", fn = function()
      local t = os.date("*t")
      return os.time({ year = t.year, month = t.month, day = t.day + 1,
                       hour = 9, min = 0, sec = 0 }) -- tomorrow 9am
    end },
  { pat = "tonight", fn = function()
      local t = os.date("*t")
      local when = os.time({ year = t.year, month = t.month, day = t.day,
                             hour = 20, min = 0, sec = 0 })
      if when <= os.time() then when = when + 3600 end -- it's past 8pm: in an hour
      return when
    end },
  { pat = "at (%d%d?):(%d%d) ?([ap]?m?)", fn = function(h, mi, ap)
      return clockTime(tonumber(h), tonumber(mi), ap ~= "" and ap or nil)
    end },
  { pat = "at (%d%d?) ?([ap]m)", fn = function(h, ap)
      return clockTime(tonumber(h), 0, ap)
    end },
}

-- text → cleanText, dueAt|nil, phrase|nil
function M.extract(text)
  local lower = text:lower()
  for _, rule in ipairs(RULES) do
    local s, e, c1, c2, c3 = lower:find(rule.pat)
    if s then
      local due = rule.fn(c1, c2, c3)
      if due and due > os.time() then
        return cut(text, s, e), due, text:sub(s, e)
      end
    end
  end
  return text, nil, nil
end

-- "in 4 min (5:23 PM)" / "tomorrow 9:00 AM" — for toasts and logs
function M.fmtDue(dueAt)
  if not dueAt then return nil end
  local delta = dueAt - os.time()
  local clock = os.date("%I:%M %p", dueAt):gsub("^0", "")
  local rel
  if delta < 90 then rel = delta .. "s"
  elseif delta < 5400 then rel = math.floor(delta / 60 + 0.5) .. " min"
  elseif delta < 129600 then rel = string.format("%.1f hr", delta / 3600):gsub("%.0", "")
  else rel = math.floor(delta / 86400 + 0.5) .. " days" end
  local day = ""
  if os.date("%x", dueAt) ~= os.date("%x") then day = os.date("%a ", dueAt) end
  return string.format("in %s (%s%s)", rel, day, clock)
end

return M
