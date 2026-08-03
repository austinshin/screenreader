"""The wire format every channel speaks — port of cr/notification.lua.

payload — internal, carries callables in `actions`, used by the card.
note    — this module's output, pure data, safe to JSON-encode and send.

The split is what lets a channel be a *translator* rather than an author.
Actions carry an `id`, not just a label (labels get reworded); `trigger.why`
travels because on a phone there is no screen context to reconstruct why
something arrived; `tier` travels so a channel can decide ambient never buzzes
a pocket without knowing what ambient means.
"""

from __future__ import annotations

import platform
import re
import time

from . import tier

SCHEMA = "cr.notification/v1"


def _slug(label):
    s = re.sub(r"[^a-z0-9]+", "_", (label or "").lower()).strip("_")
    return s or "action"


def build(payload: dict, opts: dict) -> dict:
    payload = payload or {}
    opts = opts or {}
    r = opts.get("reminder")
    now = int(time.time())

    actions = [{"id": a.get("id") or _slug(a.get("label")), "label": a.get("label")}
               for a in payload.get("actions") or []]

    level = (r or {}).get("tier") or tier.UPCOMING
    meta = payload.get("meta") or {}
    subject_id = (r or {}).get("id") or meta.get("id")

    trig = opts.get("trigger")
    return {
        "schema": SCHEMA,
        "id": f"ntf_{now}_{subject_id or 'adhoc'}",
        "ts": now,
        "iso": time.strftime("!%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)).lstrip("!"),
        "event": opts.get("event") or "notification",
        "title": payload.get("title"),
        "body": payload.get("body"),
        "icon": payload.get("icon"),
        "urgency": payload.get("urgency") or "info",
        "tier": {"level": level, "name": tier.NAME.get(level, "upcoming")},
        "trigger": ({"gate": trig.get("gate"), "why": trig.get("why")}
                    if trig else None),
        "subject": {
            "kind": "reminder" if r else "message",
            "id": subject_id,
            "bound_to": ((r or {}).get("referent") or {}).get("label")
                        or meta.get("referent"),
            "created_at": (r or {}).get("createdAt"),
            "due_at": (r or {}).get("dueAt"),
        },
        "actions": actions,
        "source": {"app": "contextual-reminders", "host": platform.node() or "pc"},
    }


def to_text(note: dict, bold: str = "*") -> str:
    """One line of prose carrying the whole object, for channels that are a
    text box rather than a structured API."""
    lines = [f"{note.get('icon') or '🔔'} {bold}{note.get('title') or 'Reminder'}{bold}"]
    if note.get("body"):
        lines.append(note["body"])
    if note.get("trigger") and note["trigger"].get("why"):
        lines.append("↳ " + note["trigger"]["why"])
    if note.get("actions"):
        lines.append("· " + " · ".join(a["label"] for a in note["actions"] if a.get("label")))
    return "\n".join(lines)
