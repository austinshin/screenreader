-- cr.timeparse — pull a time expression out of reminder text.
--
--   "water the plants in 5 minutes"   → now + 300
--   "get on a meeting at 130"         → today 1:30 PM (or tomorrow if past)
--   "call the vet at 4"               → next 4 o'clock
--   "send it at 5pm august 1"         → Aug 1, 5:00 PM
--
-- Parsed in two independent halves, a DATE and a TIME, then combined. The
-- earlier version matched one pattern for the whole expression, so "at 5pm
-- august 1" matched "at 5pm" and dropped the date on the floor — the reminder
-- fired the same afternoon. Splitting them means either half can be absent:
-- a date alone defaults to 9am, a time alone means its next occurrence.
--
-- Input arrives typed and voice-transcribed. Speech rarely produces a colon —
-- "one thirty" comes back as "130" or "1 30" — so a bare 3-4 digit run after
-- "at" is read as h:mm. Matching happens on a lowercased copy; spans are cut
-- from the ORIGINAL string so typed text keeps its casing.

local M = {}

local WORD_NUMS = {
  a = 1, an = 1, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6,
  seven = 7, eight = 8, nine = 9, ten = 10, eleven = 11, twelve = 12,
  fifteen = 15, twenty = 20, thirty = 30, forty = 40, fifty = 50, sixty = 60,
  ninety = 90,
}

local UNIT_SECONDS = {
  second = 1, seconds = 1, sec = 1, secs = 1,
  minute = 60, minutes = 60, min = 60, mins = 60,
  hour = 3600, hours = 3600, hr = 3600, hrs = 3600,
  day = 86400, days = 86400, week = 604800, weeks = 604800,
}

local MONTHS = {
  january = 1, jan = 1, february = 2, feb = 2, march = 3, mar = 3,
  april = 4, apr = 4, may = 5, june = 6, jun = 6, july = 7, jul = 7,
  august = 8, aug = 8, september = 9, sept = 9, sep = 9, october = 10, oct = 10,
  november = 11, nov = 11, december = 12, dec = 12,
}

local WEEKDAYS = {
  sunday = 1, monday = 2, tuesday = 3, wednesday = 4,
  thursday = 5, friday = 6, saturday = 7,
  sun = 1, mon = 2, tue = 3, tues = 3, wed = 4, thu = 5, thurs = 5, fri = 6, sat = 7,
}

local function num(tok)
  return tonumber(tok) or WORD_NUMS[tok]
end

-- Connectives that belonged to the time phrase and read as garbage once it's
-- gone: "pay rent on august 1" must not leave "pay rent on".
local TRAILING = {
  on = true, at = true, by = true, ["in"] = true, of = true, ["for"] = true,
  this = true, next = true, ["until"] = true, till = true, around = true,
}

-- Remove [s..e] from text, tidy whitespace and dangling connectors.
-- (Lua patterns have no alternation — the earlier "(on|at|by|in)$" silently
-- matched a literal string that never occurs, so nothing was ever trimmed.)
local function cut(text, s, e)
  local out = text:sub(1, s - 1) .. " " .. text:sub(e + 1)
  out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s,]+$", "")
  while true do
    local head, last = out:match("^(.-)%s+(%a+)$")
    if head and head ~= "" and TRAILING[last:lower()] then out = head else break end
  end
  return out
end

