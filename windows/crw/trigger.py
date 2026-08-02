"""The per-reminder state machine ("the guard") — port of cr/trigger.lua.

The observer samples a LEVEL (what's on screen); this module detects EDGES
(the thing a reminder cares about just ended). Completion is edge-triggered:
you must see the activity happening, then see it stop — otherwise "not
watching the video" is trivially true and fires instantly.

  PENDING ──seen──▶ ARMED ──absent──▶ COOLDOWN ──absent × N──▶ READY ──gate──▶ FIRED
                      ▲                  │ present                │ present
                      └──────────────────┴──────── re-arm ────────┘

Gates for firing (never mid-focus): an app-switch/wake tick, or a max-wait
backstop so a reminder can't sit READY forever.
"""

from __future__ import annotations

import time

from . import config, eventlog, matcher, notifier, reminders, tier, why

# wired by the app (glance refresh etc.); called after any state change
on_state_change = None


def _notify_change():
    if on_state_change:
        try:
            on_state_change()
        except Exception:
            pass


def defer_by(r, minutes, label):
    """Works for both kinds: a timed reminder moves its clock, a contextual
    one stops watching and comes back on the clock instead — otherwise "in 5
    minutes" would mean "in 5 minutes, if you also happen to finish that
    thing", which is not what anyone means."""
    r["dueAt"] = int(time.time()) + minutes * 60
    reminders.set_state(r, "scheduled", label)
    eventlog.append({"event": "feedback", "value": "defer",
                     "minutes": minutes, "id": r["id"]})
    why.note("reminder pushed back", r["text"], [
        ("you pressed", label),
        ("now due", time.strftime("%I:%M %p", time.localtime(r["dueAt"])).lstrip("0")),
    ])


def card_for(r):
    """The card for a fired reminder. Built separately from fire() so an
    unanswered reminder can be put back on screen without re-firing it.
    Action ids are stable, labels are not — see cr.notification."""
    def done():
        reminders.set_state(r, "done", "user")
        eventlog.append({"event": "feedback", "value": "done", "id": r["id"]})
        _notify_change()

    return {
        "title": "Reminder",
        "body": r["text"],
        "icon": "⏰",
        "urgency": "info",
        "sticky": True,  # waits for an answer; a card that dismisses itself
                         # has failed at its only job, invisibly
        "meta": {"id": r["id"],
                 "referent": (r.get("referent") or {}).get("label")},
        "actions": [
            {"id": "done", "label": "Done", "fn": done},
            {"id": "defer_5", "label": "5 min",
             "fn": lambda: (defer_by(r, 5, "5 min"), _notify_change())},
            {"id": "snooze", "label": "Snooze",
             "fn": lambda: (defer_by(r, config.SNOOZE_MINUTES, "Snooze"),
                            _notify_change())},
        ],
    }


def why_now(r, snap, gate) -> str:
    """Why this reminder is arriving at this moment, in the user's terms."""
    if gate == "time":
        due = r.get("dueAt") or int(time.time())
        late = int(time.time()) - due
        clock = time.strftime("%I:%M %p", time.localtime(due)).lstrip("0")
        extra = (f" — {late}s later than set, checked once a second"
                 if late > 2 else "")
        return f"the time you set arrived ({clock}){extra}"
    where = (r.get("referent") or {}).get("label") or "?"
    if gate == "max-wait":
        return (f'you left "{where}" and stayed away, and nothing interrupted '
                f"for {config.MAX_READY_WAIT}s — fired rather than wait longer")
    how = ("you came back from idle" if gate == "wake" else "you switched apps")
    return (f'you left "{where}" and stayed away for {config.ABSENT_SAMPLES} '
            f"checks (~{config.ABSENT_SAMPLES * config.POLL_INTERVAL}s), then "
            f"{how} — waited for that seam so this didn't land mid-task")


def fire(r, snap, gate) -> None:
    reminders.set_state(r, "fired", gate)
    eventlog.append({"event": "trigger.fired", "id": r["id"], "text": r["text"],
                     "gate": gate, "tier": r.get("tier")})

    # Ambient never gets a card: something you asked to "keep an eye on"
    # should be findable, not interruptive. It still lands in the dashboard
    # and the glance panel.
    if (r.get("tier") or tier.UPCOMING) == tier.AMBIENT:
        eventlog.append({"event": "trigger.silent", "id": r["id"],
                         "reason": "ambient tier"})
        why.note("reminder surfaced quietly", r["text"], [
            ("why now", why_now(r, snap, gate)),
            ("attention", "ambient — no card, by design. It's in the dashboard "
                          "and the glance panel."),
        ])
        _notify_change()
        return

    payload = card_for(r)
    chans = r.get("channels")
    if (r.get("tier") or 2) == tier.CRITICAL:
        payload["urgency"] = "warn"
        payload["icon"] = "🚨"
        # critical reaches you wherever you are, not only where it fired
        chans = ["card", "system"] + [c for c in (r.get("channels") or [])
                                      if c not in ("card", "system")]
        try:
            import winsound
            winsound.MessageBeep(winsound.MB_ICONEXCLAMATION)
        except Exception:
            pass
    delivered = notifier.notify(payload, {
        "channels": chans,
        "event": "reminder.fired",
        "reminder": r,
        # the same sentence the decision log gets: on a phone there is no
        # screen context to reconstruct why this arrived
        "trigger": {"gate": gate, "why": why_now(r, snap, gate)},
    })
    why.note("reminder fired", r["text"], [
        ("why now", why_now(r, snap, gate)),
        ("set", time.strftime("%I:%M %p", time.localtime(r.get("createdAt") or time.time())).lstrip("0")
                + (f' from "{r["whenPhrase"]}"' if r.get("whenPhrase") else "")),
        ("delivered to", " + ".join(delivered or r.get("channels") or ["card"])),
        ("waiting on", "you — the card stays up until you answer it"),
    ])
    _notify_change()


