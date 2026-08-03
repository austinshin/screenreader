"""Channel-agnostic notification dispatch — port of cr/notifier.lua.

One payload shape, many delivery channels; register(name, fn) adds one.
Channels receive (payload, note): the payload carries callables and is what
the card uses; note is the cr.notification/v1 object — pure data, built ONCE
per dispatch so every channel describes the same event with the same id.

Presence routing: idle past the threshold mirrors delivery to the remote
channels — the reminder lands where the user actually is.

Secrets come from crw/secrets.py (gitignored; see secrets_example.py) or
environment variables — deliberately not from another tool's config file.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import urllib.request

from . import cards, config, eventlog, notification, observer

channels: dict = {}


def register(name: str, fn) -> None:
    channels[name] = fn


try:
    from . import secrets as _secrets
except ImportError:
    class _secrets:  # type: ignore
        pass


def _secret(attr: str, env: str):
    return getattr(_secrets, attr, None) or os.environ.get(env)


def _post_json(url: str, obj: dict, tag: str) -> None:
    """Fire-and-forget JSON POST on a worker thread — a slow webhook must
    never stall the tk loop a card is drawn on."""
    def run():
        try:
            req = urllib.request.Request(
                url, json.dumps(obj).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                eventlog.append({"event": f"notify.{tag}.sent", "status": resp.status})
        except Exception as e:
            eventlog.append({"event": f"notify.{tag}.failed", "error": str(e)[:200]})
    threading.Thread(target=run, daemon=True).start()


# built-in channels ----------------------------------------------------------

register("card", lambda p, note: cards.show(p))


def _system(p, note):
    """Windows toast via PowerShell + WinRT — no dependencies, and unlike the
    macOS side there is no notification-style setting to fight. Payload goes
    over as -EncodedCommand so quoting can't break it."""
    import base64
    ps = """
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $xml.GetElementsByTagName('text')
$t.Item(0).AppendChild($xml.CreateTextNode(%s)) > $null
$t.Item(1).AppendChild($xml.CreateTextNode(%s)) > $null
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
""" % (repr(p.get("title") or "Reminder").replace('"', "'"),
       repr((p.get("body") or "")[:200]).replace('"', "'"))
    enc = base64.b64encode(ps.encode("utf-16-le")).decode()

    def run():
        try:
            subprocess.run(["powershell", "-NoProfile", "-EncodedCommand", enc],
                           creationflags=0x08000000, timeout=15)  # CREATE_NO_WINDOW
            eventlog.append({"event": "notify.system.sent", "title": p.get("title")})
        except Exception as e:
            eventlog.append({"event": "notify.system.failed", "error": str(e)[:200]})
    threading.Thread(target=run, daemon=True).start()


register("system", _system)


def _discord(p, note):
    url = _secret("discord_webhook", "DISCORD_WEBHOOK_URL")
    if not url:
        eventlog.append({"event": "notify.discord.skipped", "reason": "no webhook configured"})
        return
    _post_json(url, {"content": notification.to_text(note, bold="**")}, "discord")


def _slack(p, note):
    url = _secret("slack_webhook", "SLACK_WEBHOOK_URL")
    if not url:
        eventlog.append({"event": "notify.slack.skipped", "reason": "no webhook configured"})
        return
    _post_json(url, {"text": notification.to_text(note, bold="*")}, "slack")


def _telegram(p, note):
    token = _secret("telegram_token", "TELEGRAM_BOT_TOKEN")
    chat = _secret("telegram_chat_id", "TELEGRAM_CHAT_ID")
    if not (token and chat):
        eventlog.append({"event": "notify.telegram.skipped", "reason": "no bot token configured"})
        return
    _post_json(f"https://api.telegram.org/bot{token}/sendMessage", {
        "chat_id": chat,
        "text": notification.to_text(note, bold="*"),
        "parse_mode": "Markdown",
        # an ambient reminder is explicitly the kind that must not buzz a pocket
        "disable_notification": (note.get("tier") or {}).get("name") == "ambient",
    }, "telegram")


def _webhook(p, note):
    for url in getattr(_secrets, "webhooks", None) or []:
        _post_json(url, note, "webhook")


register("discord", _discord)
register("slack", _slack)
register("telegram", _telegram)
register("webhook", _webhook)


# dispatch -------------------------------------------------------------------

def notify(payload: dict, opts: dict | None = None) -> list[str]:
    opts = opts or {}
    names = list(opts.get("channels") or config.DEFAULT_CHANNELS)
    # no_mirror: a re-display of something already delivered, not a new event
    # — restoring a card after a restart must not re-ping a phone
    if (not opts.get("no_mirror") and config.REMOTE_WHEN_AWAY
            and observer.idle_seconds() >= config.IDLE_THRESHOLD):
        names += config.REMOTE_CHANNELS

    seen, ordered = set(), []
    for n in names:
        if n not in seen:
            seen.add(n)
            ordered.append(n)

    note = notification.build(payload, opts)
    eventlog.append({
        "event": "notify.dispatch", "title": payload.get("title"),
        "channels": ordered, "body": (payload.get("body") or "")[:200],
        "icon": payload.get("icon"), "id": note["subject"]["id"],
        "referent": note["subject"]["bound_to"], "notification": note["id"],
        "tier": note["tier"]["name"],
    })
    for n in ordered:
        fn = channels.get(n)
        if not fn:
            eventlog.append({"event": "notify.unknown_channel", "channel": n})
            continue
        try:
            fn(payload, note)
        except Exception as e:
            eventlog.append({"event": "notify.channel_failed", "channel": n,
                             "error": str(e)[:200]})
    return ordered


def available() -> list[dict]:
    return [
        {"name": "card", "configured": True, "desc": "on-screen card on this PC (default)"},
        {"name": "system", "configured": True, "desc": "Windows toast notification"},
        {"name": "discord", "configured": bool(_secret("discord_webhook", "DISCORD_WEBHOOK_URL")),
         "desc": "Discord webhook"},
        {"name": "slack", "configured": bool(_secret("slack_webhook", "SLACK_WEBHOOK_URL")),
         "desc": "Slack webhook"},
        {"name": "telegram",
         "configured": bool(_secret("telegram_token", "TELEGRAM_BOT_TOKEN")),
         "desc": "Telegram bot — push to your phone"},
        {"name": "webhook",
         "configured": bool(getattr(_secrets, "webhooks", None)),
         "desc": "generic JSON POST (secrets.py)"},
    ]


def test() -> None:
    notify({
        "title": "Test reminder",
        "body": "This is what a fired reminder will look like. "
                "Buttons log feedback to the event log.",
        "icon": "🧪",
        "urgency": "info",
        "actions": [
            {"id": "done", "label": "Done",
             "fn": lambda: eventlog.append({"event": "feedback", "value": "done",
                                            "source": "test"})},
            {"id": "snooze", "label": "Snooze",
             "fn": lambda: eventlog.append({"event": "feedback", "value": "snooze",
                                            "source": "test"})},
        ],
    })
