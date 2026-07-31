-- cr.why — the decision log, in English.
--
-- events-*.jsonl already records *what* happened. This records *why*, in the
-- words a person would use, because the two questions have different readers.
-- A tool that watches your screen and then acts on its own reading of it has
-- to be able to answer "why did you do that?" without you opening a log
-- viewer and reconstructing intent from state transitions.
--
-- Three moments are worth explaining, and they're the three where the system
-- exercises judgment rather than following instructions:
--   created — how a sentence became a time, or why it didn't
--   fired   — why *now* and not some other moment
--   skipped — why something that looked like a task wasn't treated as one
--
-- Written as Markdown to logs/decisions-YYYY-MM-DD.md so it can be read in
-- Obsidian, quoted in a demo, or handed to someone as evidence.

local config = require("cr.config")

local M = {}

local function path()
  local dir = (config.projectDir or os.getenv("HOME")) .. "/logs"
  hs.fs.mkdir(dir)
  return dir .. "/decisions-" .. os.date("%Y-%m-%d") .. ".md"
end

local function clock()
  return (os.date("%I:%M %p"):gsub("^0", ""))
end

-- kind: created | fired | skipped | learned
-- subject: the reminder text or candidate action
-- reasons: array of { label, detail } — rendered as a bullet each
function M.note(kind, subject, reasons)
  local ok, err = pcall(function()
    local f = io.open(path(), "a")
    if not f then return end
    -- a header only on the first write of the day
    if f:seek("end") == 0 then
      f:write("# Decisions — ", os.date("%A, %B %d %Y"), "\n\n",
        "Why the system did what it did. Written as it happens; ",
        "`events-*.jsonl` has the machine-readable version.\n\n")
    end
    f:write(string.format("## %s · %s\n**%s**\n\n", clock(), kind, subject or "?"))
    for _, r in ipairs(reasons or {}) do
      if r[2] ~= nil and r[2] ~= "" then
        f:write(string.format("- **%s:** %s\n", r[1], tostring(r[2])))
      end
    end
    f:write("\n")
    f:close()
  end)
  if not ok then
    -- never let explaining a decision break the decision
    require("cr.log").append({ event = "why.error", error = tostring(err) })
  end
end

return M
