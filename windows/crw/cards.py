"""Notification cards, toast, glance panel, and the typed-reminder prompt —
the tkinter counterpart of cr/notify_ui.lua + cr/glance.lua.

Everything here runs on the tk main thread; other threads reach the UI only
through the app's queue. Cards are borderless topmost Toplevels stacked from
the top-right, exactly the geometry the macOS cards used.

sticky = True: the card never times out and only an action button or ✕
closes it. A fired reminder that vanishes on its own has failed at the one
job it had, and the failure is invisible — you can't miss what you never saw.
"""

from __future__ import annotations

import time
import tkinter as tk

from . import config, eventlog, reminders, timeparse, tier

root: tk.Tk | None = None
_active: list[dict] = []      # live cards, oldest first; new cards stack below
_glance: tk.Toplevel | None = None


def init(tk_root: tk.Tk) -> None:
    global root
    root = tk_root


def _dark_mode() -> bool:
    try:
        import winreg
        with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            return winreg.QueryValueEx(k, "AppsUseLightTheme")[0] == 0
    except OSError:
        return True


def _palette() -> dict:
    if _dark_mode():
        return {"bg": "#1C1D26", "title": "#FFFFFF", "body": "#B8BCC8",
                "btn": "#2A2C3A", "btnText": "#E6E9F2", "dim": "#8A90A2",
                "accents": {"info": "#7AA2F7", "warn": "#E0AF68",
                            "success": "#9ECE6A"}}
    return {"bg": "#FFFFFF", "title": "#1A1A1A", "body": "#555555",
            "btn": "#EEEEF2", "btnText": "#222222", "dim": "#6B7280",
            "accents": {"info": "#3B6FE0", "warn": "#C77D1A",
                        "success": "#4E8C2F"}}


def _stack_offset() -> int:
    return sum(c["win"].winfo_height() + 10 for c in _active if c["win"].winfo_exists())


def show(opts: dict) -> None:
    """opts: title, lead, body, icon, urgency, duration, sticky,
    actions=[{label, fn}], onDismiss"""
    if root is None:
        return
    pal = _palette()
    accent = pal["accents"].get(opts.get("urgency") or "info", pal["accents"]["info"])
    sticky = bool(opts.get("sticky"))

    win = tk.Toplevel(root)
    win.overrideredirect(True)
    win.attributes("-topmost", True)
    win.configure(bg=accent)

    card = {"win": win, "timer": None, "done": False}

    inner = tk.Frame(win, bg=pal["bg"])
    inner.pack(fill="both", expand=True, padx=(4, 0))  # left edge = accent bar

    head = tk.Frame(inner, bg=pal["bg"])
    head.pack(fill="x", padx=12, pady=(10, 0))
    tk.Label(head, text=opts.get("icon") or "🔔", bg=pal["bg"],
             font=("Segoe UI Emoji", 13)).pack(side="left")
    tk.Label(head, text=opts.get("title") or "", bg=pal["bg"], fg=pal["title"],
             font=("Segoe UI", 10, "bold"), anchor="w").pack(
        side="left", padx=(8, 0), fill="x", expand=True)

    def dismiss(reason=None):
        if card["done"]:
            return
        card["done"] = True
        if card["timer"]:
            root.after_cancel(card["timer"])
        if card in _active:
            _active.remove(card)
        win.destroy()
        if reason:
            eventlog.append({"event": reason, "title": opts.get("title")})
        if opts.get("onDismiss"):
            try:
                opts["onDismiss"](reason)
            except Exception:
                pass

    if sticky:
        # the only way to lose a sticky card without answering it
        tk.Button(head, text="✕", bg=pal["bg"], fg=pal["dim"], bd=0,
                  activebackground=pal["bg"], cursor="hand2",
                  command=lambda: dismiss("card.closed")).pack(side="right")

    if opts.get("lead"):
        tk.Label(inner, text=opts["lead"], bg=pal["bg"], fg=pal["title"],
                 font=("Segoe UI", 11, "bold"), anchor="w", justify="left",
                 wraplength=config.CARD_WIDTH - 40).pack(fill="x", padx=12, pady=(6, 0))
    body = (opts.get("body") or "")[:300]
    if body:
        tk.Label(inner, text=body, bg=pal["bg"], fg=pal["body"],
                 font=("Segoe UI", 9), anchor="w", justify="left",
                 wraplength=config.CARD_WIDTH - 40).pack(fill="x", padx=12, pady=(4, 0))

    actions = opts.get("actions") or []
    if actions:
        row = tk.Frame(inner, bg=pal["bg"])
        row.pack(fill="x", padx=12, pady=(8, 10))
        for a in reversed(actions):
            def run(a=a):
                eventlog.append({"event": "card.action", "label": a.get("label"),
                                 "title": opts.get("title")})
                if a.get("fn"):
                    try:
                        a["fn"]()
                    except Exception as e:
                        eventlog.append({"event": "card.action_error", "error": str(e)})
                dismiss(None)
            tk.Button(row, text=a.get("label") or "OK", bg=pal["btn"],
                      fg=pal["btnText"], bd=0, padx=10, pady=3,
                      font=("Segoe UI", 9), cursor="hand2",
                      activebackground=accent, command=run).pack(side="right", padx=(6, 0))
    else:
        tk.Frame(inner, bg=pal["bg"], height=10).pack()

    # place top-right, stacked below existing cards
    win.update_idletasks()
    sw = win.winfo_screenwidth()
    w = config.CARD_WIDTH
    win.geometry(f"{w}x{win.winfo_reqheight()}+{sw - w - 16}+{16 + _stack_offset()}")
    _active.append(card)

    if not sticky:
        secs = opts.get("duration") or config.CARD_DURATION
        card["timer"] = root.after(int(secs * 1000), lambda: dismiss("card.timeout"))
        # hover pins the card
        win.bind("<Enter>", lambda e: card["timer"] and root.after_cancel(card["timer"]))
        win.bind("<Leave>", lambda e: card.__setitem__(
            "timer", root.after(3000, lambda: dismiss("card.timeout"))))
        win.bind("<Button-1>", lambda e: dismiss("card.dismissed"))


