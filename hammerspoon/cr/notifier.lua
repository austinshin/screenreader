-- cr.notifier — channel-agnostic notification dispatch.
--
-- One payload shape, many delivery channels. Local channels (canvas card,
-- system notification) and remote ones (Discord/Slack/generic webhooks) all
-- register against the same interface, so the future trigger engine calls
-- notify() once and routing decides where it lands.
--
-- Presence routing: if the user has been idle past config.idleThreshold, the
-- payload is also mirrored to config.remoteChannels — deliver the reminder
-- where the user actually is, not just where the trigger fired.
--
-- payload: { title, body, icon, urgency, actions = { { label, fn }, ... }, meta }

local config = require("cr.config")
local log = require("cr.log")
local ui = require("cr.notify_ui")

local M = { channels = {} }

function M.register(name, fn)
  M.channels[name] = fn
end

-- secrets: optional cr/secrets.lua (gitignored); see secrets.example.lua
local okSecrets, secrets = pcall(require, "cr.secrets")
M.secrets = (okSecrets and type(secrets) == "table") and secrets or {}

-- Discord webhook: secrets.lua wins; otherwise reuse the DISCORD_WEBHOOK_URL
-- already configured for the Claude Code stop-hook in ~/.claude/settings.json.
local function discordWebhook()
  if M.secrets.discordWebhook then return M.secrets.discordWebhook end
  local f = io.open(os.getenv("HOME") .. "/.claude/settings.json", "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if ok and type(data) == "table" and type(data.env) == "table" then
    return data.env.DISCORD_WEBHOOK_URL
  end
end

-- payload minus the Lua functions, safe for JSON serialization
local function wirePayload(p)
  local labels = {}
  for _, a in ipairs(p.actions or {}) do labels[#labels + 1] = a.label end
  return {
    title = p.title, body = p.body, icon = p.icon,
    urgency = p.urgency, actions = labels, meta = p.meta,
  }
end

-- built-in channels ----------------------------------------------------------

M.register("card", function(p)
  ui.show({
    title = p.title, body = p.body, icon = p.icon,
    urgency = p.urgency, actions = p.actions,
  })
end)

-- optional mirror; buttons require Hammerspoon notifications set to "Alerts"
-- in System Settings, so this channel makes no interactivity promises
M.register("system", function(p)
  hs.notify.new(function()
    log.append({ event = "notify.system.clicked", title = p.title })
  end, {
    title = p.title or "",
    informativeText = p.body or "",
    withdrawAfter = 0,
  }):send()
end)

M.register("discord", function(p)
  local url = discordWebhook()
  if not url then
    log.append({ event = "notify.discord.skipped", reason = "no webhook configured" })
    return
  end
  local body = hs.json.encode({
    content = string.format("%s **%s**\n%s", p.icon or "🔔", p.title or "", p.body or ""),
  })
  hs.http.asyncPost(url, body, { ["Content-Type"] = "application/json" }, function(code)
    log.append({ event = "notify.discord.sent", status = code, title = p.title })
  end)
end)

M.register("slack", function(p) -- Slack incoming webhook
  local url = M.secrets.slackWebhook
  if not url then
    log.append({ event = "notify.slack.skipped", reason = "no webhook configured" })
    return
  end
  local body = hs.json.encode({
    text = string.format("*%s*\n%s", p.title or "", p.body or ""),
  })
  hs.http.asyncPost(url, body, { ["Content-Type"] = "application/json" }, function(code)
    log.append({ event = "notify.slack.sent", status = code, title = p.title })
  end)
end)

M.register("webhook", function(p) -- generic JSON POST fanout
  for _, url in ipairs(M.secrets.webhooks or {}) do
    hs.http.asyncPost(url, hs.json.encode(wirePayload(p)),
      { ["Content-Type"] = "application/json" }, function(code)
        log.append({ event = "notify.webhook.sent", status = code, url = url })
      end)
  end
end)

-- dispatch --------------------------------------------------------------------

function M.notify(payload, opts)
  opts = opts or {}
  local names = {}
  for _, n in ipairs(opts.channels or config.defaultChannels) do
    names[#names + 1] = n
  end
  if config.remoteWhenAway and hs.host.idleTime() >= config.idleThreshold then
    for _, n in ipairs(config.remoteChannels or {}) do
      names[#names + 1] = n
    end
  end

  local seen, list = {}, {}
  for _, n in ipairs(names) do
    if not seen[n] then seen[n] = true; list[#list + 1] = n end
  end

  log.append({
    event = "notify.dispatch", title = payload.title, channels = list,
    body = (payload.body or ""):sub(1, 200), icon = payload.icon,
    id = payload.meta and payload.meta.id,
    referent = payload.meta and payload.meta.referent,
  })
  for _, n in ipairs(list) do
    local channel = M.channels[n]
    if channel then
      pcall(channel, payload)
    else
      log.append({ event = "notify.unknown_channel", channel = n })
    end
  end
  return list
end

-- The ways a notification can reach the user, with configuration state —
-- the web UI renders this as the per-reminder channel picker.
function M.available()
  return {
    { name = "card",    configured = true, desc = "on-screen card on this Mac (default)" },
    { name = "system",  configured = true, desc = "macOS Notification Center" },
    { name = "discord", configured = discordWebhook() ~= nil, desc = "Discord webhook" },
    { name = "slack",   configured = M.secrets.slackWebhook ~= nil, desc = "Slack webhook" },
    { name = "webhook", configured = type(M.secrets.webhooks) == "table" and #M.secrets.webhooks > 0,
      desc = "generic JSON POST (secrets.lua)" },
  }
end

-- fires a sample card through the full pipeline; feedback buttons write to the log
function M.test()
  M.notify({
    title = "Test reminder",
    body = "This is what a fired reminder will look like. Buttons log feedback to the event log.",
    icon = "🧪",
    urgency = "info",
    actions = {
      { label = "Done",      fn = function() log.append({ event = "feedback", value = "done", source = "test" }) end },
      { label = "Snooze",    fn = function() log.append({ event = "feedback", value = "snooze", source = "test" }) end },
      { label = "Too early", fn = function() log.append({ event = "feedback", value = "too_early", source = "test" }) end },
    },
  })
end

return M
