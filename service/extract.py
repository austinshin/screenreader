#!/usr/bin/env python3
"""
extract.py — turn the OCR stream into reminder candidates, and learn which
signals are worth surfacing.

Pipeline per capture:

    OCR text ──▶ gate (cheap regex)  ──▶ extractor ──▶ dedupe ──▶ score ──▶ candidates.jsonl
                 drops ~everything       rules|claude   vs seen    learned      (Lua surfaces these)
                                                                  weights

Three extractor backends, same interface:

  rules   deterministic patterns; no API key, no network, fully replayable.
  claude  Claude API with structured output; catches phrasings no regex will.
  local   any Ollama model, on this machine. Closes the one hole in the privacy
          story — OCR and speech are already on-device, and this keeps screen
          text there too. Chosen automatically when Ollama is running. Model
          size is the whole decision: see LOCAL_MODEL below.

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

# The suggestion inbox rendered on screen: "💡 0.45 Sam Xu: …" (the bulb OCRs
# as P/D/o). A line opening with a bare two-decimal score is this app's own UI
# being read back — the purest form of self-capture.
SELF_UI_ROW = re.compile(r"^\s*\S{0,2}\s*[01]\.\d{2}\s+\S")

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

# ------------------------------------------------------- chat chrome ---------
# In a chat client every line carries a timestamp and a speaker. Both are
# chrome, not content — and the timestamp is actively harmful as a signal:
# because it appears on EVERY line it can't discriminate, yet the first version
# of this gate treated a bare clock time as evidence of a commitment. Result:
# "[10:47 AM] Link: so if like u were to tell me" survived on the strength of
# "10:47", while "[10:47 AM] Saujas: hey make sure to create a pull request"
# was dropped because "make sure" wasn't a known phrasing.
#
# Stripping chrome first fixes both, and buys a signal worth more than anything
# it removed: WHO SAID IT. The whole question a reminder gate has to answer is
# whose obligation this is, and the speaker answers it — the same words mean
# different things from different mouths:
#   "Saujas: make sure to open a PR"  → someone assigning the user work   KEEP
#   "Link:   I'll open a PR"          → the user committing               KEEP
#   "Megan:  I'll handle the deploy"  → somebody else's task              DROP
#   "Link:   can you review my PR?"   → the user assigning someone else   DROP
# Stripping the timestamp also stabilizes dedupe: the same line re-read a
# minute later used to differ by its clock and read as a brand-new candidate.

LEADING_TS = re.compile(r"^\[?\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:[AaPp]\.?[Mm]\.?)?\s*\]?[\s\-—]*")
TRAILING_TS = re.compile(
    r"[\s\-—]*(?:today|yesterday|tomorrow)?[\s,]*(?:at\s+)?"
    r"\d{1,2}:\d{2}\s*(?:[AaPp]\.?[Mm]\.?)?\s*$", re.I)
# Display names carry spaces ("Sam Xu", "Austin Shin"). Missing that was not a
# cosmetic bug: an unparsed speaker defaults to "the user", so every "I'm going
# to …" anyone else typed was read as the user's own commitment.
SPEAKER = re.compile(
    r"^(?P<name>[A-Za-z][\w.\-]{0,23}(?:\s+[A-Za-z][\w.\-]{0,15}){0,2})\s*:\s+")
BARE_TOKEN = re.compile(r"^[A-Za-z][\w.\-]*$")  # a lone name left after stripping

# Who the user is, so first-person lines can be attributed. Override with
# CR_USER_ALIASES="link,austin,ashin" if the chat handle differs.
USER_ALIASES = {
    a.strip().lower()
    for a in os.environ.get("CR_USER_ALIASES", "link,austin,shinaustin,me").split(",")
    if a.strip()
}

# The user's own stated obligation. Narrower than FIRST_PERSON on purpose:
# "can you review my PR" is first-person but is the user assigning someone
# ELSE work, which is not a reminder for the user.
SELF_COMMIT = re.compile(
    r"\b(i'?ll|i will|i'?m going to|i'?m gonna|i need to|i have to|i've got to|"
    r"i gotta|i should|i must|let me|i'?m supposed to)\b", re.I)

# Someone directing the user to do something. Covers the natural phrasings the
# first version missed entirely — "make sure", "don't forget", "when you get a
# chance" — and chat spellings of "you".
DIRECTIVE = re.compile(
    r"\b(can|could|would|will) (you|u|ya)\b|\bplease\b|\bmake sure\b|"
    r"\bdon'?t forget\b|\bremember to\b|\bwhen (you|u) (get|have|can)\b|"
    r"\b(you|u) (should|need to|have to|gotta|might want to)\b|"
    r"\bmind \w+ing\b|\bwanna \w+\b|\bhave (you|u) \w+ed\b", re.I)


def split_chat_line(line: str) -> tuple[str | None, str]:
    """"[10:45 AM] Link: yea" → ("Link", "yea"). Chrome off, speaker out."""
    s = LEADING_TS.sub("", line.strip())
    speaker = None
    m = SPEAKER.match(s)
    if m:
        speaker = m.group("name")
        s = s[m.end():]
    s = TRAILING_TS.sub("", s)
    return speaker, s.strip()


def is_metadata(text: str) -> bool:
    """What's left is a bare name or nothing — a header row, not a message."""
    return not text or bool(BARE_TOKEN.match(text))


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

