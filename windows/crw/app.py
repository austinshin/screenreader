"""Wiring and the event loop — what cr/init.lua was on macOS.

One process, one loop: a withdrawn tk root plays the role Hammerspoon's
single-threaded runtime played — observer polls, trigger ticks, and cards all
share it, so there is no locking anywhere in the product logic. The two
worker threads (the Win32 message loop, whisper transcription) communicate
only through a queue drained here.
"""

from __future__ import annotations

import ctypes
import queue as queue_mod
import sys
import tkinter as tk

from . import (cards, config, dictate, eventlog, notifier, observer,
               reminders, trigger, winloop)

_q: queue_mod.Queue = queue_mod.Queue()
_root: tk.Tk | None = None


def _single_instance() -> bool:
    """Two instances would double-fire every reminder; a named mutex is the
    six-line fix."""
    ctypes.windll.kernel32.CreateMutexW(None, False, "contextual-reminders-crw")
    return ctypes.windll.kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS


def _on_new_reminder():
    # Snapshot BEFORE the dialog opens — the dialog steals focus, and the
    # dialog itself must never become "this".
    snap = observer.current

    def created(text):
        r = reminders.add(text, snap, {"via": "hotkey"})
        if r:
            cards.confirm(r)
        else:
            cards.show({"title": "Not created", "lead": text,
                        "body": "Nothing on screen to attach it to — try adding a time.",
                        "icon": "⚠️", "urgency": "warn", "duration": 5})
    cards.prompt_new(snap, created)


def _on_dictate_event(kind, data):
    if kind == "status":
        cards.toast("🎙 " + data, 2.5)
    elif kind == "rejected":
        cards.toast("🎙 " + (data or "didn't catch that"), 2.5)
    elif kind == "transcript":
        text, snap = data
        r = reminders.add(text, snap, {"via": "dictate"})
        if r:
            cards.confirm(r)
        else:
            cards.toast("couldn't attach that to anything on screen", 2.5)


def _drain_queue():
    while True:
        try:
            action, arg = _q.get_nowait()
        except queue_mod.Empty:
            break
        if action == "__app_switch__":
            # the seam, delivered the moment it happens — this poll's tick is
            # what lets a READY reminder fire between tasks instead of mid-task
            observer.poll("app-switch")
        elif action == "__dictate__":
            _on_dictate_event(*arg)
        elif action == "reminder":
            _on_new_reminder()
        elif action == "glance":
            cards.glance_toggle()
        elif action == "test":
            notifier.test()
        elif action == "logs":
            import os
            os.startfile(config.logs_dir())
        elif action == "quit":
            shutdown()
            return
        elif action == "dictate":
            if arg == "down":
                dictate.start_recording(observer.current)
            elif arg == "up":
                dictate.stop_recording()
    _root.after(50, _drain_queue)


def _observer_tick():
    observer.poll("timer")
    _root.after(config.POLL_INTERVAL * 1000, _observer_tick)


def _due_tick():
    trigger.check_due(observer.current)
    _root.after(1000, _due_tick)


def shutdown():
    eventlog.append({"event": "crw.stopped"})
    winloop.stop()
    observer.stop()
    if _root:
        _root.destroy()


def main() -> None:
    global _root
    # Windows consoles often default to cp1252, which cannot print the arrows
    # and emoji this app narrates with — and a banner must never be a crash.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if not _single_instance():
        print("crw is already running.")
        return

    _root = tk.Tk()
    _root.withdraw()
    cards.init(_root)

    reminders.load()
    observer.start()
    observer.subscribe_tick(trigger.tick)   # cooldown counts unchanged samples too
    trigger.on_state_change = cards.glance_refresh
    trigger.restore_fired()                 # unanswered reminders survive a restart

    dictate.init(lambda kind, data: _q.put(("__dictate__", (kind, data))))
    winloop.start(_q)

    _root.after(50, _drain_queue)
    _root.after(config.POLL_INTERVAL * 1000, _observer_tick)
    _root.after(1000, _due_tick)

    eventlog.append({"event": "crw.loaded"})
    print("Contextual Reminders (Windows) — running.")
    for aid, chord in winloop.registered.items():
        print(f"  {chord:<14} {aid}" + ("  (hold)" if aid == "dictate" else ""))
    for aid, chord in winloop.failed.items():
        print(f"  ! {chord} ({aid}) refused — another app owns that chord")
    ok, why_not = dictate.available()
    print("  voice: " + ("ready — hold the dictate chord and speak"
                         if ok else f"off ({why_not})"))
    print(f"  data → {config.DATA_DIR}   logs → {config.LOGS_DIR}")
    print("  dashboard: python service/ui.py  (shows these reminders read-only)")

    try:
        _root.mainloop()
    except KeyboardInterrupt:
        shutdown()


if __name__ == "__main__":
    main()
