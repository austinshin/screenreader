"""Split "what to remind me" from "when to surface it" — port of
cr/condition.lua.

    "remind me to look into embeddings after I finish watching this video"
    "once I'm done testing the gate, remind me to share progress in #eng"

The tail is a *condition*, not part of the task. Left in, it becomes the text
on the card — telling you something you can already see, in place of the
thing you actually wanted to remember. What the condition names is almost
always the thing already on screen, which is what the reminder binds to
anyway; the phrase is kept verbatim so the decision log can show the sentence
next to the window it resolved to.

The Lua original needed one pattern per phrasing (no alternation in Lua
patterns); Python regex collapses each family to a single expression. The
tests lock the same accepted phrasings.
"""

from __future__ import annotations

import re

# "i'm" / "i am" / "im" / "i"
_IM = r"i(?:'m|m|\s+am)?"

_LEADING = re.compile(
    rf"^(?:"
    rf"(?:once|after|when)\s+(?:{_IM}\s+done|i\s+finish|i\s+wrap\s+up)"
    rf"|(?:after|when)\s+this"
    rf")[^,]*,\s*",
    re.I,
)

_TRAILING = re.compile(
    rf"\s+(?:"
    rf"(?:once|after|when)\s+(?:{_IM}\s+done|i\s+finish|i\s+wrap\s+up|i\s+close)"
    rf"|(?:once|after|when)\s+this"
    rf"|after\s+{_IM}\s+out\s+of"
    rf")\s.*$",
    re.I,
)


def extract(text: str):
    """text → (clean_text, condition_phrase | None)"""
    m = _LEADING.search(text)
    if m:
        phrase = text[m.start():m.end()].rstrip(" ,")
        rest = text[m.end():]
        if len(rest) >= 3:
            return rest, phrase
    m = _TRAILING.search(text)
    if m:
        phrase = text[m.start():m.end()].lstrip()
        rest = text[:m.start()].rstrip(" ,")
        if len(rest) >= 3:
            return rest, phrase
    return text, None
