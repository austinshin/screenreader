# Code walkthrough

For someone who has to edit this. Follows one reminder from the words you say to the card on your screen, naming the file and function at each step, then documents every module.

Start with **[The one path that matters](#the-one-path-that-matters)**. If you only read one section, read that.

---

## Two processes, one folder

| | Runs as | Owns | Talks to the other via |
|---|---|---|---|
| **Lua** (`hammerspoon/cr/`) | inside Hammerspoon | sensing, state machines, cards, hotkeys, voice, **all reminder state** | writes `data/`, `logs/` |
| **Python** (`service/`) | two background processes | the dashboard, the OCR→suggestion pipeline | reads `data/`, `logs/`; calls back with `hs -c` |

**Lua owns `data/reminders.json`.** The dashboard never writes it — it shells out to `hs -c` so Hammerspoon's in-memory copy and the file can't diverge. If you add a mutation, add it in Lua and call it from Python, not the reverse.

---

## The one path that matters

You say *"hey screenreader, remind me to reply to this once I'm done here."*

```
hear (launchd) ──▶ voice.lua ──▶ reminders.lua ──▶ trigger.lua ──▶ notifier.lua ──▶ notify_ui.lua
   transcript       parse+debounce   store+classify   watch+decide     route          draw card
```

**1. `hear` writes a transcript.** A launchd agent (`~/Library/LaunchAgents/cr.voice.hear.plist`, written by `voice.lua:writePlist`) runs `hear -d` and appends growing partial transcripts to `~/Library/Logs/cr-voice/voice-transcript.log`.

> Why launchd and not `hs.task`: a child process's mic permission is attributed to its *responsible process*. Spawned from Hammerspoon, macOS attributes it to Hammerspoon — which has no speech-recognition usage string — and kills it instantly (exit 6). As its own agent, `hear` asks for its own permissions.

**2. `voice.lua` turns transcript lines into a command.** `poll` (every 0.35s) tails the file and calls `M._ingest(line)` per line:

| Function | Job |
|---|---|
| `M._wakeAt(line)` | is the wake word present, and where? Drives the HUD *before* a full command exists. |
| `M._parse(line)` | wake word → strip everything up to it → match `remind me to (.+)` |
| `boundCommand(text)` | **where the command ends.** A stated time terminates it; otherwise a 16-word cap. |
| `sameThing(a, b)` | content-word overlap, for the duplicate guard |
| `arm()` / `M._settleNow()` | fire once the transcript stops changing for `settleSeconds` |

> Three bugs live here, and the comments say so: the command had no end (captured whole conversations), the settle timer fired mid-sentence, and the dupe guard only caught *extensions* when the recognizer *revises*. `cr/test_capture.lua` replays the real transcripts that caused them.

**3. `reminders.lua:M.add(text, snap, opts)` — the single funnel.** Voice, hotkey, and suggestion-accept all land here, so they cannot drift:

```lua
condition.extract(text)  -- "…once I'm done here" → task + condition phrase
timeparse.extract(text)  -- "…in 5 minutes"       → task + triggerAt
matcher.bind(snap)       -- what "this" refers to
tier.classify(text, …)   -- how loud it's allowed to be
```

Then it stores the reminder, appends `reminder.created` to the event log, and writes a plain-English entry via `why.lua`.

The initial `state` is the fork in the whole product:

```lua
state = dueAt and "scheduled"                       -- fires on the clock
     or (matcher.matches(ref, snap) and "armed"     -- thing is on screen now
                                     or "pending")  -- wait for it to appear
```

**4. `trigger.lua` decides *when*.** `observer.lua` samples context every 5s and calls `M.tick(snap)`. Per reminder, per tick:

- `retier(r, snap)` — recompute the attention tier (consequence nearer? context arrived?)
- `step(r, snap)` — advance the state machine
- `checkDue()` — separate 1s timer for `scheduled` reminders

```
PENDING ──seen──▶ ARMED ──absent──▶ COOLDOWN ──absent × 6──▶ READY ──gate──▶ FIRED
                    ▲                  │ present                │ present
                    └──────────────────┴──────── re-arm ────────┘
```

> **Why edge-triggered.** "Remind me when I'm not watching the video" is *true the instant you make the reminder* — you're in the dialog, not the video. So it must see the thing present, then gone, then stay gone. COOLDOWN debounces a glance away; READY waits for a seam (app switch or return from idle) so it never lands mid-sentence. `tier.bypassesSeamGate()` is the single exception: **critical**.

**5. `notifier.lua:M.notify(payload, opts)` routes.** A channel registry (`card`, `system`, `discord`, `slack`, `webhook`) — `M.register(name, fn)` adds one. If you've been idle past `config.idleThreshold` it also mirrors to `config.remoteChannels`.

**6. `notify_ui.lua:M.show(opts)` draws.** An `hs.canvas` card, top-right, stacking downward.

| opt | Effect |
|---|---|
| `title` | small header |
| `lead` | the prominent line — what the card is *about* |
| `body` | supporting text |
| `sticky` | **no timeout**, body-clicks ignored, ✕ added |
| `actions` | buttons, right-aligned |

> Fired reminders are `sticky`. One that dismisses itself has failed at its only job, and failed invisibly. Suggestions stay timed — an offer that won't go away is nagging.

---

## Every file

### Lua — `hammerspoon/cr/`

| File | Lines | What it owns |
|---|--:|---|
| `init.lua` | 89 | Load order, wires handlers into the hotkey registry, exposes `CR` global for `hs -c` |
| `config.lua` | 85 | Every tunable. Read at call time, so edit + reload takes effect immediately |
| `observer.lua` | 196 | Samples context every 5s: app, window title, browser tab (AppleScript), media, idle. Publishes to subscribers |
| `matcher.lua` | 94 | What "this" means. `bind()` makes a referent; `matches()` tests presence. URL-keyed for browsers (video IDs normalized), title-keyed otherwise |
| `reminders.lua` | 218 | The store. `add` (the funnel), `confirm` (creation card), `describe`, `setState`, `promptNew` (hotkey dialog) |
| `trigger.lua` | 292 | The FSM, `retier`, `checkDue`, `fire`, `restoreFired` |
| `tier.lua` | 109 | Attention tiers 1–4 from language + binding. `bypassesSeamGate` is the load-bearing rule |
| `timeparse.lua` | 264 | Date and time out of text. Independent halves, combined — see below |
| `condition.lua` | 76 | Splits "…after I finish watching this" from the task |
| `notifier.lua` | 175 | Channel registry + presence routing |
| `notify_ui.lua` | 218 | The canvas card |
| `listening.lua` | 153 | Live transcription HUD (listening → capturing → created) |
| `voice.lua` | 406 | launchd agent, transcript tailing, wake word, debounce, dupe guard |
| `hotkeys.lua` | 165 | **One registry** for every binding; user overrides in `data/hotkeys.json` |
| `keys.lua` | 257 | The draggable cheatsheet. Reads `hotkeys.list()` — never its own copy |
| `menubar.lua` | 149 | Status icon and menu |
| `screen_text.lua` | 256 | OCR: window snapshot → `bin/cr-ocr` (Apple Vision) → JSONL |
| `viewer.lua` | 174 | Panel showing what OCR actually read |
| `suggestions.lua` | 270 | Consumes `candidates.jsonl`. **Off by default** |
| `why.lua` | 60 | The decision log — English, not JSON |
| `log.lua` | — | JSONL event append |
| `test_capture.lua` | 99 | Replays recorded transcripts. Run: `hs -c 'require("cr.test_capture").run()'` |

### Python — `service/`

| File | Lines | What it owns |
|---|--:|---|
| `ui.py` | 1165 | The whole dashboard: `snapshot()` builds state, `PAGE` is the HTML/CSS/JS string, `Handler` is the routes |
| `extract.py` | 854 | OCR → candidates. The gate, the extractors, the learning layer |
| `test_gate.py` | 119 | Labeled gate eval. `python3 service/test_gate.py` |

---

## The parts most likely to confuse you

### `timeparse.lua` — two halves, combined

`findDate` and `findTime` run **independently**, then merge.

> The earlier version matched one pattern across the whole phrase, so `"at 5pm august 1"` hit `at 5pm` and dropped the date — it fired the same afternoon. Split, either half can stand alone: a date with no time means 9am, a time with no date means its next occurrence.

Speech rarely produces a colon, so `at 130`, `at 1 30`, `at 1130` all read as h:mm. Filler is tolerated (`in like five minutes`) — not politeness, but because that phrase failing cost both the time *and* `voice.lua`'s command boundary.

### `extract.py` — the gate is the interesting part

```
OCR text → gate (regex, free) → extractor (Claude) → dedupe → score → candidates.jsonl
```

`gate(text, source)` does the real work:

1. `split_chat_line` — strip `[10:45 AM]` and `Name:` **before judging anything**
2. Decide by **speaker**: someone else's directive at you = keep; their own commitment = drop; your `SELF_COMMIT` = keep; you assigning others = drop

> In a chat app every line has a timestamp, so a timestamp carries **zero information** — yet v1 treated it as commitment evidence, dropping *"hey make sure to create a PR"* while keeping *"so if like u were to tell me"*. Stripping chrome also hands you the speaker, which is the only thing that answers *whose obligation is this?*

`score()` uses a **geometric mean**, not a product. Multiplying six sub-1.0 weights turned a 0.7 candidate into 0.10 and silently made the learning layer an off switch.

### `ui.py` — one file, on purpose

No build step; `python3 service/ui.py` is the whole deployment. `PAGE` is a raw string containing HTML, CSS, and JS.

- **`$(id)`** replaces `getElementById` — returns a warning stub instead of null. One renamed id used to throw and blank the entire page.
- Every section renders from one `load()` on a 4s interval.
- Writes go through `hs()` because **Lua owns reminder state**.
- `hs(lua, timeout=…)` — reads use 4s, writes use 15s. Rebinding nine hotkeys exceeded the read budget and reported success as failure.

---

## How to make common changes

| Want to | Do this |
|---|---|
| Add a delivery channel | `notifier.M.register("name", fn)` + a row in `M.available()`; the picker updates itself |
| Add a hotkey | One entry in `hotkeys.ACTIONS` + a handler in `init.lua`. Cheatsheet and Settings follow |
| Change when things fire | `config.trigger` (`absentSamples`, `maxReadyWait`) |
| Add a time phrasing | A pattern in `timeparse` `findTime`/`findDate`/`findRelative` |
| Change tier inference | `tier.SIGNALS` — each row is `{pattern, tier, why}`, and `why` is user-visible |
| Add a dashboard section | Markup in `PAGE`, a render call in `load()`, data in `snapshot()` |
| Turn the inference experiment on | `config.suggestions.enabled = true` |

**Never** use `hs.eventtap` for a permanent hotkey. It runs a callback on every keystroke system-wide, and Hammerspoon is single-threaded — an OCR capture or AppleScript call starves it and macOS drops your keystrokes. This happened; `init.lua` carries the scar tissue in comments.

---

## Verifying a change

```sh
./smoke-test.sh                                  # seven layers, ~20s
python3 service/test_gate.py                     # gate precision/recall
hs -c 'require("cr.test_capture").run()'         # voice capture
luac -p hammerspoon/cr/*.lua                     # Lua syntax
```

Debugging: `logs/decisions-*.md` says *why* in English; `logs/events-*.jsonl` says *what*; `hs -c "print(hs.inspect(CR.observer.current))"` shows live context.

> `hs -c` hangs if Hammerspoon isn't running. Always `open -a Hammerspoon` first, and wrap CLI calls in a timeout in scripts.
