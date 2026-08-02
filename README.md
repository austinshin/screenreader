# Contextual Reminders

A prototype for the Wispr Flow exploration: **you say what to remember, your screen decides when to surface it.**

```
control+option+command+N  →  "reply to this thread once I'm done here"
   … keep working …
   you close the thread, switch apps  →  the reminder appears
```

No clock. The trigger is *"you finished the thing you were looking at."*

**Setup:** [INSTALL.md](INSTALL.md) — or just `./setup.sh`. 
**Daily use, config, debugging:** [RUNNING.md](RUNNING.md). **Code walkthrough:** [ARCHITECTURE.md](ARCHITECTURE.md).

---

## What it does

**Input** — three ways, all landing in the same code path:

| | |
|---|---|
| 🎙 **Hold to speak** | hold `control+option+command+D`, say it, release — Whisper, on-device |
| ⌨️ **Hotkey** | `control+option+command+N`, type it |
| 💡 **Screen inference** | off by default — see [The experiment](#the-experiment-screen-inference) |

The brief's own phrasings work as written, with the condition split from the task:

| You say | Task | Bound to |
|---|---|---|
| "look into embeddings **after I finish watching this video**" | look into embeddings | the video's tab |
| "**once I'm done testing the gate**, share progress in #eng" | share progress in #eng | the window you were testing in |
| "update Megan **when I wrap up this conversation on Slack**" | update Megan | that Slack conversation |

Add a time instead (*"in 5 minutes"*, *"at 130"*, *"at 5pm august 1"*) and it becomes an ordinary scheduled reminder. Both exist; screen-bound is the interesting one.

**Output** — a card that waits for an answer (**Done · 5 min · Snooze**) rather than timing out, since a reminder that dismisses itself has failed invisibly. Delivery defaults to a local card; per reminder you can route it to Notification Center, Telegram (i.e. your phone), Discord, Slack, or a webhook from the dashboard.

**At a glance** — `command+option+shift+R` puts every reminder in a corner panel. The dashboard is a browser tab: fine for reviewing, useless for the question you actually ask twenty times a day mid-task.

---

## Why "done with this" is the hard part

The naive version fires instantly. If the rule is *"remind me when I'm not watching the video"*, that's true the moment you make the reminder — you're in the reminder dialog, not the video.

So completion is **edge-triggered**, never level-triggered. It has to *see the thing present*, then see it go away, and stay away:

```
PENDING ──seen──▶ ARMED ──absent──▶ COOLDOWN ──absent × 6──▶ READY ──gate──▶ FIRED
                    ▲                  │ present                │ present
                    └──────────────────┴──────── re-arm ────────┘
```

Three deliberate properties:

- **Debounced.** A glance at Slack and back isn't "done" — six consecutive absent samples (~30s) before it counts.
- **Gated on a seam.** Even when READY it waits for an app switch or your return from idle, so a reminder never lands mid-sentence. A max-wait backstop stops it sitting there forever.
- **Reversible.** Come back to the thing and it re-arms. This is the most common reason a reminder *seems* stuck, so the count is now on the reminder itself — *"you left Obsidian · 3 of 6 checks away"* — because one check from firing and endlessly resetting used to look identical from outside.

The same edge-triggered rule extends to conditions about the world rather than about you. *"Merge the PR after the tests run"* binds to the word "tests" and watches OCR text: it must see the tests **running** before it will accept them **finished**, so the previous run's `12 passed` still sitting in your terminal can't fire it the moment you ask.

**What "this" means** is resolved per surface: a browser tab is identified by URL (video IDs normalized, so seeking or a title change doesn't break the binding); everything else by app + normalized window title. With `media-control` installed, a video still playing in a background tab counts as *not done*.

---

## How loudly it speaks

"When to surface" turned out to be only half the question. The other half is *how loudly* — one delivery style for four kinds of thing means either the alerts are too quiet or the trivia is too loud, and after a week you read none of them.

| Tier | Interrupts? | Inferred from |
|---|---|---|
| **Critical** | immediately — the only tier that skips the seam gate | "before it closes", "urgent", "deadline" |
| **Upcoming** | at a natural break | "don't forget", or a commitment to a person |
| **In context** | when you're done with the thing | a screen binding |
| **Ambient** | **never** — dashboard and menu bar only | "keep an eye on", "at some point" |

The tier isn't a label, it's a **function that gets recomputed**. "Take out the trash" is ambient at 2pm, upcoming at 7pm, and critical the night before collection — nothing about it changed except distance from consequence. Every move is logged with its reason.

---

## Architecture

```
     screen ──▶ observer (5s: app, title, tab, media, idle)
                    │
                    ├──▶ trigger FSM ──▶ notifier ──▶ card / Notification Center / Discord …
                    │        ▲
     you ──────────────▶ reminders ─┘
        voice / hotkey
```

- **Hammerspoon (Lua)** — sensing, state machine, cards, hotkeys, voice. `hammerspoon/cr/`
- **Python, stdlib only** — the dashboard at `localhost:8765`. `service/ui.py`
- **On-device throughout** — window titles via Accessibility, OCR via Apple Vision, speech via Whisper (`whisper.cpp`, ~0.4s per utterance on an M1 Pro). The only things that leave the machine are the optional inference experiment's API call and whatever channels you explicitly enable.

Every channel receives the same versioned object rather than a message each one invents:

```json
{ "schema": "cr.notification/v1", "event": "reminder.fired",
  "body": "merge the PR", "tier": { "level": 1, "name": "critical" },
  "trigger": { "gate": "content", "why": "the tests finished (12 passed, 0 failed)" },
  "actions": [ { "id": "done", "label": "Done" }, { "id": "defer_5", "label": "5 min" } ] }
```

Two fields earn their place. `trigger.why` travels because on a phone there is no screen context to reconstruct why something arrived. Actions carry an **id** rather than only a label because labels get reworded — "Too early" became "5 min" during this project — and an id is the only thing that makes a reply addressable later without a breaking change.

**Decision log** — `logs/decisions-*.md`, plain English, written as it happens:

> **## 1:37 PM · reminder fired — make a grocery list**
> - **why now:** the time you set arrived (1:37 PM)
> - **set:** 1:32 PM from "in 5 minutes"
> - **waiting on:** you — the card stays up until you answer it

A tool that acts on its own reading of your screen should be able to say why, without you reconstructing it from state transitions.

---

## The experiment: screen inference

Reading the screen to *infer what to remind you about* — as opposed to *when to surface what you said* — is **off by default** (`config.suggestions.enabled`). It's the most technically interesting part and the least product-ready, and the brief didn't ask for it.

The pipeline: full-screen OCR (~45,000 lines/day) → a cheap gate → an extractor → a learned scoring layer with a labeling UI. Three interchangeable extractors: regex rules, Claude, or **any local Ollama model** — the gate drops ~99.8% of lines, so only ~100 a day reach it, which is what makes a 3B model on-device viable.

The gate is where the real work is. The first version treated a clock time as evidence of a commitment — but **in a chat app every line has a timestamp, so a timestamp carries zero information**. It was dropping *"hey make sure to create a PR"* while keeping *"so if like u were to tell me"*.

The fix was to strip chat chrome before judging anything, which hands you the signal that actually answers the question — **whose obligation is this?**


Measured, not asserted: `python3 service/test_gate.py` — 26 labeled lines, F1 0.76 → 1.00. Then replayed over a full day of real captures (45,008 lines → 98 kept), which is what surfaced two bugs the synthetic tests missed.

Even so: of the first 26 candidates I labeled, I kept **one**. Honest, and not good enough to put in front of a user.

---

## The four questions

**1. Which use cases did I focus on?**
The brief's middle example, generalized: *"remind me about X once I'm done with the thing I'm looking at."* My own version is closing a PR review or a doc and needing to tell someone about it — the reminder has to survive the ten seconds between finishing and forgetting. I deliberately did **not** chase "remind me when I open Y" (that's a launcher) or connector triggers (plumbing, not a question about screens).

**2. How did I sequence experiments? Where did I spend time?**
Sensing first, since everything depends on knowing what's on screen; then the state machine, since that's where "done" is actually defined; then delivery; then the inference experiment. Most of the *thinking* went into the FSM — edge-triggered, debounced, seam-gated, three properties that each came from a specific way the naive version was wrong — and into the gate's precision. Most of the *debugging* went into things that only appear in real use: a keyboard tap that dropped keystrokes system-wide, a scoring bug that silently zeroed every candidate, speaker names with spaces attributing everyone's words to me.

**3. Did I use it organically?**
Yes, and every significant correction came from use rather than planning. Reminders were firing *seconds* after being set — the time parser failed silently on "at 130" and fell back to a contextual reminder, so "1:30 tomorrow" became "four seconds from now." One sentence created two reminders during a live demo, which turned out to be three separate capture bugs. A 40-item suggestion inbox is unusable. Cards that time out get missed. And I built the reminder hotkey as a system-wide keyboard tap to support `fn`, which **dropped keystrokes while typing anywhere on the machine** — a modifier you can't have is a smaller problem than a keyboard that doesn't work.

The largest correction came from all of that at once. Every capture bug traced to the same root: an always-on recognizer never tells you where an utterance starts or ends, so the code had to *guess both* — a wake word, a settle timer, a word cap, an overlap check, a cooldown — and each guess had its own failure mode. Switching to **push-to-talk with Whisper** deleted all five mechanisms rather than fixing them, because a held key answers both questions exactly. That is the shape of fix worth looking for: not a better heuristic, but a change that means the heuristic isn't needed.

What I'd try next: binding to a **person or thread** rather than a window, since "when I wrap up this conversation" is really about the conversation, not the app.

**4. Where did I trade quality for velocity? What had to stay robust?**
Traded: the dashboard is one Python file with an HTML string in it, no build step, no tests; the OCR→candidate pipeline has no schema versioning; suggestion dedupe is lexical (Jaccard + containment) where it wants embeddings. Kept robust: **capture** (`cr.test_capture` replays recorded transcripts, including the exact demo failure), the **trigger FSM** (driven by synthetic snapshots so `./smoke-test.sh` tests it without waiting on wall-clock), the **gate** (labeled eval + real-capture replay), and **persistence** (reminders survive reload and reboot; unanswered cards are restored on start).

The rule I settled on: **anything that can silently lose a reminder gets tests; anything cosmetic doesn't.** Silent failure is the whole risk class — a reminder that vanishes without telling you is worse than one that errors, because you can't notice the absence of something you never saw. Capture earns tests despite being the least interesting code here: it isn't the hypothesis, but if getting a reminder *in* is flaky you never form the habit, never use it daily, and never get to test the hypothesis at all.

---

## Verify

```sh
./smoke-test.sh                              # eight layers in ~30s, nonzero exit on failure
python3 service/test_gate.py                 # the gate eval
hs -c 'require("cr.test_dictate").run()'     # push-to-talk parser, on real whisper output
hs -c 'require("cr.test_capture").run()'     # the older wake-word path, on recorded transcripts
./start                                      # dashboard → http://localhost:8765
```

`control+option+command+K` shows the hotkey cheatsheet — drag it anywhere, it remembers where. Every shortcut is editable from the dashboard's **Settings** tab.

When something behaves oddly, read `logs/decisions-*.md` first: it says *why*, in English.
