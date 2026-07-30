# Contextual Reminders

Prototype for the Wispr Flow take-home: reminders that surface based on **screen context**, not clock time. Runs as a Hammerspoon module (sensors, UI, delivery) with a Python brain to follow (LLM parse/judge, trigger engine).

**→ How to run, verify, configure, and debug: [RUNNING.md](RUNNING.md)**

## Status

**Working now: the full deictic loop, zero LLM.**
`⌃⌥⌘R` → type what to be reminded of → the current screen context becomes the
referent ("THIS") → per-reminder state machine watches for it to end →
debounced, transition-gated reminder card with Done / Snooze / Too early.
Next: LLM layer for non-deictic conditions ("once I'm done testing X") +
ambiguity judging.

## How a reminder flows

```
PENDING ──seen──▶ ARMED ──absent──▶ COOLDOWN ──absent × 6──▶ READY ──gate──▶ FIRED
                    ▲                  │ present                │ present
                    └──────────────────┴──────── re-arm ────────┘
```

Completion conditions are **edge-triggered**: the engine must see the activity
happening, then see it stop — otherwise "not watching the video" is trivially
true and fires instantly. COOLDOWN (~30s of consecutive absence) makes a quick
tab-away not count as "done"; READY fires only at a transition moment
(app switch / wake), never mid-focus, with a 90s backstop.

## Architecture

```
┌────────────────────────── Hammerspoon (cr/) ─────────────────────────┐
│                                                                      │
│  observer.lua      polls frontmost app + window title (5s + events), │
│                    browser tab URL/title (AppleScript), media state; │
│                    emits context.change → subscribers + JSONL log    │
│                                                                      │
│  matcher.lua       referent binding ("THIS" = creation-time context) │
│                    + deterministic presence predicate (YouTube by    │
│                    video id, else app + normalized title)            │
│                                                                      │
│  reminders.lua     store (persists to data/reminders.json) + input   │
│                    flow (⌃⌥⌘R; referent = observer's last snapshot,  │
│                    captured before the dialog steals focus)          │
│                                                                      │
│  trigger.lua       per-reminder FSM consuming observer ticks;        │
│                    fires through the notifier at transition gates    │
│                                                                      │
│  screen_text.lua   window/screen OCR: snapshot → PNG → bin/cr-ocr    │
│                    (Apple Vision, on-device) → text. Two modes:      │
│                    manual (⌃⌥⌘S) and persistent watch (⌃⌥⌘W, opt-in, │
│                    settle-delayed + rate-limited + exclusion list)   │
│                                                                      │
│  viewer.lua        live OCR viewer panel (⌃⌥⌘V): shows what was      │
│                    read, with history paging — the transparency      │
│                    surface for a screen-reading tool                 │
│                                                                      │
│  notify_ui.lua     canvas notification card (guaranteed action       │
│                    buttons, hover-to-pin, dark/light) + toast        │
│                                                                      │
│  notifier.lua      channel-agnostic dispatch: card / system /        │
│                    discord / slack / webhook; presence routing       │
│                    (idle > 3min → mirror to remote channels)         │
│                                                                      │
│  menubar.lua       status, pause/resume, test notification, logs     │
│  log.lua           append-only JSONL, one file per day               │
│  config.lua        all tunables                                      │
└──────────────────────────────────────────────────────────────────────┘
                     logs/events-YYYY-MM-DD.jsonl
          (debug pane · dogfooding journal · replay-harness input)
```

## Why a canvas card instead of hs.notify

macOS notification action buttons only render when the app's notification style
is set to "Alerts" in System Settings — a per-user setting we can't control —
and Hammerspoon's `additionalActions` has known glitches. The canvas card
guarantees Done / Snooze / **Too early** buttons (the feedback loop that turns
false positives into training data), supports hover-to-pin, and demos like a
product. `hs.notify` remains available as a passive mirror channel.

## Sensing ladder (implemented rungs)

1. Frontmost app + focused window title — event-driven (app switch, wake) + 5s poll
2. Browser active tab URL + title — AppleScript, Chrome-family + Safari
3. Media playback state — optional, via `brew install media-control`
   (`nowplaying-cli` also detected but broken on macOS 15.4+)
5. Full window/screen OCR — **on-demand only** (⌃⌥⌘S or `CR.screenText.capture`),
   never in the 5s poll: continuous full-screen OCR is a CPU and privacy
   firehose. Apple Vision, 100% on-device, ~4–5s per busy retina window.
   Bonus signal: a window snapshot includes the browser's tab strip, so OCR
   sees background-tab titles that the AppleScript active-tab query can't.

Rung 4 (Accessibility text dumps) is skipped for now — OCR covers apps with
weak AX support (GPU-rendered terminals like kitty, Electron apps) anyway.

## Install / enable

Loaded from `~/.hammerspoon/init.lua`:

```lua
local crPath = os.getenv("HOME") .. "/Documents/code/JAMW/wispr-takehome/contextual-reminders/hammerspoon"
package.path = package.path .. ";" .. crPath .. "/?.lua;" .. crPath .. "/?/init.lua"
local ok, err = pcall(require, "cr")
if not ok then print("[cr] failed to load: " .. tostring(err)) end
```

Permissions:
- **Accessibility** (Hammerspoon) — required for window titles; already granted if Hammerspoon hotkeys work.
- **Automation** — first browser-tab query pops "Hammerspoon wants to control Chrome/Safari"; approve once.

## Controls

- Menu bar `◉` — status, pause/resume observer, test notification, open logs
- `⌃⌥⌘T` — send test notification through the full dispatch pipeline
- `⌃⌥⌘C` — show current context snapshot as a card
- Console: `hs -c "print(hs.inspect(CR.observer.current))"`

## Notification channels

| channel   | transport                          | config |
|-----------|------------------------------------|--------|
| `card`    | canvas UI (primary)                | default |
| `system`  | hs.notify mirror (no buttons)      | opt-in |
| `discord` | webhook                            | auto: reuses `DISCORD_WEBHOOK_URL` from `~/.claude/settings.json`, or `secrets.lua` |
| `slack`   | incoming webhook                   | `secrets.lua` |
| `webhook` | generic JSON POST fanout           | `secrets.lua` |

Presence routing: if idle > `config.idleThreshold` (3 min), payloads are also
mirrored to `config.remoteChannels` — deliver where the user actually is.

## Event log

JSONL, one file per day in `logs/`. Event types so far: `cr.loaded`,
`observer.start/stop`, `context.change`, `context.heartbeat`,
`notify.dispatch`, `notify.<channel>.sent/skipped`, `card.action`,
`card.timeout`, `card.dismissed`, `feedback`.

`card.timeout` vs `card.action` is the first stickiness metric: did the user
act on a card, or let it expire?