-- ------------------------------------------------------------------ date ----
-- Returns {y, m, d}, startIndex, endIndex — or nil.
local function findDate(t)
  local best

  local function consider(s, e, y, m, d)
    if s and (not best or s < best.s) then best = { s = s, e = e, y = y, m = m, d = d } end
  end

  local now = os.date("*t")

  -- "august 1", "aug 1st", "august 1 2026"
  for name, mon in pairs(MONTHS) do
    local s, e, d, yr = t:find("%f[%a]" .. name .. "%f[%A][%s,]+(%d%d?)%a?%a?[%s,]*(%d?%d?%d?%d?)")
    if s then
      consider(s, e, tonumber(yr) ~= nil and #yr == 4 and tonumber(yr) or nil, mon, tonumber(d))
    end
    -- "1 august" / "1st of august"
    local s2, e2, d2 = t:find("(%d%d?)%a?%a?%s+of?%s*%f[%a]" .. name .. "%f[%A]")
    if s2 then consider(s2, e2, nil, mon, tonumber(d2)) end
  end

  -- "8/1", "8/1/2026"
  local s, e, m, d, yr = t:find("%f[%d](%d%d?)/(%d%d?)/?(%d?%d?%d?%d?)%f[%D]")
  if s then consider(s, e, #yr == 4 and tonumber(yr) or nil, tonumber(m), tonumber(d)) end

  -- "tomorrow", "today", "tonight"
  local s3, e3 = t:find("%f[%a]tomorrow%f[%A]")
  if s3 then
    local n = os.date("*t", os.time() + 86400)
    consider(s3, e3, n.year, n.month, n.day)
  end
  local s4, e4 = t:find("%f[%a]toda?y?%f[%A]") or t:find("%f[%a]tonight%f[%A]")
  if s4 then consider(s4, e4, now.year, now.month, now.day) end

  -- "on monday", "next friday" — the coming occurrence
  for name, wd in pairs(WEEKDAYS) do
    local s5, e5 = t:find("%f[%a]" .. name .. "%f[%A]")
    if s5 then
      local delta = (wd - now.wday + 7) % 7
      if delta == 0 then delta = 7 end -- "monday" on a Monday means next Monday
      local n = os.date("*t", os.time() + delta * 86400)
      consider(s5, e5, n.year, n.month, n.day)
    end
  end

  if not best or not best.m or not best.d then return nil end
  return best, best.s, best.e
end

-- ------------------------------------------------------------------ time ----
-- Returns {hour, min, explicit}, startIndex, endIndex — or nil.
-- `explicit` = am/pm was stated, so no next-occurrence guessing is needed.
local function findTime(t)
  local pats = {
    -- with am/pm
    { "%f[%a]at%s+(%d%d?):(%d%d)%s*([ap])%.?m%.?", "hm+ap" },
    { "%f[%d](%d%d?):(%d%d)%s*([ap])%.?m%.?",      "hm+ap" },
    { "%f[%a]at%s+(%d%d?)%s*([ap])%.?m%.?",        "h+ap" },
    { "%f[%d](%d%d?)%s*([ap])%.?m%.?",             "h+ap" },
    -- speech drops the colon: "at 130 pm"
    { "%f[%a]at%s+(%d)(%d%d)%s*([ap])%.?m%.?",     "hm+ap" },
    { "%f[%a]at%s+(%d%d)(%d%d)%s*([ap])%.?m%.?",   "hm+ap" },
    -- no am/pm — resolve to the next occurrence
    { "%f[%a]at%s+(%d%d?):(%d%d)",                 "hm" },
    { "%f[%a]at%s+(%d)(%d%d)%f[%D]",               "hm" },   -- "at 130"
    { "%f[%a]at%s+(%d%d)(%d%d)%f[%D]",             "hm" },   -- "at 1130"
    { "%f[%a]at%s+(%d%d?)%s+(%d%d)%f[%D]",         "hm" },   -- "at 1 30"
    { "%f[%a]at%s+(%d%d?)%f[%D]",                  "h" },    -- "at 4"
    { "%f[%d](%d%d?):(%d%d)",                      "hm" },
    -- "at noon" / "at midnight"
    { "%f[%a]noon%f[%A]",                          "noon" },
    { "%f[%a]midnight%f[%A]",                      "midnight" },
  }
  for _, p in ipairs(pats) do
    local s, e, a, b, c = t:find(p[1])
    if s then
      local kind = p[2]
      if kind == "noon" then return { hour = 12, min = 0, explicit = true }, s, e end
      if kind == "midnight" then return { hour = 0, min = 0, explicit = true }, s, e end
      local hour, min, ap
      if kind == "hm+ap" then hour, min, ap = tonumber(a), tonumber(b), c
      elseif kind == "h+ap" then hour, min, ap = tonumber(a), 0, b
      elseif kind == "hm" then hour, min = tonumber(a), tonumber(b)
      else hour, min = tonumber(a), 0 end
      if hour and hour <= 24 and (min or 0) < 60 then
        if ap == "p" and hour < 12 then hour = hour + 12 end
        if ap == "a" and hour == 12 then hour = 0 end
        return { hour = hour, min = min or 0, explicit = ap ~= nil }, s, e
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------- relative -----
local function findRelative(t)
  local s, e = t:find("%f[%a]in half an hour%f[%A]")
  if s then return os.time() + 1800, s, e end

  local s2, e2, n, unit = t:find("%f[%a]in%s+(%w+)%s+and%s+a%s+half%s+(%a+)")
  if s2 then
    local v, u = num(n), UNIT_SECONDS[unit]
    if v and u then return os.time() + math.floor(v * u + u / 2), s2, e2 end
  end

  -- Speech pads numbers with hedges — "in like five minutes", "in about an
  -- hour". Without these the phrase doesn't parse at all, which matters twice:
  -- the reminder loses its time, and cr.voice can no longer use the time as
  -- the end of the spoken command.
  for _, filler in ipairs({ "", "like%s+", "about%s+", "around%s+", "roughly%s+",
                            "maybe%s+", "just%s+" }) do
    local s3, e3, n3, unit3 = t:find("%f[%a]in%s+" .. filler .. "(%w+)%s+(%a+)")
    if s3 then
      local v, u = num(n3), UNIT_SECONDS[unit3]
      if v and u then return os.time() + v * u, s3, e3 end
    end
  end
  return nil
end

-- ------------------------------------------------------------------ api -----
-- text → cleanText, triggerAt|nil, phrase|nil
function M.extract(text)
  local lower = text:lower()

  -- "in N minutes" is self-contained: it means from *now*, so no date/time
  -- combining applies.
  local rel, rs, re_ = findRelative(lower)
  if rel then return cut(text, rs, re_), rel, text:sub(rs, re_) end

  local date, ds, de = findDate(lower)
  local time, ts, te = findTime(lower)
  if not date and not time then return text, nil, nil end

  local now = os.date("*t")
  local when = {
    year  = date and (date.y or now.year) or now.year,
    month = date and date.m or now.month,
    day   = date and date.d or now.day,
    hour  = time and time.hour or 9,   -- a date with no time means 9am
    min   = time and time.min or 0,
    sec   = 0,
  }
  local at = os.time(when)
  if not at then return text, nil, nil end

  if not date then
    -- Time only. Roll forward to the next occurrence so "at 130" at 1:32pm
    -- means tomorrow, never two minutes ago.
    if not (time and time.explicit) and at <= os.time() and when.hour < 12 then
      at = at + 12 * 3600           -- "at 4" after 4am can still mean 4pm today
    end
    while at <= os.time() do at = at + 86400 end
  elseif at <= os.time() and not date.y then
    -- A bare "august 1" that already passed means next year.
    when.year = when.year + 1
    at = os.time(when) or at
  end

  -- Cut the later span first so the earlier index stays valid.
  local out = text
  local spans = {}
  if date then spans[#spans + 1] = { ds, de } end
  if time then spans[#spans + 1] = { ts, te } end
  table.sort(spans, function(a, b) return a[1] > b[1] end)
  local phrase = {}
  for _, sp in ipairs(spans) do
    phrase[#phrase + 1] = lower:sub(sp[1], sp[2])
    out = cut(out, sp[1], sp[2])
  end
  return out, at, table.concat(phrase, " ")
end

-- "in 4 min (5:23 PM)" / "Fri 9:00 AM" — for toasts and logs
function M.fmtDue(triggerAt)
  if not triggerAt then return nil end
  local delta = triggerAt - os.time()
  local clock = os.date("%I:%M %p", triggerAt):gsub("^0", "")
  local rel
  if delta < 0 then rel = "now"
  elseif delta < 90 then rel = delta .. "s"
  elseif delta < 5400 then rel = math.floor(delta / 60 + 0.5) .. " min"
  elseif delta < 129600 then rel = (string.format("%.1f", delta / 3600):gsub("%.0$", "")) .. " hr"
  else rel = math.floor(delta / 86400 + 0.5) .. " days" end
  local day = ""
  if os.date("%x", triggerAt) ~= os.date("%x") then
    day = os.date("%a %b %d, ", triggerAt)
  end
  return string.format("%s%s (in %s)", day, clock, rel)
end

return M
