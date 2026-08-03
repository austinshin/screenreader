# Extraction service

Turns the OCR stream into scored reminder candidates, and learns which signals
are worth surfacing from what you do with them.

```
OCR text ──▶ gate ──────▶ extractor ──▶ dedupe ──▶ score ──▶ candidates.jsonl
             (regex)      rules|claude   vs seen   learned         │
             1.8% survive                          weights         ▼
                                                            cr.suggestions
                                                          card / inbox / drop
                                                                   │
                                              Add · Not mine · Dismiss
                                                                   │
                                                            feedback.jsonl
                                                                   │
                                                        --learn ──▶ weights.json
```

## Running

```sh
python3 -m venv .venv && .venv/bin/pip install anthropic   # once

.venv/bin/python service/extract.py --once      # process new captures
.venv/bin/python service/extract.py --watch     # poll forever (30s)
.venv/bin/python service/extract.py --learn     # recompute weights from feedback
.venv/bin/python service/extract.py --stats     # weights + precision so far
```

Backend is chosen automatically: `local` when Ollama is running (same job,
nothing leaves the machine), else `claude` when `ANTHROPIC_API_KEY` is set (or
a Keychain item exists), else `rules`. Force with `--backend rules|claude|local`.

## The three backends

| | `rules` | `claude` | `local` |
|---|---|---|---|
| Needs | nothing | API key | Ollama running (a ~3B instruct model) |
| Extraction | regex patterns + heuristics | `claude-opus-5`, structured output, precision-first system prompt | same prompt + schema-constrained decoding, on this machine |
| Determinism | fully replayable | not replayable | not replayable |
| Measured precision | **~2%** (see below) | not yet measured | not yet measured |

The gate runs before **both**. It is the cost control: full-screen OCR yields
thousands of lines per capture and almost none are commitments. Measured on 100
real captures, the gate passed **143 of 8111 lines (1.8%)** to the extractor.

## Measured: why the LLM layer is necessary

Run against 100 real captures with the rules backend:

```
100 captures · 8111 lines → 143 gated (1.8%) → 60 candidates
would interrupt (score >= 0.55):  0
inbox only (0.30 – 0.55):        60
```

(Recorded when the inbox floor was 0.30; it has since moved to 0.50 —
`THRESH_INBOX` in `extract.py` — because below half-confidence the extractor
is guessing at whether the user is even the one on the hook.)

Of those 60, roughly one was a real commitment. The rest were Facebook
messages, my own prose in a terminal, Markdown headings, and a status-page
excerpt. **Regexes can find text containing "I'll"; they cannot tell whose
obligation it is, or whether it is already done.** That is the specific
judgement the `claude` backend exists to make, and this run is the evidence for
why the escalation is worth its cost rather than a speculative addition.

The second finding is more encouraging: **zero of the 60 false positives would
have interrupted.** They all scored below the fire threshold and landed in the
silent inbox. The tiering absorbed a 98%-wrong extractor without spending any
of the user's attention — which is the whole argument for tiered confidence
rather than a single accept/reject cutoff.

## How the learning works — and why it isn't a trained model

There is nothing to train on at t=0: no labels, no data, and the label that
matters (did the user act on it?) does not exist until reminders start
shipping. So the system learns **thresholds** online from the only signal that
is cheap, honest, and continuously available — what you press on each card.

- `accept` → +1 for every feature of that candidate
- `dismiss` / `not mine` → −1
- `too early` → timing was wrong, content was right; **no weight change**

Features are coarse and interpretable on purpose: `app:Slack`,
`kind:commitment`, `explicit:true`, `time:morning`, `temporal:true`,
`backend:rules`. Coarse features need few examples to become useful, and a
weight you can read is a weight you can debug.

`score = confidence × ∏(feature multipliers)`, where each multiplier is a
Laplace-smoothed accept rate mapped to 0.4 – 1.6. A feature you never accept
decays and stops interrupting you. This is the exploit half of a contextual
bandit; the explore half is that medium-scored candidates still land in the
inbox instead of being dropped, so they can be labelled at zero attention cost.

Verified end-to-end with three labels:

```
feature                              mult    ✓    ✗
app:Slack                            1.15    1    0
kind:commitment                      1.15    1    0
explicit:true                        1.15    1    0
app:Google Chrome                    0.76    0    2
kind:task                            0.76    0    2
explicit:false                       0.76    0    2
```

**When there is enough labelled data** (hundreds of accept/dismiss pairs), the
same feature vectors and labels become the training set for an actual
classifier, or few-shot examples appended to the extractor prompt. The feedback
log is the dataset either way — which is why it is logged in this shape from day
one rather than as a bare event counter.

## Files

| Path | What |
|---|---|
| `data/candidates.jsonl` | scored candidates (Lua tails this) |
| `data/feedback.jsonl` | labels + feature vectors — the training set |
| `data/weights.json` | learned per-feature multipliers |
| `data/extract_state.json` | per-file cursor + seen-candidate hashes |

All gitignored. Same privacy posture as the OCR logs: candidates quote screen
text, so they stay local.
