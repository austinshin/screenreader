-- cr.log — append-only JSONL event log.
-- One file per day under <project>/logs/. This log is the debug pane, the
-- dogfooding journal, and (later) the replay-harness input, so every module
-- writes through here rather than print().

local config = require("cr.config")

local M = {}

local function dir()
  return (config.projectDir or os.getenv("HOME")) .. "/logs"
end

function M.dirPath()
  return dir()
end

function M.todayPath()
  return dir() .. "/events-" .. os.date("%Y-%m-%d") .. ".jsonl"
end

function M.append(event)
  event.ts  = event.ts or os.time()
  event.iso = os.date("%Y-%m-%dT%H:%M:%S", event.ts)
  local ok, line = pcall(hs.json.encode, event)
  if not ok then return end
  hs.fs.mkdir(dir())
  local f = io.open(M.todayPath(), "a")
  if f then
    f:write(line, "\n")
    f:close()
  end
end

return M
