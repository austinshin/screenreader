-- cr.hotkeys — one registry every keybinding is read from.
--
-- Previously the chords lived in three places: the hs.hotkey.bind calls, the
-- cheatsheet panel, and the menu bar. Three copies of the same fact drift the
-- moment one changes — the menu bar advertised ⌃⌥⌘R for a week after that
-- binding moved. Once bindings are user-editable, drift stops being cosmetic
-- and starts being a lie: a cheatsheet that prints a chord which no longer
-- works is worse than no cheatsheet.
--
-- So: this module owns the list, resolves user overrides on top of it, does
-- the binding, and hands the resolved set to anything that displays it.
--
-- Overrides persist to data/hotkeys.json. The defaults stay in code, so a
-- corrupt or deleted overrides file degrades to a working keyboard rather
-- than none.

local config = require("cr.config")
local log = require("cr.log")

local M = { handlers = {}, bound = {} }

-- id, label, and the default chord. `label` is what a person reads, so it is
-- phrased as the thing you want, not the function that does it.
M.ACTIONS = {
  { id = "reminder", label = "New reminder",             mods = { "ctrl", "alt", "cmd" }, key = "n" },
  { id = "glance",   label = "Show my reminders",        mods = { "cmd", "alt", "shift" }, key = "r" },
  { id = "voice",    label = "Switch capture mode",       mods = { "ctrl", "alt", "cmd" }, key = "m" },
  { id = "ocr",      label = "Read this window once",    mods = { "ctrl", "alt", "cmd" }, key = "s" },
  { id = "watch",    label = "Watch mode (auto-read)",   mods = { "ctrl", "alt", "cmd" }, key = "w" },
  { id = "viewer",   label = "See what it read",         mods = { "ctrl", "alt", "cmd" }, key = "v" },
  { id = "review",   label = "Review suggestions",       mods = { "ctrl", "alt", "cmd" }, key = "i" },
  { id = "context",  label = "Where am I right now",     mods = { "ctrl", "alt", "cmd" }, key = "c" },
  { id = "test",     label = "Send a test card",         mods = { "ctrl", "alt", "cmd" }, key = "t" },
  { id = "keys",     label = "Hotkey cheatsheet",        mods = { "ctrl", "alt", "cmd" }, key = "k" },
  -- `hold = true` is part of the chord's description, not a detail of the
  -- handler: this whole module exists so a chord is described in exactly one
  -- place, and "you hold this one rather than tapping it" is something the
  -- cheatsheet and the dashboard have to be able to say.
  { id = "dictate",  label = "Hold to speak a reminder",  mods = { "ctrl", "alt", "cmd" }, key = "d",
    hold = true },
}

local MOD_NAME = { ctrl = "control", alt = "option", cmd = "command", shift = "shift" }
local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }
local VALID_MOD = { ctrl = true, alt = true, cmd = true, shift = true }

local overrides = {}

local function path()
  return (config.projectDir or os.getenv("HOME")) .. "/data/hotkeys.json"
end

