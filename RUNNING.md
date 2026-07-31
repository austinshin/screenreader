# Running Contextual Reminders

Everything operational: starting, verifying, using, configuring, debugging.

## Quick start

```sh
./start          # dashboard (http://localhost:8765) + extraction service
./start status   # what's running
./start stop
```

The Hammerspoon side (observer, triggers, hotkeys, voice) loads via
`~/.hammerspoon/init.lua` — already wired. Three ways to create a reminder:

| How | Trigger |
|---|---|
| 🎙 voice | *"hey screenreader, remind me to water the plants in 5 minutes"* (toggle ⌃⌥⌘M) |
| ⌨️ hotkey | **fn⇧⌘N** — type it; time phrases understood |
| 💡 suggestions | accept from the menu-bar inbox or the dashboard |

Time phrases (*in 5 minutes*, *at 3pm*, *tomorrow at 9*) fire on the clock.
Without one, the reminder is contextual — it fires when you're done with the
thing that was on screen. Delivery defaults to a card on this Mac; each
reminder's channels (card / Notification Center / Discord / Slack / webhook)
are editable from the dashboard's Reminders list.

## Prerequisites

| Thing | Why | Check |
|---|---|---|
| [Hammerspoon](https://www.hammerspoon.org/) | runs the whole prototype | `ls /Applications/Hammerspoon.app` |
| `hs` CLI | console debugging (installed by `require("hs.ipc")`, already in init.lua) | `which hs` |
| Accessibility permission | reading focused-window titles | System Settings → Privacy & Security → Accessibility → Hammerspoon ✓ |
| Automation permission | browser tab URL/title via AppleScript | macOS prompts once per browser on first query — click OK |
| `media-control` *(optional)* | media playing/paused state (rung 3) | `brew install media-control` |
| Screen Recording permission *(for OCR)* | window snapshots | System Settings → Privacy & Security → Screen Recording → Hammerspoon ✓, then **restart Hammerspoon** |
| `bin/cr-ocr` *(for OCR)* | on-device Vision OCR helper | `swiftc -O ocr/cr-ocr.swift -o bin/cr-ocr` |

> `nowplaying-cli` is also auto-detected but is broken on macOS 15.4+; prefer `media-control`. Without either, everything still works — snapshots just have `media = nil`.

## Is it working? (one command)

```sh
./smoke-test.sh
```

Checks all seven layers in ~20s without waiting on wall-clock: module loaded,
observer sensing, OCR + permission, the trigger FSM (synthetic ticks), card
delivery, the extraction service, and log files. Prints `N passed, M failed` and
exits nonzero on failure, so it works as a pre-demo check or in CI.

## Daily use in 30 seconds

1. **Set a reminder:** look at the thing → `⌃⌥⌘R` → type what to remember → Enter.
2. **Walk away from it.** ~30s of real absence plus your next app switch → card fires.
3. **Answer the card:** Done / Snooze / **Too early** (the last one is the signal
   that trains the system — use it).
4. **Optional, opt-in:** `⌃⌥⌘W` turns on persistent screen-watching; `⌃⌥⌘V`
   shows what the OCR is reading; `.venv/bin/python service/extract.py --watch`
   turns captured text into suggested reminders.

## Starting it

The module loads automatically when Hammerspoon starts, via the loader stanza at the bottom of `~/.hammerspoon/init.lua` (it `pcall`s the require, so an error here can never break the rest of the config).

```sh
open -a Hammerspoon        # start (or restart the config from the HS menu bar icon → "Reload Config")
```

To make it survive reboots: Hammerspoon menu → Preferences → **Launch Hammerspoon at login**.

Reloading after editing any `cr/*.lua` file:

```sh
hs -c "hs.timer.doAfter(0.1, hs.reload)"
```

> **Gotcha:** a bare `hs -c "hs.reload()"` hangs the CLI — the reload kills the IPC connection the CLI is waiting on. The `doAfter` form replies first, then reloads. Also: if Hammerspoon isn't running at all, any `hs -c` hangs forever (it waits on a message port that doesn't exist) — `open -a Hammerspoon` first.

