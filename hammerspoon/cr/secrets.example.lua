-- Copy to secrets.lua (gitignored) and fill in what you use. All optional.
return {
  -- Discord: falls back automatically to DISCORD_WEBHOOK_URL from
  -- ~/.claude/settings.json (already configured for the Claude stop-hook),
  -- so you only need this to override it.
  -- discordWebhook = "https://discord.com/api/webhooks/…",

  -- Slack incoming webhook
  -- slackWebhook = "https://hooks.slack.com/services/…",

  -- Telegram bot — reminders as push notifications on your phone.
  --   1. message @BotFather, send /newbot, copy the token it gives you
  --   2. send your new bot any message (a bot cannot open a chat with you)
  --   3. curl "https://api.telegram.org/bot<TOKEN>/getUpdates" and read
  --      result[].message.chat.id — that number is telegramChatId
  -- Both are required; with only one, the channel reports itself unconfigured.
  -- telegramToken  = "123456789:AA…",
  -- telegramChatId = "987654321",

  -- Generic JSON POST fanout — receives the full cr.notification/v1 object
  -- webhooks = { "https://example.com/hook" },
}
