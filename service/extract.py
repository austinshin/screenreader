#!/usr/bin/env python3
"""
extract.py — turn the OCR stream into reminder candidates, and learn which
signals are worth surfacing.

Pipeline per capture:

    OCR text ──▶ gate (cheap regex)  ──▶ extractor ──▶ dedupe ──▶ score ──▶ candidates.jsonl
                 drops ~everything       rules|claude   vs seen    learned      (Lua surfaces these)
                                                                  weights

Two extractor backends, same interface:

  rules   deterministic patterns; no API key, no network, fully replayable.
  claude  Claude API with structured output; catches phrasings no regex will.

The gate runs first in both cases — it is the cost control. Full-screen OCR
produces a lot of text per capture, and the overwhelming majority of it is not
a commitment. Sending all of it to an LLM would be expensive and slow; the gate
drops the noise so the expensive extractor only sees text that plausibly
contains a task.

The learning layer is deliberately *not* a trained model — see LEARNING below.

Usage:
    extract.py --once                 process new captures, then exit
    extract.py --watch                poll for new captures forever
    extract.py --learn                recompute weights from feedback
    extract.py --stats                show weights + precision so far
    extract.py --backend claude       force a backend (default: auto)
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
DATA = ROOT / "data"
MODEL = "claude-opus-5"

# ---------------------------------------------------------------- gate --------
# Cheap first pass. Only lines that could carry an intention survive to the
# extractor.
#
# The first version of this gate was tuned purely for recall and produced 377
# candidates of which ~1 was real. The failure modes were not random — they
# clustered, and each cluster has a structural fix:
#
#   1. SELF-CAPTURE. The tool read its own output: assistant prose in the
#      terminal, its own docs in the note app, its own capture files. A
#      screen-reading tool that writes to the screen will always feed on
#      itself unless it is told not to. → SELF_REF + source exclusion.
#   2. WRONG SOURCE. "I'll take that" in a game stream, a YouTube title, a
#      calendar row — the sentence looks like a commitment, but the *surface*
#      makes it impossible. → SOURCE_POLICY: an app's job decides whether a
#      commitment there is even plausible.
#   3. NOT THE USER'S. Third-person narration and other people's messages.
#      → first-person requirement for implied commitments.
#
# The lesson generalizes past this project: on screen text, *provenance* is a
# stronger precision signal than phrasing. Where a sentence appeared tells you
# more about whether it is a task than how it is worded.

# Apps whose text can plausibly contain a commitment the user made or received.
# Everything else needs an explicit "remind me" to get through at all.
CONVERSATIONAL = {
    "slack", "discord", "messages", "mail", "superhuman", "spark", "outlook",
    "telegram", "whatsapp", "signal", "linear", "notion", "asana", "jira",
    "github", "gmail", "teams", "zoom",
}
# Apps that are almost never a source of the user's own commitments.
NEVER_IMPLIED = {
    "spotify", "music", "vlc", "quicktime", "steam", "obs", "preview",
    "photos", "activity monitor", "system settings", "finder",
}

# The tool's own footprint — anything matching is self-capture, never a task.
SELF_REF = re.compile(
    r"(contextual[- ]remind|screen capture —|cr-ocr|candidates\.jsonl|"
    r"feedback\.jsonl|extract\.py|suggestions\.lua|⌃⌥⌘|hammerspoon|"
    r"\[(?:CARD|inbox|drop)\s*\]|score >= |wispr[- ]takehome)",
    re.I,
)

# Structural noise: timestamps, log lines, chat metadata, headings, code.
STRUCTURAL = re.compile(
    r"^(?:"
    r"\d{1,2}:\d{2}\s|"                    # 15:40 game clock / log time
    r"[•\-*]\s*\d{1,2}\s*(?:am|pm)\b|"     # • 2pm Gym  (calendar row)
    r"\d{1,2}:\d{2}\s?(?:AM|PM)\s+\w+\s+https?://|"  # chat timestamp + link
    r"#{1,6}\s|"                           # markdown heading
    r"\|.*\||"                             # table row
    r"(?:import|from|def|class|const|let|var|function|return|await)\s|"
    r"[A-Za-z_.]+\([^)]*\)\s*[;{]?$"       # bare function call
    r")",
    re.I,
)

# First-person markers — an implied commitment must be about the user.
FIRST_PERSON = re.compile(r"\b(i'?ll|i will|i'?m going to|i need to|i have to|i should|my |me\b)", re.I)
# Direct address — someone asking the user to do something.
SECOND_PERSON = re.compile(r"\b(can you|could you|would you|please|you need to|remind me)\b", re.I)


def source_policy(source: str) -> str:
    """How permissive should the gate be for text from this surface?

    full     — conversational app; implied commitments are plausible
    explicit — only literal "remind me"-style intent gets through
    none     — never a source of the user's tasks
    """
    s = (source or "").lower()
    app = s.split("—")[0].strip()
    if any(k in app for k in NEVER_IMPLIED):
        return "none"
    if any(k in s for k in CONVERSATIONAL):
        return "full"
    return "explicit"

COMMIT = re.compile(
    r"\b("
    r"remind me|don'?t forget|note to self|todo|to-do|action item|follow[ -]?up|"
    r"i'?ll |i will |i'?m going to|need to|needs to|have to|should |must |"
    r"can you |could you |please |waiting on|blocked on|circle back|"
    r"by (?:eod|eow|tomorrow|monday|tuesday|wednesday|thursday|friday|next week)|"
    r"due |deadline|before (?:the )?(?:meeting|call|standup|demo)"
    r")",
    re.I,
)
TEMPORAL = re.compile(
    r"\b(today|tonight|tomorrow|tmrw|monday|tuesday|wednesday|thursday|friday|"
    r"saturday|sunday|next week|this week|eod|eow|\d{1,2}\s?(?:am|pm)|"
    r"\d{1,2}:\d{2}|in \d+ (?:min|minutes|hours|days))\b",
    re.I,
)
# Lines that look like UI chrome, code, or navigation rather than prose.
NOISE = re.compile(
    r"^(?:[\W\d]{0,4}$|https?://\S+$|[A-Za-z_]+\([^)]*\)\s*[;{]?$|[{}\[\]();,]+$)"
)


EXPLICIT = re.compile(r"\b(remind me|note to self|don'?t forget|todo:|to-?do:)\b", re.I)


def gate(text: str, source: str = "") -> list[str]:
    """Return the lines worth spending an extractor call on.

    Source-aware: the same sentence is a task in Slack and noise in a game
    stream, so the surface decides how permissive to be.
    """
    policy = source_policy(source)
    if policy == "none":
        return []
    if SELF_REF.search(source or ""):
        return []

    keep = []
    for raw in text.splitlines():
        line = raw.strip()
        if len(line) < 15 or len(line) > 300:
            continue
        if NOISE.match(line) or STRUCTURAL.match(line) or SELF_REF.search(line):
            continue

        explicit = EXPLICIT.search(line)
        if explicit:
            keep.append(line)  # explicit intent always passes, any surface
            continue
        if policy != "full":
            continue  # non-conversational surface needs explicit intent
        # Implied commitment: must be phrased as the user's own obligation or
        # a direct ask of them, AND carry a commitment or temporal marker.
        if not (FIRST_PERSON.search(line) or SECOND_PERSON.search(line)):
            continue
        if COMMIT.search(line) or TEMPORAL.search(line):
            keep.append(line)
    return keep


# ------------------------------------------------------------ candidate -------


@dataclass
class Candidate:
    id: str
    action: str  # what to be reminded of
    kind: str  # commitment | request | deadline | task
    evidence: str  # the line it came from
    source: str  # app — window title
    app: str
    iso: str
    backend: str
    confidence: float  # extractor's own confidence, 0..1
    score: float = 0.0  # confidence adjusted by learned weights
    features: list[str] = field(default_factory=list)
    when: str | None = None  # temporal hint, verbatim, if any


def make_id(action: str) -> str:
    return "c" + hashlib.sha1(normalize(action).encode()).hexdigest()[:12]


def normalize(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", "", s.lower()).strip()


# ------------------------------------------------------------ extractors -----


def extract_rules(lines: list[str], entry: dict) -> list[Candidate]:
    """Deterministic extraction. No network. Replayable."""
    out = []
    for line in lines:
        kind = (
            "commitment"
            if re.search(r"\bi'?(?:ll|m going to)|i will\b", line, re.I)
            else "request"
            if re.search(r"\b(can you|could you|please)\b", line, re.I)
            else "deadline"
            if re.search(r"\b(due|deadline|by eod|by eow)\b", line, re.I)
            else "task"
        )
        when = TEMPORAL.search(line)
        # explicit "remind me" is the highest-confidence signal there is
        explicit = bool(re.search(r"\bremind me|note to self|todo\b", line, re.I))
        out.append(
            Candidate(
                id=make_id(line),
                action=line,
                kind=kind,
                evidence=line,
                source=entry.get("source", "?"),
                app=(entry.get("source") or "?").split("—")[0].strip(),
                iso=entry.get("iso", ""),
                backend="rules",
                confidence=0.9 if explicit else 0.45,
                when=when.group(0) if when else None,
            )
        )
    return out


EXTRACT_SCHEMA = {
    "type": "object",
    "properties": {
        "candidates": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "Imperative phrasing of what the user should be reminded to do.",
                    },
                    "kind": {
                        "type": "string",
                        "enum": ["commitment", "request", "deadline", "task"],
                    },
                    "evidence": {
                        "type": "string",
                        "description": "The exact source line this came from.",
                    },
                    "when": {
                        "type": ["string", "null"],
                        "description": "Temporal hint verbatim from the text, or null.",
                    },
                    "confidence": {"type": "number"},
                    "reasoning": {"type": "string"},
                },
                "required": [
                    "action",
                    "kind",
                    "evidence",
                    "when",
                    "confidence",
                    "reasoning",
                ],
                "additionalProperties": False,
            },
        }
    },
    "required": ["candidates"],
    "additionalProperties": False,
}

SYSTEM = """You extract actionable reminders from text that was OCR'd off a user's screen.