## Verifying it's alive

Three ways, in order of laziness:

1. **Menu bar** — a `◉` icon appears; its menu shows `👁 observing · <app> — <window title>`.
2. **Console query:**
   ```sh
   hs -c "print(hs.inspect(CR.observer.current))"   # current context snapshot
   hs -c "print(CR.observer.running)"               # true
   ```
3. **Event log** — a new line appears within ~5s of switching apps:
   ```sh
   tail -f logs/events-$(date +%Y-%m-%d).jsonl
   ```

## Using it

| Action | How |
|---|---|
| **Create a reminder** | `⌃⌥⌘R`, or menu bar → *New reminder…* |
| Test notification (full pipeline) | `⌃⌥⌘T`, or menu bar → *Send test notification* |
| Show current context as a card | `⌃⌥⌘C`, or menu bar → *Show current context* |
| **OCR the focused window** | `⌃⌥⌘S` — card shows char count + preview; full text → `logs/ocr-*.jsonl` |
| **Toggle persistent screen watching** | `⌃⌥⌘W` — auto-OCR on context change (sticky) |
| **Toggle the live OCR viewer** | `⌃⌥⌘V` — on-screen panel showing what OCR just read (sticky) |
| Manage reminders | menu bar → each reminder row has *Mark done* / *Cancel* |
| Pause / resume the observer | menu bar → *Pause observer* / *Resume observer* |
| Open the logs folder | menu bar → *Open logs folder* |
| Dismiss a card | click its background, or wait for auto-dismiss (12s; hovering pins it) |
| Card buttons | **Done / Snooze / Too early** — each writes a `feedback` event to the log |

## Creating reminders (the deictic flow)

1. Look at the thing — the YouTube video, the Slack thread, the terminal session.
2. `⌃⌥⌘R`. The dialog shows what "THIS" is bound to (the observer's last
   snapshot — captured *before* the dialog opens, so the dialog never becomes
   the referent).
3. Type what to be reminded of. **Watch it.**
4. A toast confirms: `👁 Watching: <app — title>` (born ARMED), or
   `⏳ Will arm on first sighting` if the thing wasn't on screen.
5. Walk away from the thing. ~30s of real absence + your next app switch →
   the reminder card fires.

States (visible per-reminder in the menu bar, badge shows active count):

| state | icon | meaning |
|---|---|---|
| pending | ⏳ | referent not yet seen; arms on first sighting |
| armed | 👁 | referent on screen; watching for it to end |
| cooldown | ⏱ | referent gone; counting absent samples (6 × 5s); returning re-arms |
| ready | 🕐 | really gone; waiting for an app switch to fire (90s backstop) |
| fired | 🔔 | card shown; unacknowledged cards stay here — resolve via menu bar |
| snoozed | 💤 | re-fires in 10 min |

