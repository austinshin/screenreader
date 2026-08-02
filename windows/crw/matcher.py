"""Referent binding + presence predicate — port of cr/matcher.lua.

Deictic-only and deliberately LLM-free: a referent is "whatever was on screen
when the reminder was created", and presence is a deterministic match against
later snapshots. On Windows the app identity is the process executable
("Code.exe") where macOS used the bundle id; browser tabs are title-bound for
now (Chromium puts the tab title in the window title), with url_key kept for
when a URL source lands.
"""

from __future__ import annotations

import re

# Spinner/animation glyphs some apps render into their titles — every frame
# looked like a context change until these were stripped (dogfooding finding
# #1 on the Mac; terminals do the same on Windows).
_SPINNER = set("✳✱✻✽●⏺○")


def normalize_title(s):
    if not isinstance(s, str) or not s:
        return None
    out = "".join(
        ch for ch in s
        if not (0x2800 <= ord(ch) <= 0x28FF) and ch not in _SPINNER)
    out = re.sub(r"\s+", " ", out).strip()
    return out or None


def url_key(url):
    """Canonical key for a URL. YouTube gets a special case — the video id is
    the identity. Everything else keeps its query (a Google search IS its
    query) but drops the fragment."""
    if not isinstance(url, str) or not url:
        return None
    m = re.match(r"^https?://([^/]+)", url)
    host = m.group(1) if m else ""
    if "youtube.com" in host:
        v = re.search(r"[?&]v=([\w-]+)", url)
        if v:
            return "yt:" + v.group(1)
    short = re.match(r"^https?://youtu\.be/([\w-]+)", url)
    if short:
        return "yt:" + short.group(1)
    return re.sub(r"#.*$", "", url).rstrip("/")


def bind(snap):
    """Bind a referent from a snapshot: "this" = what's on screen right now."""
    if not snap:
        return None
    title = normalize_title(snap.get("tab") or snap.get("title"))
    ukey = url_key(snap.get("url"))
    if not title and not ukey:
        return None
    return {
        "exe": snap.get("exe"),
        "app": snap.get("app"),
        "urlKey": ukey,
        "titleCore": title,
        "boundAt": None,  # stamped by the caller (reminders.add)
        "label": f"{snap.get('app') or '?'} — {title or snap.get('url') or 'untitled'}",
    }


def _title_match(core, s):
    if not core or not s:
        return False
    n = normalize_title(s)
    if not n:
        return False
    a, b = n.lower(), core.lower()
    return a == b or b in a or a in b


def matches(ref, snap) -> bool:
    """Presence: is the referent visible in this snapshot?"""
    if not ref or not snap:
        return False
    if ref.get("urlKey"):
        if url_key(snap.get("url")) == ref["urlKey"]:
            return True
    elif ref.get("exe") and snap.get("exe") == ref["exe"]:
        if _title_match(ref.get("titleCore"), snap.get("tab") or snap.get("title")):
            return True
    # media fallback: a bound video still playing in the background is not
    # "done" — needs a media source (winsdk); degrades to False without one
    media = snap.get("media")
    if (ref.get("titleCore") and media and media.get("playing")
            and _title_match(ref["titleCore"], media.get("title"))):
        return True
    return False