The text is noisy: UI chrome, other people's messages, code, half-rendered
elements. Precision matters far more than recall — a wrong reminder costs the
user's trust, a missed one costs nothing visible.

Only emit a candidate when ALL of these hold:
- It is something THIS user needs to do or follow up on (not someone else's task,
  not a task already completed, not a hypothetical or quoted example).
- It is actionable — a specific action, not a topic or a feeling.
- It is still open (not "I already sent it", not past tense).

Never emit: news headlines, marketing copy, documentation, code comments,
someone else's commitments, tasks the text says are already done, or generic
advice. When the subject of the obligation is ambiguous, do not emit.

confidence: 0.9+ only for explicit self-directed intent ("remind me to X",
"I'll send the deck by Friday"). 0.5-0.7 for implied obligations. Below 0.5 if
you are unsure the user is the one on the hook."""


def extract_claude(lines: list[str], entry: dict) -> list[Candidate]:
    import anthropic

    client = anthropic.Anthropic()
    numbered = "\n".join(f"{i+1}. {l}" for i, l in enumerate(lines))
    resp = client.messages.create(
        model=MODEL,
        max_tokens=4096,
        system=SYSTEM,
        output_config={"format": {"type": "json_schema", "schema": EXTRACT_SCHEMA}},
        messages=[
            {
                "role": "user",
                "content": (
                    f"Context: the user was in {entry.get('source','?')} at "
                    f"{entry.get('iso','?')}.\n\n"
                    f"Candidate lines from the screen:\n{numbered}\n\n"
                    "Extract reminders per your instructions."
                ),
            }
        ],
    )
    if resp.stop_reason == "refusal":
        return []
    text = next((b.text for b in resp.content if b.type == "text"), "{}")
    data = json.loads(text)
    out = []
    for c in data.get("candidates", []):
        out.append(
            Candidate(
                id=make_id(c["action"]),
                action=c["action"],
                kind=c["kind"],
                evidence=c.get("evidence", ""),
                source=entry.get("source", "?"),
                app=(entry.get("source") or "?").split("—")[0].strip(),
                iso=entry.get("iso", ""),
                backend="claude",
                confidence=float(c.get("confidence", 0.5)),
                when=c.get("when"),
            )
        )
    return out


def pick_backend(requested: str) -> str:
    if requested != "auto":
        return requested
    if os.environ.get("ANTHROPIC_API_KEY") or (
        Path.home() / ".config/anthropic/credentials"
    ).exists():
        return "claude"
    return "rules"


# ------------------------------------------------------------- LEARNING ------
# There is nothing to train a model on at t=0: no labels, no data, and the
# label that matters (did the user act on it?) only exists after we start
# shipping reminders. So instead of training a model, the system learns
# *thresholds* online from the only signal that is cheap, honest, and
# continuously available: what the user does with each card.
#
#   accept    → +1 for every feature of that candidate
#   dismiss   → -1
#   too_early → timing was wrong, content was right; no weight change
#
# Features are coarse and interpretable on purpose (app, kind, backend, hour
# bucket, explicit-vs-implied). Coarse features need few examples to become
# useful, and a weight you can read is a weight you can debug — which matters
# more than squeezing out accuracy at this scale.
#
# score = confidence * product(feature multipliers), where a feature's
# multiplier is a Laplace-smoothed accept rate. A feature the user has never
# accepted decays toward 0 and stops interrupting them. This is a contextual
# bandit's exploit half; the explore half is that medium-scored candidates
# still land in the passive inbox rather than being dropped.
#
# When there IS enough labelled data (hundreds of accept/dismiss pairs), the
# same feature vectors + labels become the training set for a real classifier,
# or few-shot examples for the extractor prompt. The feedback log is the
# dataset either way — that is the point of logging it in this shape.

PRIOR = 3.0  # smoothing: how many "neutral" observations each feature starts with


def featurize(c: Candidate) -> list[str]:
    hour = 0
    try:
        hour = datetime.fromisoformat(c.iso).hour
    except Exception:
        pass
    bucket = (
        "night" if hour < 6 else "morning" if hour < 12 else "afternoon" if hour < 18 else "evening"
    )
    feats = [
        f"app:{c.app[:24]}",
        f"kind:{c.kind}",
        f"backend:{c.backend}",
        f"time:{bucket}",
        f"explicit:{bool(re.search(r'remind me|note to self|todo', c.evidence, re.I))}",
        f"temporal:{c.when is not None}",
    ]
    return feats


def load_weights() -> dict:
    p = DATA / "weights.json"
    if p.exists():
        return json.loads(p.read_text())
    return {}


def score(c: Candidate, weights: dict) -> float:
    s = c.confidence
    for f in c.features:
        w = weights.get(f)
        if w:
            s *= w["multiplier"]
    return round(min(s, 1.0), 4)


def learn() -> dict:
    """Recompute feature multipliers from the feedback log."""
    counts: dict[str, dict] = {}
    fb_path = DATA / "feedback.jsonl"
    n = 0
    if fb_path.exists():
        for line in fb_path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                fb = json.loads(line)
            except json.JSONDecodeError:
                continue
            value = fb.get("value")
            if value not in ("accept", "dismiss"):
                continue  # too_early / snooze carry no content signal
            n += 1
            for f in fb.get("features", []):
                c = counts.setdefault(f, {"accept": 0, "dismiss": 0})
                c[value] += 1
    weights = {}
    for f, c in counts.items():
        total = c["accept"] + c["dismiss"]
        # Laplace-smoothed accept rate, centered so an unseen feature is neutral
        rate = (c["accept"] + PRIOR * 0.5) / (total + PRIOR)
        weights[f] = {
            "multiplier": round(0.4 + 1.2 * rate, 4),  # 0.4 .. 1.6
            "accept": c["accept"],
            "dismiss": c["dismiss"],
        }
    DATA.mkdir(exist_ok=True)
    (DATA / "weights.json").write_text(json.dumps(weights, indent=2, sort_keys=True))
    print(f"learned from {n} labelled events across {len(weights)} features")
    return weights


# ------------------------------------------------------------- pipeline ------

THRESH_FIRE = 0.55  # >= interrupt with a card
THRESH_INBOX = 0.30  # >= keep silently in the inbox; below this, drop


def state_path() -> Path:
    return DATA / "extract_state.json"


def load_state() -> dict:
    if state_path().exists():
        return json.loads(state_path().read_text())
    return {"cursor": {}, "seen": []}


def save_state(st: dict) -> None:
    DATA.mkdir(exist_ok=True)
    st["seen"] = st["seen"][-2000:]
    state_path().write_text(json.dumps(st))


def new_entries(state: dict) -> list[dict]:
    """OCR captures we haven't processed yet, oldest first."""
    out = []
    for path in sorted(glob.glob(str(LOGS / "ocr-*.jsonl"))):
        start = state["cursor"].get(os.path.basename(path), 0)
        with open(path) as f:
            lines = f.readlines()
        for line in lines[start:]:
            if line.strip():
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        state["cursor"][os.path.basename(path)] = len(lines)
    return out