-- "control + option + command + N" — spelled out, never glyphs. ⌃⌥⌘ is only
-- readable if you already know it, which defeats a cheatsheet.
function M.describe(mods, key)
  local parts = {}
  for _, m in ipairs(MOD_ORDER) do
    for _, has in ipairs(mods or {}) do
      if has == m then parts[#parts + 1] = MOD_NAME[m] end
    end
  end
  parts[#parts + 1] = (key or ""):upper()
  return table.concat(parts, " + ")
end

local function chordKey(mods, key)
  local seen = {}
  for _, m in ipairs(mods or {}) do seen[m] = true end
  local out = {}
  for _, m in ipairs(MOD_ORDER) do if seen[m] then out[#out + 1] = m end end
  return table.concat(out, "+") .. ":" .. (key or ""):lower()
end

function M.load()
  overrides = {}
  local f = io.open(path(), "r")
  if not f then return end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if ok and type(data) == "table" then overrides = data end
end

local function persist()
  hs.fs.mkdir((config.projectDir or os.getenv("HOME")) .. "/data")
  local ok, blob = pcall(hs.json.encode, overrides, true)
  if not ok then return end
  local f = io.open(path(), "w")
  if f then f:write(blob); f:close() end
end

-- The effective set: defaults with any override applied. Everything that
-- displays a chord reads this, so nothing can advertise a stale one.
function M.list()
  local out = {}
  for _, a in ipairs(M.ACTIONS) do
    local o = overrides[a.id]
    local mods = (o and type(o.mods) == "table" and #o.mods > 0) and o.mods or a.mods
    local key = (o and type(o.key) == "string" and o.key ~= "") and o.key or a.key
    out[#out + 1] = {
      id = a.id, label = a.label, mods = mods, key = key,
      chord = M.describe(mods, key),
      hold = a.hold or false,
      isDefault = chordKey(mods, key) == chordKey(a.mods, a.key),
      default = M.describe(a.mods, a.key),
    }
  end
  return out
end

function M.get(id)
  for _, b in ipairs(M.list()) do if b.id == id then return b end end
end

-- Bind everything from scratch. Cheap, and avoids the class of bug where a
-- rebind leaves the previous chord alive alongside the new one.
function M.apply()
  -- Rebinding destroys every hotkey object, including the one holding a live
  -- releasedfn. Editing a shortcut from the dashboard mid-hold would therefore
  -- leave the recorder running with nothing left to stop it. Cheaper to cancel
  -- than to reason about.
  local okD, dictate = pcall(require, "cr.dictate")
  if okD and dictate and dictate.busy and dictate.busy() then pcall(dictate.cancel) end

  for _, hk in ipairs(M.bound) do pcall(function() hk:delete() end) end
  M.bound = {}
  for _, b in ipairs(M.list()) do
    -- A handler is either a function (tap) or { pressed, released } (hold).
    -- Both go through one bind call: hs.hotkey.new shifts its arguments right
    -- when the third is a function or nil, so bind(mods, key, fn) still lands
    -- fn in pressedfn exactly as before — the tap actions are untouched.
    local h = M.handlers[b.id]
    local pressed, released, repeated
    if type(h) == "function" then
      pressed = h
    elseif type(h) == "table" then
      pressed, released, repeated = h.pressed, h.released, h.repeated
    end
    if pressed or released or repeated then
      local ok, hk = pcall(hs.hotkey.bind, b.mods, b.key, pressed, released, repeated)
      if ok and hk then M.bound[#M.bound + 1] = hk
      else log.append({ event = "hotkey.bind_failed", id = b.id, chord = b.chord }) end
    end
  end
  log.append({ event = "hotkeys.applied", count = #M.bound })
end

-- Returns ok, err. Validation is the whole value of routing changes through
-- here: a chord with no modifier would swallow that letter everywhere you
-- type, and two actions on one chord means one silently never fires.
function M.set(id, mods, key)
  if not M.get(id) then return false, "unknown action" end
  if type(key) ~= "string" or key == "" then return false, "no key" end
  key = key:lower()
  local clean = {}
  for _, m in ipairs(mods or {}) do
    if VALID_MOD[m] then clean[#clean + 1] = m end
  end
  if #clean == 0 then
    return false, "needs at least one modifier — a bare key would fire while you type"
  end
  if #clean == 1 and clean[1] == "shift" then
    return false, "shift alone isn't enough — add control, option, or command"
  end
  local want = chordKey(clean, key)
  for _, b in ipairs(M.list()) do
    if b.id ~= id and chordKey(b.mods, b.key) == want then
      return false, "already used by \"" .. b.label .. "\""
    end
  end
  -- probe: macOS may refuse a chord another app owns system-wide
  local ok, hk = pcall(hs.hotkey.new, clean, key, function() end)
  if not ok or not hk then return false, "macOS wouldn't accept that combination" end
  pcall(function() hk:delete() end)

  overrides[id] = { mods = clean, key = key }
  persist()
  M.apply()
  log.append({ event = "hotkey.changed", id = id, chord = M.describe(clean, key) })
  return true
end

function M.reset(id)
  if id then overrides[id] = nil else overrides = {} end
  persist()
  M.apply()
  log.append({ event = "hotkey.reset", id = id or "all" })
  return true
end

return M
