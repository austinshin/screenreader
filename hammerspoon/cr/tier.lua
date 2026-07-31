-- cr.tier — how loudly a reminder is allowed to speak.
--
--   1 critical   stop what you're doing
--   2 upcoming   a commitment approaching
--   3 in-context relevant because of what's on screen right now
--   4 ambient    background awareness, never interrupts
--
-- The tier is inferred from what you said, not from a time. Two reminders can
-- be due at the same instant and deserve completely different volume.
--
-- IMPORTANT: tier is not a property of the reminder, it is a property of the
-- reminder *right now*. "Take out the trash" is ambient at 2pm, upcoming at
-- 7pm, and critical at 11:55 the night before collection — nothing about it
-- changed except its distance from consequence. So this module computes an
-- opening position; cr.trigger re-evaluates it as context moves. A classifier
-- that stamped a tier once and never revisited would be wrong within the hour.
--
-- Design note: 1 and 4 are never defaults. Ambient is too quiet to be a safe
-- default for something you asked to be reminded of; critical is too loud to
-- assign without evidence. Unbound reminders open at 2, screen-bound at 3.

local M = {}

M.CRITICAL, M.UPCOMING, M.INCONTEXT, M.AMBIENT = 1, 2, 3, 4

M.NAME = { "critical", "upcoming", "in context", "ambient" }

-- Plain-language label + what it implies, for the UI and the decision log.
M.LABEL = {
  [1] = { name = "Critical",   note = "interrupts you as soon as it fires" },
  [2] = { name = "Upcoming",   note = "waits for a natural break" },
  [3] = { name = "In context", note = "waits until you're done with the thing" },
  [4] = { name = "Ambient",    note = "never interrupts — menu bar and dashboard only" },
}

-- Each entry: { pattern, tier, why }. Order matters only within a family;
-- across families the strongest (lowest tier number) match wins, so an urgent
-- phrase beats an informational one in the same sentence.
local SIGNALS = {
  -- consequence: something is lost if this is missed
  { "%f[%a]or i'?ll miss%f[%A]",        1, "you said it has a consequence you'd miss" },
  { "%f[%a]before it closes%f[%A]",     1, "you said something closes" },
  { "%f[%a]before they close%f[%A]",    1, "you said something closes" },
  { "%f[%a]deadline%f[%A]",             1, 'you said "deadline"' },
  { "%f[%a]expires?%f[%A]",             1, "you said something expires" },
  { "%f[%a]last chance%f[%A]",          1, 'you said "last chance"' },
  -- explicit urgency
  { "%f[%a]urgent%f[%A]",               1, 'you said "urgent"' },
  { "%f[%a]asap%f[%A]",                 1, 'you said "asap"' },
  { "%f[%a]critical%f[%A]",             1, 'you said "critical"' },
  { "%f[%a]emergency%f[%A]",            1, 'you said "emergency"' },
  { "%f[%a]right away%f[%A]",           1, 'you said "right away"' },
  { "%f[%a]don'?t forget%f[%A]",        2, 'you said "don\'t forget"' },
  { "%f[%a]make sure%f[%A]",            2, 'you said "make sure"' },
  { "%f[%a]important%f[%A]",            2, 'you said "important"' },
  -- a commitment made to a person
  { "%f[%a]tell%f[%A]",                 2, "it's something you owe a person" },
  { "%f[%a]reply%f[%A]",                2, "it's something you owe a person" },
  { "%f[%a]respond%f[%A]",              2, "it's something you owe a person" },
  { "%f[%a]get back to%f[%A]",          2, "it's something you owe a person" },
  { "%f[%a]follow up%f[%A]",            2, "it's a follow-up you promised" },
  { "%f[%a]send%f[%A]",                 2, "you promised to send something" },
  -- informational: worth knowing, not worth interrupting for
  { "%f[%a]keep an eye on%f[%A]",       4, 'you said "keep an eye on" — that\'s watching, not doing' },
  { "%f[%a]keep track of%f[%A]",        4, "it's something to track, not act on" },
  { "%f[%a]fyi%f[%A]",                  4, 'you said "fyi"' },
  { "%f[%a]note that%f[%A]",            4, "you're noting something, not tasking yourself" },
  { "%f[%a]at some point%f[%A]",        4, 'you said "at some point"' },
  { "%f[%a]eventually%f[%A]",           4, 'you said "eventually"' },
  { "%f[%a]no rush%f[%A]",              4, 'you said "no rush"' },
  { "%f[%a]whenever%f[%A]",             4, 'you said "whenever"' },
}

-- text, hasScreenBinding → tier, why
function M.classify(text, bound)
  local t = (text or ""):lower()
  local best, why
  for _, s in ipairs(SIGNALS) do
    if t:find(s[1]) then
      if not best or s[2] < best then best, why = s[2], s[3] end
    end
  end
  -- A screen binding outranks a tier-2 word. "reply to this thread" contains
  -- "reply", but the binding already says *when* it's relevant — moving it to
  -- "upcoming" would file it under a heading whose trigger it doesn't use.
  -- Only genuine urgency (up) or an explicitly informational phrase (down)
  -- should override where the binding put it.
  if bound then
    if best == M.CRITICAL then return best, why end
    if best == M.AMBIENT then return best, why end
    return M.INCONTEXT, "it's tied to what was on your screen"
  end
  if best then return best, why end
  return M.UPCOMING, "no urgency or context signal — treated as an ordinary commitment"
end

-- Does this tier get to interrupt at all?
function M.interrupts(tier)
  return (tier or M.UPCOMING) <= M.INCONTEXT
end

-- Critical is the only tier allowed past the seam gate. Everything else waits
-- for a natural break, which is the promise that makes this tolerable to leave
-- running all day.
function M.bypassesSeamGate(tier)
  return tier == M.CRITICAL
end

return M