def emit(cands: list[Candidate]) -> None:
    DATA.mkdir(exist_ok=True)
    with open(DATA / "candidates.jsonl", "a") as f:
        for c in cands:
            f.write(json.dumps(asdict(c)) + "\n")


def run_once(backend: str, verbose: bool = True) -> list[Candidate]:
    state = load_state()
    weights = load_weights()
    seen = set(state["seen"])
    entries = new_entries(state)
    extractor = extract_claude if backend == "claude" else extract_rules

    fired, gated_total, kept_lines = [], 0, 0
    for entry in entries:
        text = entry.get("text") or ""
        lines = gate(text, entry.get("source", ""))
        gated_total += len(text.splitlines())
        kept_lines += len(lines)
        if not lines:
            continue
        try:
            cands = extractor(lines, entry)
        except Exception as e:  # network/API failure must not lose the cursor
            print(f"  extractor error ({backend}): {e}", file=sys.stderr)
            continue
        for c in cands:
            if c.id in seen:
                continue  # same action already surfaced — the same text sits
                # on screen across many captures, so this is the common case
            c.features = featurize(c)
            c.score = score(c, weights)
            if c.score < THRESH_INBOX:
                continue
            seen.add(c.id)
            state["seen"].append(c.id)
            fired.append(c)

    if fired:
        emit(fired)
    save_state(state)

    if verbose:
        print(
            f"{len(entries)} captures · {gated_total} lines → {kept_lines} gated "
            f"({100*kept_lines/max(gated_total,1):.1f}%) → {len(fired)} candidates"
        )
        for c in fired:
            lane = "CARD " if c.score >= THRESH_FIRE else "inbox"
            print(f"  [{lane}] {c.score:.2f} {c.kind:<10} {c.action[:70]}")
    return fired


