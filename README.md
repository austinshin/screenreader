# Contextual Reminders

A prototype for the Wispr Flow exploration: **you say what to remember, your screen decides when to surface it.**

```
control+option+command+N  →  "reply to this thread once I'm done here"
   … keep working …
   you close the thread, switch apps  →  the reminder appears
```

No clock. The trigger is *"you finished the thing you were looking at."*

**Setup:** `./setup.sh` — then [RUNNING.md](RUNNING.md) for daily use, config, and debugging.

---

## What it does

**Input** — three ways, all landing in the same code path:

| | |
|---|---|
| ⌨️ **Hotkey** | `control+option+command+N`, type it |
| 🎙 **Voice** | *"hey screenreader, remind me to reply to this once I'm done here"* |
| 💡 **Screen inference** | off by default — see [The experiment](#the-experiment-screen-inference) |

The brief's own phrasings work as written, with the condition split from the task:

| You say | Task | Bound to |
|---|---|---|
| "look into embeddings **after I finish watching this video**" | look into embeddings | the video's tab |
| "**once I'm done testing the gate**, share progress in #eng" | share progress in #eng | the window you were testing in |
| "update Megan **when I wrap up this conversation on Slack**" | update Megan | that Slack conversation |

Add a time instead (*"in 5 minutes"*, *"at 130"*, *"at 5pm august 1"*) and it becomes an ordinary scheduled reminder. Both exist; screen-bound is the interesting one.

**Output** — a card that waits for an answer (Done / Snooze / Too early) rather than timing out, since a reminder that dismisses itself has failed invisibly. Delivery defaults to a local card; per reminder you can route it to Notification Center, Discord, Slack, or a webhook from the dashboard.

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
- **Reversible.** Come back to the thing and it re-arms. "Too early" on the card sends it all the way back to PENDING — that button is the only signal that the system was wrong about you, and nothing else can provide it.

**What "this" means** is resolved per surface: a browser tab is identified by URL (video IDs normalized, so seeking or a title change doesn't break the binding); everything else by app + normalized window title. With `media-control` installed, a video still playing in a background tab counts as *not done*.

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
- **On-device throughout** — window titles via Accessibility, OCR via Apple Vision, speech via `hear -d`. The only thing that leaves the machine is the optional inference experiment's API call.

**Decision log** — `logs/decisions-*.md`, plain English, written as it happens:

> **## 1:37 PM · reminder fired — make a grocery list**
> - **why now:** the time you set arrived (1:37 PM)
> - **set:** 1:32 PM from "in 5 minutes"
> - **waiting on:** you — the card stays up until you answer it

A tool that acts on its own reading of your screen should be able to say why, without you reconstructing it from state transitions.

---

## The experiment: screen inference

Reading the screen to *infer what to remind you about* — as opposed to *when to surface what you said* — is **off by default** (`config.suggestions.enabled`). It's the most technically interesting part and the least product-ready, and the brief didn't ask for it.

The pipeline: full-screen OCR (~45,000 lines/day) → a cheap gate → Claude for extraction → a learned scoring layer with a labeling UI.

The gate is where the real work is. The first version treated a clock time as evidence of a commitment — but **in a chat app every line has a timestamp, so a timestamp carries zero information**. It was dropping *"hey make sure to create a PR"* while keeping *"so if like u were to tell me"*.

The fix was to strip chat chrome before judging anything, which hands you the signal that actually answers the question — **whose obligation is this?**

```
Saujas: make sure to open a PR   →  someone assigning you work    KEEP
Link:   I'll send the demo       →  you committing                KEEP
Megan:  I'll handle the deploy   →  somebody else's task          DROP
Link:   can you review my PR?    →  you assigning someone else    DROP
```

Measured, not asserted: `python3 service/test_gate.py` — 26 labeled lines, F1 0.76 → 1.00. Then replayed over a full day of real captures (45,008 lines → 98 kept), which is what surfaced two bugs the synthetic tests missed.

Even so: of the first 26 candidates I labeled, I kept **one**. Honest, and not good enough to put in front of a user.

---

## The four questions

**1. Which use cases did I focus on?**
The brief's middle example, generalized: *"remind me about X once I'm done with the thing I'm looking at."* My own version is closing a PR review or a doc and needing to tell someone about it — the reminder has to survive the ten seconds between finishing and forgetting. I deliberately did **not** chase "remind me when I open Y" (that's a launcher) or connector triggers (plumbing, not a question about screens).

**2. How did I sequence experiments? Where did I spend time?**
Sensing first, since everything depends on knowing what's on screen; then the state machine, since that's where "done" is actually defined; then delivery; then the inference experiment. Most of the *thinking* went into the FSM — edge-triggered, debounced, seam-gated, three properties that each came from a specific way the naive version was wrong — and into the gate's precision. Most of the *debugging* went into things that only appear in real use: a keyboard tap that dropped keystrokes system-wide, a scoring bug that silently zeroed every candidate, speaker names with spaces attributing everyone's words to me.

**3. Did I use it organically?**
Yes, and it changed the project twice. Using it is how I found reminders firing seconds after being set — the time parser was failing silently and falling back to a *contextual* reminder, so "1:30 tomorrow" became "four seconds from now." It's also how I learned a 40-item suggestion inbox is unusable, and that cards timing out meant I missed them. What I'd try next: binding to a **person or thread** rather than a window, since "when I wrap up this conversation" is really about the conversation, not the app.

**4. Where did I trade quality for velocity? What had to stay robust?**
Traded: the dashboard is one Python file with an HTML string in it, no build step, no tests; the OCR→candidate pipeline has no schema versioning; suggestion dedupe is lexical (Jaccard + containment) where it wants embeddings. Kept robust: the **trigger FSM** (driven by synthetic snapshots so `./smoke-test.sh` tests it without waiting on wall-clock), the **gate** (labeled eval + real-capture replay), and **persistence** (reminders survive reload and reboot; unanswered cards are restored on start). The rule: anything that can silently lose a reminder gets tests, anything cosmetic doesn't.

---

## Verify

```sh
./smoke-test.sh                 # seven layers in ~20s, nonzero exit on failure
python3 service/test_gate.py    # the gate eval
./start                         # dashboard → http://localhost:8765
```

`control+option+command+K` shows the hotkey cheatsheet — drag it anywhere, it remembers where.
