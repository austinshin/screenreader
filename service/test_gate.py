#!/usr/bin/env python3
"""
test_gate.py — labeled eval for the gate.

The gate is the cost control and the precision control: it decides which screen
lines are worth an extractor call. Changing it by feel is how you trade one
false-positive class for another without noticing. This is the harness that
makes a change provable — every case is a line the system will really see,
labeled with whether it deserves to survive.

    python3 service/test_gate.py          # score the gate, list failures
    python3 service/test_gate.py -v       # list every case

Cases are (source, line, should_keep). Chat lines carry their real chrome —
"[10:45 AM] Link: yea" — because stripping that chrome correctly is exactly
what's under test.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extract import gate  # noqa: E402

CHAT = "Discord — #general"
SLACK = "Slack — #eng"
BROWSER = "Google Chrome — Gmail"
GAME = "Steam — Dota 2"
EDITOR = "Zed — extract.py"
NOTES = "Zed — notes.md"

# (source, line, should_keep)
CASES: list[tuple[str, str, bool]] = [
    # --- chat chrome must never be the reason a line survives ---------------
    (CHAT, "[10:45 AM] Link: yea", False),
    (CHAT, "[10:45 AM] Link: lol", False),
    (CHAT, "[10:47 AM] Link: so if like u were to tell me", False),
    (CHAT, "[11:02 AM] Link: lol that meeting was at 3pm yesterday", False),
    (CHAT, "Saujas — Today at 2:14 PM", False),
    (CHAT, "[9:15 AM] Saujas: morning", False),
    (SLACK, "10:45 AM", False),
    (SLACK, "Link  2:14 PM", False),

    # --- someone directing the user: the class we most want ----------------
    (CHAT, "[10:47 AM] Saujas: hey make sure to create a pull request for ur work later", True),
    (CHAT, "[10:48 AM] Saujas: don't forget to send the demo video tonight", True),
    (CHAT, "[10:49 AM] Saujas: can you review the PR before EOD tomorrow?", True),
    (SLACK, "[3:02 PM] Megan: remember to book the room for standup", True),
    (SLACK, "[3:05 PM] Megan: when you get a chance, could you update the doc?", True),
    (CHAT, "[4:00 PM] Saujas: please push the branch when you're done", True),

    # --- the user committing --------------------------------------------------
    (CHAT, "[10:50 AM] Link: I'll send the deck by Friday", True),
    (SLACK, "[10:51 AM] Link: i need to fix the OCR gate today", True),
    (BROWSER, "I'll follow up with the vendor by EOD", True),

    # --- chatter that merely mentions time or work ---------------------------
    (CHAT, "[10:52 AM] Link: that PR was huge lol", False),
    (CHAT, "[10:53 AM] Saujas: the meeting is at 3pm", False),  # info, not a task for me
    (CHAT, "[10:54 AM] Link: thanks!", False),
    (SLACK, "[10:55 AM] Megan: I'll handle the deploy", False),  # someone else's task

    # --- wrong surface entirely ---------------------------------------------
    (GAME, "[15:40] Radiant: I'll take mid", False),
    (EDITOR, "    # TODO: remember to strip chat chrome", False),  # code, not a commitment
    (EDITOR, "def gate(text: str, source: str = '') -> list[str]:", False),

    # --- explicit intent survives anywhere ----------------------------------
    (BROWSER, "remind me to water the plants tonight", True),
    (NOTES, "note to self: rotate the API key before the demo", True),
]


def main() -> None:
    verbose = "-v" in sys.argv
    tp = fp = tn = fn = 0
    failures = []

    for source, line, want in CASES:
        got = bool(gate(line, source))
        ok = got == want
        if want and got:
            tp += 1
        elif want and not got:
            fn += 1
        elif not want and got:
            fp += 1
        else:
            tn += 1
        if not ok:
            failures.append((source, line, want, got))
        if verbose:
            mark = "✓" if ok else "✗"
            print(f"  {mark} keep={got!s:<5} want={want!s:<5} {line[:62]}")

    total = len(CASES)
    prec = tp / (tp + fp) if (tp + fp) else 1.0
    rec = tp / (tp + fn) if (tp + fn) else 1.0
    f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0

    if failures:
        print("\nfailures:")
        for source, line, want, got in failures:
            kind = "false positive (noise let through)" if got else "false negative (real ask dropped)"
            print(f"  {kind}\n    [{source}] {line}")

    print(
        f"\n{tp + tn}/{total} correct · "
        f"precision {prec:.0%} · recall {rec:.0%} · F1 {f1:.2f} "
        f"({fp} let through, {fn} dropped)"
    )
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