def stats() -> None:
    weights = load_weights()
    if not weights:
        print("no weights yet — run --learn after collecting feedback")
    else:
        print(f"{'feature':<34} {'mult':>6} {'✓':>4} {'✗':>4}")
        for f, w in sorted(weights.items(), key=lambda kv: -kv[1]["multiplier"]):
            print(f"{f:<34} {w['multiplier']:>6.2f} {w['accept']:>4} {w['dismiss']:>4}")
    fb = DATA / "feedback.jsonl"
    if fb.exists():
        vals: dict[str, int] = {}
        for line in fb.read_text().splitlines():
            if line.strip():
                try:
                    vals[json.loads(line).get("value", "?")] = (
                        vals.get(json.loads(line).get("value", "?"), 0) + 1
                    )
                except json.JSONDecodeError:
                    pass
        total = sum(vals.values())
        acc = vals.get("accept", 0)
        print(f"\nfeedback: {vals}")
        if total:
            print(f"precision (accept / all judged): {acc/total:.0%}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--test",
        metavar="TEXT",
        help="run the pipeline on literal text (or '-' for stdin) and print the "
        "lane each line would land in. Nothing is written.",
    )
    ap.add_argument("--source", help="simulate this source for --test, e.g. 'Slack — #team'")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--learn", action="store_true")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--backend", default="auto", choices=["auto", "rules", "claude"])
    args = ap.parse_args()

    if args.learn:
        learn()
        return
    if args.stats:
        stats()
        return
    if args.test is not None:
        text = sys.stdin.read() if args.test == "-" else args.test
        backend = pick_backend(args.backend)
        test_source = args.source or "test — Slack"
        lines = gate(text, test_source)
        total = len(text.splitlines())
        print(f"backend: {backend}")
        print(f"gate: {total} lines → {len(lines)} kept")
        if not lines:
            print("  (nothing survived the gate — no extractor call would be made)")
            return
        weights = load_weights()
        extractor = extract_claude if backend == "claude" else extract_rules
        cands = extractor(lines, {"source": test_source, "iso": datetime.now().isoformat()})
        if not cands:
            print("  (extractor found no candidates)")
            return
        for c in cands:
            c.features = featurize(c)
            c.score = score(c, weights)
            lane = (
                "CARD " if c.score >= THRESH_FIRE
                else "inbox" if c.score >= THRESH_INBOX
                else "drop "
            )
            print(f"  [{lane}] {c.score:.2f} {c.kind:<11} {c.action[:66]}")
        return

    backend = pick_backend(args.backend)
    print(f"backend: {backend}")
    if args.watch:
        while True:
            run_once(backend)
            time.sleep(args.interval)
    else:
        run_once(backend)


if __name__ == "__main__":
    main()