def active_count() -> int:
    return len(_active)


def toast(text: str, secs: float = 1.8) -> None:
    """Brief bottom-center flash (echo after creating a reminder, etc.)."""
    if root is None:
        return
    pal = _palette()
    win = tk.Toplevel(root)
    win.overrideredirect(True)
    win.attributes("-topmost", True)
    tk.Label(win, text=text, bg=pal["bg"], fg=pal["title"],
             font=("Segoe UI", 10), padx=16, pady=8).pack()
    win.update_idletasks()
    x = (win.winfo_screenwidth() - win.winfo_reqwidth()) // 2
    y = win.winfo_screenheight() - 140
    win.geometry(f"+{x}+{y}")
    root.after(int(secs * 1000), win.destroy)


# glance ---------------------------------------------------------------------
# The dashboard is a browser tab: fine for reviewing, useless for "what am I
# on the hook for?" asked twenty times a day mid-task. Read-only on purpose.

def _glance_rows(frame, pal) -> None:
    for w in frame.winfo_children():
        w.destroy()
    rows = sorted(reminders.active(),
                  key=lambda r: (r.get("tier") or 2, r.get("dueAt") or float("inf")))
    if not rows:
        tk.Label(frame, text="Nothing on your plate.", bg=pal["bg"], fg=pal["dim"],
                 font=("Segoe UI", 10)).pack(padx=14, pady=10)
        return
    for r in rows:
        row = tk.Frame(frame, bg=pal["bg"])
        row.pack(fill="x", padx=14, pady=4)
        when = (timeparse.fmt_due(r["dueAt"]) if r.get("dueAt")
                else {"pending": "waiting", "armed": "watching",
                      "cooldown": "watching", "ready": "any moment",
                      "fired": "reminded"}.get(r.get("state"), r.get("state")))
        crit = (r.get("tier") or 2) == tier.CRITICAL
        tk.Label(row, text=when, bg=pal["bg"],
                 fg=pal["accents"]["warn"] if crit else pal["dim"],
                 font=("Segoe UI", 8), width=18, anchor="e").pack(side="left")
        col = tk.Frame(row, bg=pal["bg"])
        col.pack(side="left", fill="x", expand=True, padx=(10, 0))
        tk.Label(col, text=r["text"][:48], bg=pal["bg"], fg=pal["title"],
                 font=("Segoe UI", 10), anchor="w").pack(fill="x")
        # "why hasn't it fired" matters more than "what is it bound to"
        sub = reminders.waiting(r) or (not r.get("dueAt")
                                       and (r.get("referent") or {}).get("label"))
        if sub:
            tk.Label(col, text=sub[:60], bg=pal["bg"], fg=pal["dim"],
                     font=("Segoe UI", 8), anchor="w").pack(fill="x")