# Text *about* reminders is not a reminder. Documentation, specs, and this
# project's own notes quote "remind me to X" constantly — and the explicit
# bypass below originally ignored provenance entirely, so every one of those
# quotes scored 0.90 and carded. On a full-corpus run that single hole
# accounted for essentially all of the LLM backend's output.
#
# The tell is always the same: an *instance* of intent is stated plainly,
# whereas a *mention* of intent is quoted, templated, or bulleted.
MENTION = re.compile(
    r"""(
      ["“”'].{0,40}\bremind\ me|      # "remind me …"  — quoted example
      \bremind\ me\b.{0,40}["“”']|    # … remind me …" — closing quote
      <[a-z_ ]+>|                     # <feature> <topic> <channel> placeholders
      ^\s*[•\-*]\s*["“”']|            # bulleted quotation
      \b(?:e\.g\.|for\ example|such\ as|like\ this|instead\ of)\b|
      \b(?:strings?|literal|pattern|regex|keyword|phrase)\b
    )""",
    re.I | re.X,
)


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
        if len(line) > 300 or SELF_REF.search(line) or SELF_UI_ROW.match(line):
            continue
        if NOISE.match(line) or STRUCTURAL.match(line):
            continue

        # Chrome off before anything is judged, so a timestamp can never be the
        # reason a line survives and the speaker becomes available as evidence.
        speaker, body = split_chat_line(line)
        if is_metadata(body) or len(body) < 12:
            continue
        if NOISE.match(body) or STRUCTURAL.match(body) or MENTION.search(body):
            continue

        # What the extractor sees: content, attributed. Keeping the speaker
        # tells the LLM whose obligation it is; dropping the clock keeps the
        # same sentence stable across re-reads for dedupe.
        cleaned = f"{speaker}: {body}" if speaker else body

        # Checked against the raw line too: "note to self: …" parses as a
        # speaker named "note to self", which would strip the very phrase that
        # makes it explicit.
        if EXPLICIT.search(body) or EXPLICIT.search(line):
            keep.append(cleaned)  # a plain statement of intent passes anywhere
            continue
        if policy != "full":
            continue  # non-conversational surface needs explicit intent

        # Whose task is it? The speaker decides which test applies.
        from_someone_else = speaker is not None and speaker.lower() not in USER_ALIASES
        if from_someone_else:
            # Only an instruction aimed at the user counts. Their own
            # commitments ("I'll handle the deploy") are not the user's task.
            if DIRECTIVE.search(body):
                keep.append(cleaned)
        else:
            # The user, or an unattributed surface (their email, their notes):
            # their own stated obligations count.
            if SELF_COMMIT.search(body) or (DIRECTIVE.search(body) and EXPLICIT.search(body)):
                keep.append(cleaned)
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


