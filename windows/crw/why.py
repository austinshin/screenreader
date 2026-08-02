"""The decision log, in English — port of cr/why.lua.

events-*.jsonl records *what* happened; this records *why*, in the words a
person would use. A tool that acts on its own reading of your screen has to be
able to answer "why did you do that?" without state-transition archaeology.
"""

from __future__ import annotations

import time

from . import config, eventlog


def _path():
    return config.logs_dir() / time.strftime("decisions-%Y-%m-%d.md")


def note(kind: str, subject: str, reasons: list) -> None:
    """reasons: list of (label, detail) pairs; falsy details are skipped."""
    try:
        p = _path()
        new = not p.exists() or p.stat().st_size == 0
        with open(p, "a", encoding="utf-8") as f:
            if new:
                f.write(f"# Decisions — {time.strftime('%A, %B %d %Y')}\n\n"
                        "Why the system did what it did. Written as it happens; "
                        "`events-*.jsonl` has the machine-readable version.\n\n")
            clock = time.strftime("%I:%M %p").lstrip("0")
            f.write(f"## {clock} · {kind}\n**{subject or '?'}**\n\n")
            for r in reasons or []:
                if r and r[1]:
                    f.write(f"- **{r[0]}:** {r[1]}\n")
            f.write("\n")
    except OSError as e:
        # never let explaining a decision break the decision
        eventlog.append({"event": "why.error", "error": str(e)})
