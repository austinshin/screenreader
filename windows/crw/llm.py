"""Optional local-LLM transcript polish — the layer between whisper and the
deterministic parsers.

Whisper is already local and already good; what it gets wrong is the speech
itself: homophones ("by milk"), spelled-out clock times ("at one thirty")
that timeparse's patterns can't see, misheard names. This module hands the
raw transcript to a small local model with one job: repair those, change
nothing else.

The deterministic parsers stay the authority — this is the "LLM earns its
way in only where determinism runs out" rule from the original matcher, and
speech artifacts are exactly where it runs out. Three design consequences:

  * Ollama over plain HTTP (urllib), no client dependency — the same
    decision service/extract.py made, for the same reason: the core stays
    on the standard library, and a missing Ollama disables this feature
    with a logged reason, nothing else.
  * The model may REPAIR, never REWRITE. Two guards enforce it: the output
    must share most of its content words with what was heard, and may
    introduce almost none of its own. A polish that fails either guard is
    logged and discarded — hallucinating "tomorrow morning" onto a reminder
    would be worse than any mishearing.
  * Failure of any kind returns the input unchanged. A reminder must never
    be lost, delayed past the timeout, or mangled because the polisher had
    a bad day.

Auto-detected: on when Ollama answers at CR_OLLAMA_URL, off otherwise,
re-checked every minute — installing Ollama mid-session just starts working.
"""

from __future__ import annotations

import json
import re
import time
import urllib.request

from . import config, eventlog

_avail_cache = {"at": 0.0, "model": None}

_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}

# One narrow job, stated narrowly — small instruct models follow the fence
# they can see, and every sentence here is a fence. The examples matter more
# than the rules for a 3B model: without them the first live run dropped
# "hear" (misheard "here") instead of repairing it, and "here"/"this" are
# the words the condition parser binds on — the least droppable words in
# the sentence.
_SYSTEM = (
    "You repair the output of a speech-to-text system. The input is one "
    "short spoken reminder. Fix obvious transcription errors only: misheard "
    "words, homophones, and spelled-out clock times. Keep every word — "
    "especially place and time words like 'here', 'this', 'today'. Never "
    "add, drop, or reorder information. Never answer, expand, or complete "
    "the reminder. If the input already reads correctly, return it "
    "unchanged.\n\n"
    "Examples:\n"
    "  'by milk at one thirty' -> 'buy milk at 1:30'\n"
    "  'reply to sarah when im done hear' -> 'reply to Sarah when I'm done here'\n"
    "  'send it at five pm august first' -> 'send it at 5pm august 1'\n"
    "  'water the plants' -> 'water the plants'"
)


def available() -> str | None:
    """The model to use, or None. Cached for a minute — one liveness probe
    per utterance would double the latency it exists to justify.

    The 1.5s budget is a liveness check, not just discovery (extract.py's
    lesson): a daemon too overloaded to list its models is certainly too
    overloaded to polish before the user looks away.
    """
    now = time.monotonic()
    if now - _avail_cache["at"] < 60:
        return _avail_cache["model"]
    model = None
    if config.LLM.get("enabled", True):
        try:
            with urllib.request.urlopen(f"{config.LLM['url']}/api/tags",
                                        timeout=1.5) as r:
                names = [m["name"] for m in json.load(r).get("models", [])]
            want = config.LLM["model"]
            model = next((n for n in names if n == want), None) \
                or next((n for n in names
                         if n.split(":")[0] == want.split(":")[0]), None) \
                or (names[0] if names else None)
        except Exception:
            model = None
    _avail_cache.update(at=now, model=model)
    return model


def _sig(s: str) -> set:
    """Content words, for comparing what was heard against what came back."""
    return {w for w in re.findall(r"[a-z']+", s.lower()) if len(w) > 2}


def _acceptable(raw: str, out: str):
    """May this output replace the transcript? Repair yes, rewrite no."""
    if len(out) > 2 * len(raw) + 20:
        return False, "grew far beyond the utterance"
    r, p = _sig(raw), _sig(out)
    if r and p:
        if len(r & p) / min(len(r), len(p)) < 0.5:
            return False, "shares too little with what was heard"
        # normalizing "one thirty" → "1:30" *removes* words, which is fine;
        # what a repair may not do is bring words of its own
        if len(p - r) > max(1, len(p) // 3):
            return False, "introduced words that were never said"
    return True, None


def _chat(model: str, text: str) -> str:
    """One Ollama round trip. Separated so tests can stub the transport."""
    body = json.dumps({
        "model": model,
        "stream": False,
        # schema-constrained decoding matters far more for a small model
        # than a large one: without it they narrate and apologise
        "format": _SCHEMA,
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": _SYSTEM},
            {"role": "user", "content": text},
        ],
    }).encode()
    req = urllib.request.Request(f"{config.LLM['url']}/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=config.LLM["timeout"]) as r:
        payload = json.load(r)
    return json.loads(payload["message"]["content"]).get("text", "")


def polish(text: str):
    """raw transcript → (text, meta | None). meta is set only when the
    transcript actually changed: {model, ms, raw} — the decision log needs
    the before, the after, and who did it."""
    model = available()
    if not model:
        return text, None
    t0 = time.time()
    try:
        out = (_chat(model, text) or "").strip().strip('"')
    except Exception as e:
        eventlog.append({"event": "llm.polish_failed", "model": model,
                         "error": str(e)[:200]})
        return text, None
    ms = int((time.time() - t0) * 1000)
    if not out or out.lower() == text.lower():
        return text, None
    ok, reason = _acceptable(text, out)
    if not ok:
        # the rejection is evidence, not noise: it is how a bad model or a
        # bad prompt gets noticed instead of quietly rewording reminders
        eventlog.append({"event": "llm.polish_rejected", "model": model,
                         "reason": reason, "raw": text[:200], "out": out[:200]})
        return text, None
    eventlog.append({"event": "llm.polished", "model": model, "ms": ms,
                     "raw": text[:200], "text": out[:200]})
    return out, {"model": model, "ms": ms, "raw": text}
