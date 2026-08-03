# Contextual Reminders — Windows port

The same product on Win32: **you say what to remember, your screen decides
when to surface it.** One Python process, standard library only for the core.

```
cd windows
python run.py
```

No install step. Optional extras enable optional features (see below);
[INSTALL.md](INSTALL.md) is the full guide — prerequisites, voice setup,
start-at-login, troubleshooting.

## What you get

| | |
|---|---|
| `Ctrl+Alt+N` | type a reminder — binds to the window you were just looking at |
| `Ctrl+Alt+D` | **hold** to speak one (needs the voice extras below) |
| `Ctrl+Alt+R` | glance panel: every reminder and why it hasn't fired yet |
| `Ctrl+Alt+T` | send a test card |
| `Ctrl+Alt+Q` | quit |

A ◉ tray icon (notification area) mirrors the macOS menu bar: left-click
toggles the glance panel, right-click gets you new-reminder / test-card /
logs / quit. Windows hides new tray icons under the ^ chevron by default —
drag it onto the taskbar to pin it.

Same semantics as the macOS original: *"reply to this thread once I'm done
here"* strips the condition, binds to the foreground window, and fires only
after you leave it and stay away (~30s of checks), at a seam — an app switch
or your return from idle — never mid-task. Times work too (*"in 5 minutes"*,
*"at 130"*, *"at 5pm august 1"*). Attention tiers, the sticky fired card with
**Done · 5 min · Snooze**, the plain-English decision log, and the
`cr.notification/v1` channel object are all ported unchanged.

Reminders persist to the repo's shared `data/reminders.json`, so the existing
dashboard shows them (read-only for now): `python service/ui.py`.

## Architecture

```
windows/crw/
  timeparse condition tier matcher     ported logic — pure Python, tested
  reminders trigger notification why   store · FSM · wire format · decision log
  observer                             Win32: foreground window, idle, media*
  winloop                              RegisterHotKey + WinEventHook thread
  cards notifier                       tkinter cards/glance · channel registry
  dictate                              push-to-talk* (in-process WASAPI)
  app                                  wiring — one tk event loop, no locks
```

What Hammerspoon's single-threaded runtime was on macOS, a withdrawn tk root
is here: observer polls, trigger ticks, and cards share one loop. The two
worker threads (Win32 message loop, whisper) talk to it only through a queue.

Two lessons carried over on purpose:
- **No keyboard hooks, ever.** `RegisterHotKey` costs nothing until pressed;
  a `WH_KEYBOARD_LL` hook runs on every keystroke system-wide and starves
  under load exactly like `hs.eventtap` did — dropping input everywhere.
- **The seam is event-driven.** A WinEventHook for `EVENT_SYSTEM_FOREGROUND`
  delivers app switches the moment they happen, so a READY reminder fires
  *between* tasks, not up to five seconds into the next one.

And one simplification Windows gives for free: no TCC. Window titles need no
Accessibility grant, and recording is in-process (one OS mic toggle) — the
entire launchd/responsible-process saga from the macOS port doesn't exist.

## Optional features

| Feature | Enable with |
|---|---|
| Voice (push-to-talk) | `pip install sounddevice`, a `whisper-cli` on PATH, and `models/ggml-base.en.bin` in the repo (the macOS `setup.sh` model works verbatim) |
| Transcript polish (*a local LLM repairs mishearings: "by milk at one thirty" → "buy milk at 1:30", which timeparse can then read*) | install [Ollama](https://ollama.com) + `ollama pull llama3.2:3b` — auto-detected, guarded so it can repair but never rewrite |
| Media awareness (*a video playing in the background is not "done"*) | `pip install winsdk` — uses the system SMTC API |
| Discord / Slack / Telegram / webhooks | copy `crw/secrets_example.py` → `crw/secrets.py`, or set `DISCORD_WEBHOOK_URL` etc. |

Anything missing reports a one-line reason at startup and disables only itself.

## Verify

```
cd windows
python -m unittest discover -s tests     # 49 tests: parser, FSM, tiers, matcher
```

The FSM suite covers the full edge-triggered trace
(`armed → cooldown → armed → ready → fired`), the retier limits (proximity
caps at upcoming; ambient is never promoted by the clock and fires silently),
and card-only restore after a restart.

Note for the curious: synthesizing the hotkeys programmatically to test them
may fail while anti-cheat software (e.g. Riot Vanguard) is running — it
filters injected input at the driver level. Real key presses are unaffected.

## Not ported yet

- **OCR / content conditions** (*"merge the PR after the tests run"*) — the
  Windows path is `Windows.Media.Ocr` via winsdk; the edge-triggered
  watch-for logic is small, the capture plumbing is the work.
- **URL binding for browser tabs** — tabs currently bind by window title
  (Chromium puts the tab title there), which survives everything except a
  page retitling itself. A UIA address-bar read or an extension fixes it.
- **The wake-word path** — deliberately dropped, not pending: push-to-talk
  replaced it on macOS too, for reasons the root README explains.
- **Dashboard writes** — the dashboard reads this port's state; its mutation
  endpoints still speak `hs -c`. A small local control endpoint would fix it.