**Too early** is the false-positive button: it sends the reminder back to
`pending` (you weren't done with the thing) *and* logs the miss — that's the
tuning data.

Reminders persist to `data/reminders.json` (gitignored), so `hs.reload()`
doesn't lose them.

### Scripted FSM test (no waiting)

Feed synthetic snapshots straight through the state machine:

```sh
hs -c "
local video = { app='Chrome', bundle='com.google.Chrome', tab='X - YouTube', url='https://www.youtube.com/watch?v=abc', reason='timer' }
local other = { app='Slack', bundle='com.tinyspeck.slackmacgap', title='#general', reason='timer' }
local r = CR.reminders.add('fsm smoke test', video)
CR.trigger.tick(other); CR.trigger.tick(video)          -- tab-away + back: re-arms
for i=1,6 do CR.trigger.tick(other) end                  -- really gone: ready
CR.trigger.tick({ app='Slack', bundle='x', reason='app-switch' })  -- gate: fires
print(r.state)  -- 'fired'
CR.reminders.setState(r, 'done', 'test')
"
```

Fire a custom notification from the console (handy for testing channels):

```sh
hs -c 'CR.notifier.notify({ title = "Manual test", body = "hello", icon = "👋", urgency = "warn" })'
hs -c 'CR.notifier.notify({ title = "Phone ping" }, { channels = { "discord" } })'
```

## Reading the event log

One JSONL file per day in `logs/`. Every module writes through it — it's the debug pane, the dogfooding journal, and the future replay-harness input.

```sh
# what changed on screen today
jq -r 'select(.event == "context.change") | "\(.iso)  \(.app)  \(.title // .url // "")"' logs/events-$(date +%Y-%m-%d).jsonl

# notification outcomes: acted on vs expired (the stickiness metric)
jq -r 'select(.event | startswith("card.")) | "\(.iso)  \(.event)  \(.title)"' logs/events-$(date +%Y-%m-%d).jsonl

# feedback button presses
jq 'select(.event == "feedback")' logs/events-*.jsonl
```

Event types: `cr.loaded`, `observer.start/stop`, `context.change`, `context.heartbeat`, `reminder.created`, `reminder.state` (every FSM transition, with `from`/`to`), `trigger.start/fired/error`, `notify.dispatch`, `notify.<channel>.sent/skipped`, `card.action`, `card.timeout`, `card.dismissed`, `feedback`.

```sh
# a reminder's full lifecycle
jq -r 'select(.event == "reminder.state") | "\(.iso)  \(.text)  \(.from)→\(.to)"' logs/events-$(date +%Y-%m-%d).jsonl

# false-positive rate: too_early / fired
jq 'select(.event == "feedback") | .value' logs/events-*.jsonl | sort | uniq -c
```

## Configuration

All tunables live in `hammerspoon/cr/config.lua` — edit, then reload. Highlights:

| Key | Default | Meaning |
|---|---|---|
| `pollInterval` | `5` | seconds between context samples |
| `idleThreshold` | `180` | idle seconds before you count as "away" |
| `remoteWhenAway` | `true` | mirror notifications to `remoteChannels` when away |
| `remoteChannels` | `{ "discord" }` | where "away" notifications also go |
| `defaultChannels` | `{ "card" }` | where every notification goes |
| `card.duration` | `12` | seconds before a card auto-dismisses |
| `browsers` | Chrome/Brave/Edge/Vivaldi/Arc/Safari | which apps get the tab query |

### Webhook channels

- **Discord:** works out of the box — it reuses `DISCORD_WEBHOOK_URL` from `~/.claude/settings.json` (the Claude stop-hook config). Override via `secrets.lua` if needed.
- **Slack / generic webhooks:** `cp hammerspoon/cr/secrets.example.lua hammerspoon/cr/secrets.lua`, fill in, reload. `secrets.lua` is gitignored.

## OCR: grab everything on screen as text

`⌃⌥⌘S` snapshots the **focused window**, runs it through Apple's Vision OCR
(100% on-device — nothing leaves the machine), and shows a preview card. From
the console:

```sh
hs -c "CR.screenText.capture(function(text, err) print(text or err) end)"                    # focused window
hs -c "CR.screenText.capture(function(text, err) print(text or err) end, { screen = true })" # whole screen
```

Privacy design, deliberately:
- **On-demand only** — never wired into the 5s poll. Continuous full-screen OCR
  is a CPU + privacy firehose (see: Microsoft Recall, Wispr's 2025 incident).
- **Split logging** — the main event log gets metadata only (`screen.ocr`,
  source, char count, duration); the full text goes to `logs/ocr-*.jsonl`,
  which is local and gitignored. Clear it anytime: `rm logs/ocr-*.jsonl`.

### Two capture modes

| mode | how | behavior |
|---|---|---|
| **manual** | `⌃⌥⌘S` | captures the focused window, once, when you ask |
| **auto** ("screen watching") | `⌃⌥⌘W` toggle, or menu bar → *Start screen watching* | OCRs every context change — **off by default**, opt-in |

**Auto mode is sticky.** The toggle is stored via `hs.settings` (persisted to
Hammerspoon's plist), so once you turn it on it stays on across `hs.reload()`,
app restarts, and reboots — until you turn it off. Since Hammerspoon is a login
item, that means truly always-on. Verify: `defaults read
org.hammerspoon.Hammerspoon | grep cr.watch` (`1` = on) or
`hs -c "return tostring(CR.screenText.watching)"`.

Auto mode guards (all in `config.watch`):
- **settle delay** (3s) — the new context must hold still before capturing; an
  app-switching spree yields one capture, not five
- **rate limit** (15s min between captures)
- **exclusion list** — password managers, Keychain, System Settings are never
  auto-captured; add bundles to `config.watch.excludeBundles`
- menu bar status shows `📸 auto-OCR` while watching

Every capture (either mode) produces **two outputs**:

| format | path | for |
|---|---|---|
| JSONL (machine) | `logs/ocr-YYYY-MM-DD.jsonl` — one line per capture with `mode` + `reason`; `file` field links to the readable twin | replay harness, jq, future trigger evidence |
| Markdown (human) | `logs/captures/YYYY-MM-DD_HH-MM-SS_<mode>_<App>.md` — header (source/mode/duration/chars) + full text | reading, grepping, dragging into Obsidian |

The filename answers "when, how, and from what" at a glance:
`2026-07-29_22-19-09_auto_Obsidian.md` vs `2026-07-29_20-57-46_manual_kitty.md`.

### Live viewer (`⌃⌥⌘V`)

An always-on-screen panel (top-left) showing **what the OCR actually read** —
source, mode, timestamp, char count, duration, and the full text. Every capture
(manual or auto) pushes into it live.

- `‹` / `›` page back through the last 25 captures; `✕` closes
- sticky, like watch mode: survives reloads and reboots
- also toggleable from the menu bar → *Show/Hide OCR viewer*
- it's a Hammerspoon canvas overlay, not a window, so per-window captures never
  photograph the viewer itself (whole-screen captures do)

This is the transparency surface: for a tool that reads your screen, "what does
it see?" should never require opening a log file.
- Expect ~4–5s per busy retina window (Vision "accurate" mode; a "fast" mode
  or downscaling is an easy tune if it ever gates a real trigger).

Neat side-effect: a window snapshot includes Chrome's tab strip, so OCR reads
**background tab titles** the AppleScript active-tab query can't see.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| any `hs -c` hangs forever | Hammerspoon isn't running → `open -a Hammerspoon` |
| OCR: "snapshot failed" | Screen Recording not granted, or granted without restarting Hammerspoon → grant, then `killall Hammerspoon && open -a Hammerspoon` |
| first-ever OCR hangs Hammerspoon | the macOS permission dialog blocks the main thread → answer the dialog on screen |
| OCR garbles text | Vision struggles with tiny fonts/low contrast; try `{ screen = true }` less, focused window more |
| `hs -c "hs.reload()"` hangs | expected — use the `doAfter` form above |
| window titles are `nil` | Accessibility permission missing → System Settings → Privacy & Security → Accessibility → enable Hammerspoon, then reload |
| browser `url`/`tab` always `nil` | Automation permission was denied → System Settings → Privacy & Security → Automation → Hammerspoon → enable the browser |
| no cards appear | check the log for `notify.dispatch`; if present, check HS console (menu bar → Console) for errors |
| `media` always `nil` | no media tool installed (fine), or install `media-control` |
| `context.change` spam from terminals | known: kitty's animated title spinner changes the title every frame — title normalization is on the roadmap |
| module didn't load at all | HS console shows `[cr] failed to load: <error>` — the pcall guard keeps the rest of the config alive; fix the error and reload |

## Disabling / uninstalling

- Temporary: menu bar → *Pause observer* (stops sampling; UI stays).
- Full: delete the "Contextual Reminders" stanza at the bottom of `~/.hammerspoon/init.lua` and reload. The repo and logs are untouched.
