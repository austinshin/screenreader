"""How loudly a reminder is allowed to speak — port of cr/tier.lua.

    1 critical   stop what you're doing
    2 upcoming   a commitment approaching
    3 in-context relevant because of what's on screen right now
    4 ambient    background awareness, never interrupts

Tier is a property of the reminder *right now*: trigger.retier re-evaluates
it as context moves, inside two hard limits — ambient is never promoted
("never interrupts" has to mean never), and critical is only ever assigned
here, from stated consequence; the clock alone caps out at upcoming.
1 and 4 are never defaults: ambient is too quiet for something you asked to
be reminded of, critical too loud to assign without evidence.
"""

from __future__ import annotations

import re

CRITICAL, UPCOMING, INCONTEXT, AMBIENT = 1, 2, 3, 4

NAME = {1: "critical", 2: "upcoming", 3: "in context", 4: "ambient"}

LABEL = {
    1: {"name": "Critical", "note": "interrupts you as soon as it fires"},
    2: {"name": "Upcoming", "note": "waits for a natural break"},
    3: {"name": "In context", "note": "waits until you're done with the thing"},
    4: {"name": "Ambient", "note": "never interrupts — dashboard and glance only"},
}

# (pattern, tier, why). Across entries the strongest (lowest) match wins, so
# an urgent phrase beats an informational one in the same sentence.
SIGNALS = [
    # consequence: something is lost if this is missed
    (r"\bor i'?ll miss\b", 1, "you said it has a consequence you'd miss"),
    (r"\bbefore it closes\b", 1, "you said something closes"),
    (r"\bbefore they close\b", 1, "you said something closes"),
    (r"\bdeadline\b", 1, 'you said "deadline"'),
    (r"\bexpires?\b", 1, "you said something expires"),
    (r"\blast chance\b", 1, 'you said "last chance"'),
    # explicit urgency
    (r"\burgent\b", 1, 'you said "urgent"'),
    (r"\basap\b", 1, 'you said "asap"'),
    (r"\bcritical\b", 1, 'you said "critical"'),
    (r"\bemergency\b", 1, 'you said "emergency"'),
    (r"\bright away\b", 1, 'you said "right away"'),
    (r"\bdon'?t forget\b", 2, 'you said "don\'t forget"'),
    (r"\bmake sure\b", 2, 'you said "make sure"'),
    (r"\bimportant\b", 2, 'you said "important"'),
    # a commitment made to a person
    (r"\btell\b", 2, "it's something you owe a person"),
    (r"\breply\b", 2, "it's something you owe a person"),
    (r"\brespond\b", 2, "it's something you owe a person"),
    (r"\bget back to\b", 2, "it's something you owe a person"),
    (r"\bfollow up\b", 2, "it's a follow-up you promised"),
    (r"\bsend\b", 2, "you promised to send something"),
    # informational: worth knowing, not worth interrupting for
    (r"\bkeep an eye on\b", 4, 'you said "keep an eye on" — that\'s watching, not doing'),
    (r"\bkeep track of\b", 4, "it's something to track, not act on"),
    (r"\bfyi\b", 4, 'you said "fyi"'),
    (r"\bnote that\b", 4, "you're noting something, not tasking yourself"),
    (r"\bat some point\b", 4, 'you said "at some point"'),
    (r"\beventually\b", 4, 'you said "eventually"'),
    (r"\bno rush\b", 4, 'you said "no rush"'),
    (r"\bwhenever\b", 4, 'you said "whenever"'),
]

_COMPILED = [(re.compile(p, re.I), t, w) for p, t, w in SIGNALS]


def classify(text: str, bound: bool):
    """(text, has_screen_binding) → (tier, why)"""
    best, why = None, None
    for pat, t, w in _COMPILED:
        if pat.search(text or "") and (best is None or t < best):
            best, why = t, w
    # A screen binding outranks a tier-2 word: "reply to this thread" contains
    # "reply", but the binding already says *when* it's relevant. Only genuine
    # urgency (up) or an explicitly informational phrase (down) overrides it.
    if bound:
        if best in (CRITICAL, AMBIENT):
            return best, why
        return INCONTEXT, "it's tied to what was on your screen"
    if best is not None:
        return best, why
    return UPCOMING, "no urgency or context signal — treated as an ordinary commitment"


def bypasses_seam_gate(t) -> bool:
    """Critical is the only tier allowed past the seam gate — the promise that
    makes this tolerable to leave running all day."""
    return t == CRITICAL
