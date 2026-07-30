-- cr.matcher — referent binding + presence predicate.
--
-- v1 is deictic-only and deliberately LLM-free: a referent is "whatever was on
-- screen when the reminder was created", and presence is a deterministic match
-- against later snapshots. Fully replayable; the LLM earns its way in later,
-- only where determinism runs out (non-deictic conditions, ambiguity).

local M = {}

-- Strip spinner/animation glyphs from window titles before comparing.
-- Dogfooding finding #1: kitty renders Claude Code's Braille spinner in the
-- title bar (⠐ → ⠂ → …), which made every frame look like a context change.
local SPINNER = {
  [0x2733] = true, [0x2731] = true, [0x273B] = true, [0x273D] = true, -- ✳ ✱ ✻ ✽
  [0x25CF] = true, [0x23FA] = true, [0x25CB] = true,                  -- ● ⏺ ○
}

function M.normalizeTitle(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, out = pcall(function()
    local parts = {}
    for _, cp in utf8.codes(s) do
      local isBraille = cp >= 0x2800 and cp <= 0x28FF
      if not isBraille and not SPINNER[cp] then
        parts[#parts + 1] = utf8.char(cp)
      end
    end
    return table.concat(parts)
  end)
  if not ok then out = s end -- invalid utf8: compare raw rather than crash
  out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if out == "" then return nil end
  return out
end

-- Canonical key for a URL. YouTube gets a special case — the video id is the
-- identity; timestamps and playlist params are noise. Everything else keeps
-- its query string (a Google search IS its query) but drops the fragment.
function M.urlKey(url)
  if type(url) ~= "string" or url == "" then return nil end
  local host = url:match("^https?://([^/]+)") or ""
  if host:find("youtube%.com") then
    local vid = url:match("[?&]v=([%w_%-]+)")
    if vid then return "yt:" .. vid end
  end
  local short = url:match("^https?://youtu%.be/([%w_%-]+)")
  if short then return "yt:" .. short end
  return (url:gsub("#.*$", ""):gsub("/$", ""))
end

-- Bind a referent from a snapshot: "this" = what's on screen right now.
function M.bind(snap)
  if not snap then return nil end
  local title = M.normalizeTitle(snap.tab or snap.title)
  local urlKey = M.urlKey(snap.url)
  if not title and not urlKey then return nil end
  return {
    bundle    = snap.bundle,
    app       = snap.app,
    urlKey    = urlKey,
    titleCore = title,
    boundAt   = os.time(),
    label     = (snap.app or "?") .. " — " .. (title or snap.url or "untitled"),
  }
end

local function titleMatch(core, s)
  if not core or not s then return false end
  local n = M.normalizeTitle(s)
  if not n then return false end
  local a, b = n:lower(), core:lower()
  return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

-- Presence: is the referent visible in this snapshot?
function M.matches(ref, snap)
  if not ref or not snap then return false end
  if ref.urlKey then
    -- URL-bound (browser): the active tab is the identity
    if M.urlKey(snap.url) == ref.urlKey then return true end
  elseif ref.bundle and snap.bundle == ref.bundle then
    -- title-bound (everything else): same app + matching normalized title
    if titleMatch(ref.titleCore, snap.tab or snap.title) then return true end
  end
  -- media fallback: a bound video still playing in a background tab is not
  -- "done" — requires media-control to be installed, degrades to false without
  if ref.titleCore and snap.media and snap.media.playing
    and titleMatch(ref.titleCore, snap.media.title) then
    return true
  end
  return false
end

return M