def normalize(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", "", s.lower()).strip()


def make_id(action: str, evidence: str = "") -> str:
    """Identity for dedupe.

    Keyed on the *evidence* (the verbatim source line) rather than the
    generated action. This matters more than it looks: an LLM paraphrases the
    same task differently on every pass — "Create the day 1 updates video and
    send it to Shin" / "Create and send the day 1 updates video" / "Record one
    or two more update videos" were all one email, read across 30 captures.
    Hashing the action let every rephrasing through as a "new" candidate.
    The source line is stable, so hashing it collapses them.
    """
    basis = normalize(evidence) or normalize(action)
    return "c" + hashlib.sha1(basis.encode()).hexdigest()[:12]


STOP = {
    "the", "a", "an", "and", "or", "to", "for", "of", "in", "on", "at", "by",
    "with", "your", "you", "it", "this", "that", "then", "once", "after",
    "before", "is", "are", "be", "will", "send", "create", "make", "get",
}


def _stem(w: str) -> str:
    """Crude plural strip. "update"/"updates" and "video"/"videos" are the same
    task; a real stemmer is not worth a dependency for this."""
    return w[:-1] if len(w) > 3 and w.endswith("s") and not w.endswith("ss") else w


def action_key(action: str) -> frozenset:
    """Content words, for catching paraphrases the evidence hash misses.

    OCR is not stable either: the same line re-read can differ by a character
    ("GitHub paad's"), which changes the evidence hash. Comparing content-word
    sets survives both LLM rephrasing and OCR jitter.
    """
    words = [_stem(w) for w in normalize(action).split()
             if w not in STOP and len(w) > 2]
    return frozenset(words)


def too_similar(key: frozenset, seen_keys: list[frozenset],
                thresh: float = 0.6, containment: float = 0.75) -> bool:
    """Overlap against everything already surfaced.

    Two tests, because the duplicates come in two shapes. Jaccard catches
    rewordings of similar length. Containment catches the case Jaccard misses:
    one phrasing is a subset of a longer one ("send update videos" inside
    "send one or two more update videos") — same task, but the extra words
    push union up and Jaccard down.
    """
    if not key:
        return False
    for other in seen_keys:
        if not other:
            continue
        inter = len(key & other)
        if inter / len(key | other) >= thresh:
            return True
        if inter / min(len(key), len(other)) >= containment:
            return True
    return False


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
                id=make_id(line, line),
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
                id=make_id(c["action"], c.get("evidence", "")),
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


# ------------------------------------------------------------ local model ----
# The privacy story has one hole. OCR is on-device (Apple Vision), speech is
# on-device (hear -d), and then the surviving lines are posted to an API. For a
# tool whose whole premise is reading your screen, closing that is worth real
# quality: the gate already drops ~99.8% of lines, so a local model is only
# asked to judge the ~100 that survive a day, not the 45,000 that don't.
#
# Talks to Ollama over plain HTTP rather than importing a client, so the
# service keeps its single dependency. Any instruct model works — 3B is enough
# because the gate has already answered "is this plausibly a task", leaving
# only "is it *this user's* task", which is a much smaller question.

# MODEL SIZE IS THE WHOLE DECISION, and it is a throughput problem, not a
# quality one. Watch mode captures every ~20s, so extraction has to finish in
# well under that or the queue grows without bound and never recovers.
#
# Measured on this machine (M1 Pro, 16GB): gemma4 at 9.6GB took **140 seconds**
# for a 200-token reply and returned empty content — the weights barely fit
# alongside everything else, so it thrashes. A 3B model (~2GB) is the right
# class here and lands in low single-digit seconds.
#
# That is affordable because the gate has already done the hard filtering: a
# day of screen text is ~45,000 lines and ~100 reach the extractor. The model
# is not asked "is this plausibly a task" — regex answered that — only "is it
# *this user's* task", which is a much smaller question and one a small
# instruct model can hold.
OLLAMA_URL = os.environ.get("CR_OLLAMA_URL", "http://localhost:11434")
LOCAL_MODEL = os.environ.get("CR_LOCAL_MODEL", "llama3.2:3b")
LOCAL_TIMEOUT = float(os.environ.get("CR_LOCAL_TIMEOUT", "45"))
LOCAL_SLOW_MS = 15000  # past this, the model is too big to keep up with capture


def ollama_available() -> str | None:
    """The model to use, or None. Prefers CR_LOCAL_MODEL; falls back to any
    installed model so a machine with *something* pulled still works.

    The 1.5s budget is deliberately a liveness check, not just discovery. An
    oversized model doesn't merely answer slowly — it wedges the whole server
    while it thrashes, and /api/tags stops responding too. If the daemon can't
    say what it has within a second and a half, it certainly can't extract
    before the next capture, so treating that as "not available" and falling
    back is correct rather than pessimistic.
    """
    import urllib.request
    try:
        with urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=1.5) as r:
            names = [m["name"] for m in json.load(r).get("models", [])]
    except Exception:
        return None
    if not names:
        return None
    for n in names:                      # exact, then prefix (":latest" tags)
        if n == LOCAL_MODEL:
            return n
    for n in names:
        if n.split(":")[0] == LOCAL_MODEL.split(":")[0]:
            return n
    return names[0]


