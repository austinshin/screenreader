"""Reminder store + input funnel — port of cr/reminders.lua.

Voice, hotkey, and any future input all land in add(), so they cannot drift.
Persists to data/reminders.json in the same schema the Lua side writes, which
is what lets the existing dashboard (service/ui.py) show these reminders
unchanged. Deliberately UI-free: confirmation cards and the prompt dialog
live in the app layer, so this module is fully testable headless.
"""

from __future__ import annotations

import json
import os
import random
import time

from . import condition, config, eventlog, matcher, tier, timeparse, why

items: list[dict] = []


def _path():
    return config.data_dir() / "reminders.json"


def persist() -> None:
    # write-then-rename: the dashboard polls this file every 4s, and a read
    # that lands mid-truncate would see an empty reminder list
    p = _path()
    tmp = p.with_name(p.name + ".tmp")
    try:
        tmp.write_text(json.dumps({"items": items}, indent=2, ensure_ascii=False),
                       encoding="utf-8")
        os.replace(tmp, p)
    except OSError as e:
        eventlog.append({"event": "reminders.persist_failed", "error": str(e)})


def load() -> None:
    global items
    try:
        data = json.loads(_path().read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            items = data["items"]
            eventlog.append({"event": "reminders.loaded", "count": len(items)})
    except (OSError, json.JSONDecodeError):
        pass


def add(text: str, snap, opts: dict | None = None):
    """The single funnel. A time expression inside the text is extracted here
    so every creation path understands time the same way. Returns the
    reminder, or None if there was nothing to bind to and no time."""
    opts = opts or {}
    original = text  # kept verbatim for the decision log

    body, cond = condition.extract(text)
    if cond:
        text = body
    clean, due_at, phrase = timeparse.extract(text)
    due_at = due_at or opts.get("dueAt")
    if phrase:
        text = clean

    ref = matcher.bind(snap)
    if ref:
        ref["boundAt"] = int(time.time())
    elif due_at:
        # timed reminders don't need a screen referent; record where it was set
        ref = {"kind": "time", "label": "anywhere", "boundAt": int(time.time())}
    else:
        eventlog.append({"event": "reminder.rejected",
                         "reason": "no bindable context", "text": text})
        return None

    is_bound = ref.get("kind") != "time"
    tr, tr_why = tier.classify(text, is_bound)

    r = {
        "id": "r%d%03d" % (int(time.time()), random.randint(0, 999)),
        "text": text,
        "createdAt": int(time.time()),
        "tier": tr,
        "tierInitial": tr,
        "tierWhy": tr_why,
        "referent": ref,
        "dueAt": due_at,            # epoch; None for purely contextual reminders
        "whenPhrase": phrase,       # the words the time came from, verbatim
        "condPhrase": cond,         # the words the screen condition came from
        "channels": opts.get("channels") or list(config.DEFAULT_CHANNELS),
        "via": opts.get("via"),
        # timed reminders fire on the clock; deictic ones are born ARMED when
        # the thing is on screen right now, else PENDING until first sighting
        "state": ("scheduled" if due_at
                  else "armed" if matcher.matches(ref, snap) else "pending"),
        "absent": 0,
    }
    items.append(r)
    persist()
    eventlog.append({"event": "reminder.created", "id": r["id"], "text": text,
                     "via": opts.get("via"), "state": r["state"],
                     "referent": ref.get("label"), "dueAt": due_at,
                     "channels": r["channels"]})

    why.note("reminder created", r["text"], [
        ("heard", f'"{original}"  ({opts.get("via") or "?"})'),
        ("created at", time.strftime("%I:%M:%S %p").lstrip("0")),
        ("time", (f'matched "{phrase}" → triggers {timeparse.fmt_due(due_at)}'
                  if due_at else
                  "no time phrase found → this one waits on context, not the clock")),
        (("condition", f'you said "{cond}" → resolved to what was on screen: '
                       f'{ref.get("label") or "?"}') if cond else None),
        ("place", ("not used — a timed reminder fires wherever you are" if due_at
                   else f'bound to {ref.get("label") or "?"} · fires once you\'re done with it')),
        ("attention", f'{tier.LABEL[tr]["name"]} — {tier.LABEL[tr]["note"]} ({tr_why})'),
        ("delivery", " + ".join(r["channels"])),
    ])
    return r


def describe(r) -> str:
    """One-line summary of when/where/how a reminder will surface."""
    parts = []
    if r.get("dueAt"):
        parts.append("⏰ " + (timeparse.fmt_due(r["dueAt"]) or ""))
        parts.append("📍 set from " + ((r.get("referent") or {}).get("label") or "?"))
    elif r.get("state") == "pending":
        parts.append("⏳ arms on first sighting")
        parts.append("📍 " + ((r.get("referent") or {}).get("label") or "?"))
    else:
        parts.append("👁 fires when you're done with")
        parts.append("📍 " + ((r.get("referent") or {}).get("label") or "?"))
    parts.append("📣 " + "+".join(r.get("channels") or ["card"]))
    return " · ".join(parts)


def waiting(r):
    """Why this reminder has not fired yet, in one short line. A reminder one
    check from firing and one that resets on every glance back look identical
    from outside; the count is the difference, so it travels with the row."""
    need = config.ABSENT_SAMPLES
    if r.get("dueAt") and r.get("state") == "scheduled":
        return None  # the clock already answers this
    where = (r.get("referent") or {}).get("label") or "it"
    st = r.get("state")
    if st == "pending":
        return f"waiting for {where} to appear"
    if st == "armed":
        return f"watching {where} — you're still on it"
    if st == "cooldown":
        return f"you left {where} · {r.get('absent') or 0} of {need} checks away"
    if st == "ready":
        return "ready — waiting for a natural break"
    return None


def set_state(r, state, extra=None) -> None:
    prev = r.get("state")
    r["state"] = state
    persist()
    eventlog.append({"event": "reminder.state", "id": r["id"], "from": prev,
                     "to": state, "text": r["text"], "extra": extra})


def set_channels(rid, channels) -> bool:
    r = get(rid)
    if not r or not isinstance(channels, list) or not channels:
        return False
    r["channels"] = channels
    persist()
    eventlog.append({"event": "reminder.channels", "id": rid, "channels": channels})
    return True


def active() -> list[dict]:
    return [r for r in items if r.get("state") not in ("done", "cancelled")]


def get(rid):
    for r in items:
        if r.get("id") == rid:
            return r
    return None
