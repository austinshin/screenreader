-- Copy to secrets.lua (gitignored) and fill in what you use. All optional.
return {
  -- Discord: falls back automatically to DISCORD_WEBHOOK_URL from
  -- ~/.claude/settings.json (already configured for the Claude stop-hook),
  -- so you only need this to override it.
  -- discordWebhook = "https://discord.com/api/webhooks/…",

  -- Slack incoming webhook
  -- slackWebhook = "https://hooks.slack.com/services/…",

  -- Generic JSON POST fanout (full payload, action labels included)
  -- webhooks = { "https://example.com/hook" },
}