def restore_fired() -> int:
    """A sticky card only survives as long as the process drawing it. Put
    unanswered reminders back up on start — local card only: the remote
    channels already delivered once."""
    n = 0
    for r in reminders.active():
        if r.get("state") == "fired":
            n += 1
            notifier.notify(card_for(r), {
                "channels": ["card"],
                "no_mirror": True,  # a redraw, not a new event
                "event": "reminder.restored",
                "reminder": r,
            })
    if n:
        eventlog.append({"event": "trigger.restored", "count": n})
    return n


def retier(r, snap) -> None:
    """Tier is a property of the reminder *right now*, so it is recomputed
    rather than remembered — inside two hard limits (see crw.tier)."""
    from_ = r.get("tier") or tier.UPCOMING
    to, reason = from_, None

    if r.get("dueAt"):
        # Proximity raises volume, but ambient promised to never interrupt,
        # and critical needs stated consequence, not a clock — nearness alone
        # caps out at upcoming.
        left = r["dueAt"] - int(time.time())
        if from_ != tier.AMBIENT and left <= 3600 and from_ > tier.UPCOMING:
            to, reason = tier.UPCOMING, "within the hour"
    elif (r.get("referent") and from_ == tier.AMBIENT
          and matcher.matches(r["referent"], snap)):
        # something you were only tracking is now in front of you
        to, reason = tier.INCONTEXT, "the thing it's about is on screen now"
    elif (from_ == tier.INCONTEXT and r.get("state") == "pending"
          and int(time.time()) - (r.get("createdAt") or int(time.time())) > 86400):
        # a context that hasn't come back in a day isn't going to interrupt well
        to, reason = tier.AMBIENT, "its context hasn't appeared in a day"

    if to != from_:
        r["tier"], r["tierWhy"] = to, reason
        r.setdefault("tierHistory", []).append(
            {"t": int(time.time()), "from": from_, "to": to, "why": reason})
        reminders.persist()
        eventlog.append({"event": "tier.moved", "id": r["id"],
                         "from": from_, "to": to, "why": reason})
        why.note("reminder got louder" if to < from_ else "reminder got quieter",
                 r["text"], [
                     ("moved", f'{tier.LABEL[from_]["name"]} → {tier.LABEL[to]["name"]}'),
                     ("because", reason),
                     ("now", tier.LABEL[to]["note"]),
                 ])
        _notify_change()


def check_due(snap) -> None:
    """Timed reminders bypass the FSM entirely: they fire on the clock,
    wherever the user is. Called every second for demo-friendly precision."""
    now = int(time.time())
    for r in reminders.active():
        if r.get("state") == "scheduled" and r.get("dueAt") and now >= r["dueAt"]:
            try:
                fire(r, snap or {}, "time")
            except Exception as e:
                eventlog.append({"event": "trigger.error", "id": r["id"],
                                 "error": str(e)})


def _step(r, snap) -> None:
    present = matcher.matches(r.get("referent"), snap)
    st = r.get("state")

    if st == "pending":
        if present:
            r["absent"] = 0
            reminders.set_state(r, "armed")

    elif st == "armed":
        if not present:
            r["absent"] = 1
            reminders.set_state(r, "cooldown")

    elif st == "cooldown":
        if present:
            # brief tab-away, not "done" — the debounce doing its job
            r["absent"] = 0
            reminders.set_state(r, "armed", "rearmed")
        else:
            r["absent"] = (r.get("absent") or 0) + 1
            if r["absent"] >= config.ABSENT_SAMPLES:
                r["readyAt"] = int(time.time())
                reminders.set_state(r, "ready")

    elif st == "ready":
        if present:
            # came back before we fired: definitely not done
            r["absent"] = 0
            reminders.set_state(r, "armed", "returned")
        else:
            gate = None
            if tier.bypasses_seam_gate(r.get("tier")):
                # the one tier allowed to interrupt mid-focus — the stated
                # exception, not an oversight
                gate = "critical"
            elif snap.get("reason") in ("app-switch", "wake"):
                gate = snap["reason"]
            elif int(time.time()) - (r.get("readyAt") or 0) >= config.MAX_READY_WAIT:
                gate = "max-wait"
            if gate:
                fire(r, snap, gate)


def tick(snap) -> None:
    """One observer sample through every active reminder. Exported for
    scripted tests: feed synthetic snapshots without waiting on wall-clock."""
    for r in reminders.active():
        try:
            retier(r, snap)
        except Exception as e:
            eventlog.append({"event": "trigger.error", "id": r.get("id"),
                             "error": "retier: " + str(e)})
        before = r.get("state")
        try:
            _step(r, snap)
        except Exception as e:
            eventlog.append({"event": "trigger.error", "id": r.get("id"),
                             "error": str(e)})
        if r.get("state") != before:
            _notify_change()
