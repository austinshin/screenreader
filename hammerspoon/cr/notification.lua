-- cr.notification — the wire format every channel speaks.
--
-- Before this module each remote channel invented its own message. Discord
-- built a markdown string, Slack built a different markdown string, and the
-- generic webhook posted `wirePayload` — a private helper with no timestamp,
-- no event type, no schema version, and the reminder id buried inside `meta`.
-- Three formatters meant adding a fourth channel was writing a fourth
-- formatter, and it meant a receiver could not tell what it had been sent.
--
-- So the payload and the wire object are now different things, deliberately:
--
--   payload — internal, carries Lua closures in `actions`, used by the card
--   note    — this module's output, pure data, safe to JSON-encode and send
--
-- The split is what lets a channel be a *translator* rather than an author. A
-- new channel formats an object whose shape it can rely on, instead of
-- reaching into a reminder and deciding for itself what matters.
--
-- Four choices in the schema are worth stating, because each one is cheap now
-- and expensive to add later:
--
--   * A versioned envelope (schema/id/ts/event). A receiver that cannot tell
--     what it got, or when, has to guess — and guessing is what breaks when
--     the format later changes.
--   * Actions carry an `id`, not just a label. Labels are for humans and get
--     reworded ("Too early" became "5 min" during this project). An id is the
--     only thing that makes a reply addressable, so two-way channels become a
--     feature rather than a breaking change.
--   * `trigger.why` travels. On a phone there is no screen context to explain
--     why something arrived, which makes the one-line reason the single most
--     valuable field in the object.
--   * `tier` travels. A channel can then decide that ambient never reaches
--     your phone without needing to know what ambient means.

local tier = require("cr.tier")

local M = {}

M.SCHEMA = "cr.notification/v1"

-- Labels are written for people and get reworded; ids must not move when they
-- do. Derived only as a fallback — an action that matters should name itself.
local function slug(label)
  local s = (label or ""):lower():gsub("[^%a%d]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or "action"
end

local function host()
  local ok, name = pcall(function() return hs.host.localizedName() end)
  return (ok and name) or "mac"
end

-- payload: what notifier.notify was handed (may contain closures)
-- opts:    { event, reminder, trigger = { gate, why }, channels }
function M.build(payload, opts)
  payload = payload or {}
  opts = opts or {}
  local r = opts.reminder
  local now = os.time()

  local actions = {}
  for _, a in ipairs(payload.actions or {}) do
    actions[#actions + 1] = { id = a.id or slug(a.label), label = a.label }
  end

  local level = (r and r.tier) or tier.UPCOMING
  local subjectId = (r and r.id) or (payload.meta and payload.meta.id)

  return {
    schema = M.SCHEMA,
    -- prefixed and subject-scoped so a receiver can dedupe retries without
    -- needing to compare bodies
    id = string.format("ntf_%d_%s", now, subjectId or "adhoc"),
    ts = now,
    iso = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
    event = opts.event or "notification",

    title = payload.title,
    body = payload.body,
    icon = payload.icon,
    urgency = payload.urgency or "info",

    tier = { level = level, name = tier.NAME[level] or "upcoming" },
    trigger = opts.trigger and {
      gate = opts.trigger.gate,
      why = opts.trigger.why,
    } or nil,
    subject = {
      kind = r and "reminder" or "message",
      id = subjectId,
      bound_to = (r and r.referent and r.referent.label)
        or (payload.meta and payload.meta.referent),
      created_at = r and r.createdAt,
      due_at = r and r.dueAt,
    },
    actions = actions,
    source = { app = "contextual-reminders", host = host() },
  }
end

-- One line of prose carrying the whole object, for channels that are a text
-- box rather than a structured API. Kept here so Discord, Slack, and Telegram
-- cannot drift into three different renderings of the same notification.
function M.toText(note, opts)
  opts = opts or {}
  local bold = opts.bold or "*"
  local lines = {}
  lines[#lines + 1] = string.format("%s %s%s%s",
    note.icon or "🔔", bold, note.title or "Reminder", bold)
  if note.body and note.body ~= "" then lines[#lines + 1] = note.body end
  if note.trigger and note.trigger.why then
    lines[#lines + 1] = "↳ " .. note.trigger.why
  end
  -- Actions are named even where they aren't tappable: knowing the choices
  -- exist tells you the reminder is still waiting on the Mac rather than gone.
  if #(note.actions or {}) > 0 then
    local labels = {}
    for _, a in ipairs(note.actions) do labels[#labels + 1] = a.label end
    lines[#lines + 1] = "· " .. table.concat(labels, " · ")
  end
  return table.concat(lines, "\n")
end

return M