def glance_toggle() -> None:
    global _glance
    if _glance and _glance.winfo_exists():
        _glance.destroy()
        _glance = None
        return
    if root is None:
        return
    pal = _palette()
    _glance = tk.Toplevel(root)
    _glance.overrideredirect(True)
    _glance.attributes("-topmost", True)
    _glance.configure(bg=pal["bg"])
    tk.Label(_glance, text="Reminders", bg=pal["bg"], fg=pal["accents"]["info"],
             font=("Segoe UI", 9, "bold"), anchor="w").pack(fill="x", padx=14, pady=(10, 2))
    frame = tk.Frame(_glance, bg=pal["bg"])
    frame.pack(fill="both", expand=True, pady=(0, 10))
    _glance_rows(frame, pal)
    _glance.update_idletasks()
    _glance.geometry(f"+{_glance.winfo_screenwidth() - _glance.winfo_reqwidth() - 20}+40")
    _glance.bind("<Button-1>", lambda e: glance_toggle())

    def refresh():
        # countdowns go stale fast; a panel showing "in 5 min" ten minutes
        # later is worse than no time at all
        if _glance and _glance.winfo_exists():
            _glance_rows(frame, pal)
            _glance.after(5000, refresh)
    _glance.after(5000, refresh)
    eventlog.append({"event": "glance.show"})


def glance_refresh() -> None:
    pass  # rows re-render on their own 5s timer; hook kept for parity


# prompt ---------------------------------------------------------------------

def prompt_new(snap, on_done) -> None:
    """Typed input. The referent is the snapshot from BEFORE the dialog
    opened — the dialog steals focus, and the dialog itself must never
    become "this"."""
    if root is None:
        return
    pal = _palette()
    win = tk.Toplevel(root)
    win.title("New reminder")
    win.attributes("-topmost", True)
    win.configure(bg=pal["bg"], padx=16, pady=12)
    msg = ("" if snap else "Nothing on screen to attach this to — include a time.")
    tk.Label(win, text="What do you want to be reminded of?", bg=pal["bg"],
             fg=pal["title"], font=("Segoe UI", 10, "bold")).pack(anchor="w")
    if msg:
        tk.Label(win, text=msg, bg=pal["bg"], fg=pal["dim"],
                 font=("Segoe UI", 9)).pack(anchor="w")
    entry = tk.Entry(win, width=52, font=("Segoe UI", 10), bg=pal["btn"],
                     fg=pal["title"], insertbackground=pal["title"], bd=0)
    entry.pack(pady=8, ipady=4)

    def submit(_=None):
        text = entry.get().strip()
        win.destroy()
        if text:
            on_done(text)

    entry.bind("<Return>", submit)
    entry.bind("<Escape>", lambda e: win.destroy())
    row = tk.Frame(win, bg=pal["bg"])
    row.pack(anchor="e")
    tk.Button(row, text="Remind me", command=submit, bg=pal["accents"]["info"],
              fg="#FFFFFF", bd=0, padx=12, pady=3, cursor="hand2").pack(side="right")
    win.update_idletasks()
    x = (win.winfo_screenwidth() - win.winfo_reqwidth()) // 2
    win.geometry(f"+{x}+220")
    entry.focus_force()


def confirm(r) -> None:
    """Receipt for a created reminder — auto-dismisses; only fired reminders
    earn a sticky card."""
    when = (timeparse.fmt_due(r["dueAt"]) if r.get("dueAt")
            else (f'waits for {(r.get("referent") or {}).get("label") or "it"} to appear'
                  if r.get("state") == "pending"
                  else f'when you\'re done with {(r.get("referent") or {}).get("label") or "this"}'))
    show({
        "title": "Reminder created · " + time.strftime("%I:%M %p").lstrip("0"),
        "lead": r["text"],
        "body": f'{when}\n{tier.LABEL[r.get("tier") or 2]["name"]} · '
                + " + ".join(r.get("channels") or ["card"]),
        "icon": "✅",
        "urgency": "success",
        "duration": 5,
    })