def extract_local(lines: list[str], entry: dict) -> list[Candidate]:
    """Same contract as extract_claude, run on this machine."""
    import urllib.request
    model = ollama_available()
    if not model:
        return []
    numbered = "\n".join(f"{i+1}. {l}" for i, l in enumerate(lines))
    body = json.dumps({
        "model": model,
        "stream": False,
        # Ollama takes a JSON schema here and constrains decoding to it, which
        # matters far more for a small model than a large one: without it they
        # narrate, apologise, and wrap JSON in prose.
        "format": EXTRACT_SCHEMA,
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content":
                f"Context: the user was in {entry.get('source','?')} at "
                f"{entry.get('iso','?')}.\n\nCandidate lines from the screen:\n"
                f"{numbered}\n\nExtract reminders per your instructions."},
        ],
    }).encode()
    req = urllib.request.Request(f"{OLLAMA_URL}/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=LOCAL_TIMEOUT) as r:
            payload = json.load(r)
        content = payload["message"]["content"]
        data = json.loads(content)
    except Exception as e:
        took = time.time() - t0
        print(f"  local model ({model}) failed after {took:.0f}s: {e}", file=sys.stderr)
        if took >= LOCAL_TIMEOUT - 1:
            # Say the useful thing rather than the literal one: a timeout here
            # almost always means the model is too large for this machine, not
            # that anything is broken.
            print(f"  → {model} is too slow to keep up with capture. Try a ~3B "
                  f"model: ollama pull llama3.2:3b", file=sys.stderr)
        return []
    took_ms = (time.time() - t0) * 1000
    if took_ms > LOCAL_SLOW_MS:
        print(f"  note: {model} took {took_ms/1000:.0f}s — captures arrive every "
              f"~20s, so a smaller model will keep up better", file=sys.stderr)
    if not str(content).strip():
        print(f"  note: {model} returned nothing; small models need the schema "
              f"and a short prompt to stay on task", file=sys.stderr)
        return []

    out = []
    for c in data.get("candidates", []):
        if not isinstance(c, dict) or not c.get("action"):
            continue
        try:
            conf = float(c.get("confidence", 0.5))
        except (TypeError, ValueError):
            conf = 0.5
        out.append(
            Candidate(
                id=make_id(c["action"], c.get("evidence", "")),
                action=str(c["action"])[:200],
                kind=c.get("kind") if c.get("kind") in
                     ("commitment", "request", "deadline", "task") else "task",
                evidence=str(c.get("evidence", ""))[:300],
                source=entry.get("source", "?"),
                app=(entry.get("source") or "?").split("—")[0].strip(),
                iso=entry.get("iso", ""),
                backend="local",
                confidence=max(0.0, min(1.0, conf)),
                when=c.get("when") if isinstance(c.get("when"), str) else None,
            )
        )
    return out


def pick_backend(requested: str) -> str:
    if requested != "auto":
        return requested
    # Local first when it's there: same job, nothing leaves the machine.
    if ollama_available():
        return "local"
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
    """confidence, adjusted by the *average* learned signal.

    Geometric mean, not a raw product. Multiplying six sub-1.0 multipliers
    compounds: a 0.7-confidence candidate carrying six mildly-disliked
    features scored 0.10 and nothing ever surfaced again — the learning layer
    silently became an off switch. Averaging keeps the total adjustment inside
    one feature's range (~0.4x–1.6x), so a feature votes rather than vetoes,
    and adding more feature types can't change the scale.
    """
    mults = [weights[f]["multiplier"] for f in c.features if f in weights]
    if not mults:
        return round(min(c.confidence, 1.0), 4)
    product = 1.0
    for m in mults:
        product *= m
    adjustment = product ** (1.0 / len(mults))
    return round(min(c.confidence * adjustment, 1.0), 4)


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
    _write_atomic(DATA / "weights.json", json.dumps(weights, indent=2, sort_keys=True))
    print(f"learned from {n} labelled events across {len(weights)} features")
    return weights


EXTRACTORS = {"rules": extract_rules, "claude": extract_claude, "local": extract_local}


# ------------------------------------------------------------- pipeline ------

THRESH_FIRE = 0.55  # >= interrupt with a card
THRESH_INBOX = 0.50  # >= keep silently in the inbox; below this, drop
# 0.50, not 0.30: below half-confidence the extractor is guessing at whether
# the user is even the one on the hook. Those cost more to read than they save.


def _write_atomic(path: Path, text: str) -> None:
    """Write-then-rename so a concurrent reader never sees a half-written file
    (the dashboard reads weights.json; a torn extract_state.json would reset
    the cursor and replay a day of captures)."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def state_path() -> Path:
    return DATA / "extract_state.json"


def load_state() -> dict:
    if state_path().exists():
        return json.loads(state_path().read_text())
    return {"cursor": {}, "seen": [], "keys": []}


def save_state(st: dict) -> None:
    DATA.mkdir(exist_ok=True)
    st["seen"] = st["seen"][-2000:]
    st["keys"] = st.get("keys", [])[-400:]
    _write_atomic(state_path(), json.dumps(st))


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
    seen_keys = [frozenset(k) for k in state.get("keys", [])]
    entries = new_entries(state)
    extractor = EXTRACTORS.get(backend, extract_rules)

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
            key = action_key(c.action)
            if too_similar(key, seen_keys):
                continue  # a rephrasing of something already surfaced
            seen_keys.append(key)
            state.setdefault("keys", []).append(sorted(key))
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
    ap.add_argument("--backend", default="auto",
                    choices=["auto", "rules", "claude", "local"])
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
        extractor = EXTRACTORS.get(backend, extract_rules)
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
