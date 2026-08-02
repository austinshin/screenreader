"""Pull a time expression out of reminder text — port of cr/timeparse.lua.

    "water the plants in 5 minutes"   → now + 300
    "get on a meeting at 130"         → today 1:30 PM (or tomorrow if past)
    "call the vet at 4"               → next 4 o'clock
    "send it at 5pm august 1"         → Aug 1, 5:00 PM

Parsed in two independent halves, a DATE and a TIME, then combined — either
half can be absent: a date alone defaults to 9am ("tonight": 8pm), a time
alone means its next occurrence. Input arrives typed and voice-transcribed;
speech rarely produces a colon, so a bare 3-4 digit run after "at" reads as
h:mm. Matching happens on a lowercased copy; spans are cut from the ORIGINAL
string so typed text keeps its casing.
"""

from __future__ import annotations

import re
import time

WORD_NUMS = {
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
    "fifty": 50, "sixty": 60, "ninety": 90,
}

UNIT_SECONDS = {
    "second": 1, "seconds": 1, "sec": 1, "secs": 1,
    "minute": 60, "minutes": 60, "min": 60, "mins": 60,
    "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600,
    "day": 86400, "days": 86400, "week": 604800, "weeks": 604800,
}

MONTHS = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
    "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
}

WEEKDAYS = {  # tm_wday: Monday=0
    "monday": 0, "mon": 0, "tuesday": 1, "tue": 1, "tues": 1,
    "wednesday": 2, "wed": 2, "thursday": 3, "thu": 3, "thurs": 3,
    "friday": 4, "fri": 4, "saturday": 5, "sat": 5, "sunday": 6, "sun": 6,
}


def _num(tok: str):
    if tok.isdigit():
        return int(tok)
    return WORD_NUMS.get(tok)


# Connectives that belonged to the time phrase and read as garbage once it's
# gone: "pay rent on august 1" must not leave "pay rent on".
TRAILING = {"on", "at", "by", "in", "of", "for", "this", "next",
            "until", "till", "around"}


def _cut(text: str, s: int, e: int) -> str:
    """Remove [s, e) from text, tidy whitespace and dangling connectors."""
    out = text[:s] + " " + text[e:]
    out = re.sub(r"\s+", " ", out).strip().rstrip(" ,")
    while True:
        m = re.match(r"^(.+?)\s+([A-Za-z]+)$", out)
        if m and m.group(2).lower() in TRAILING:
            out = m.group(1)
        else:
            break
    return out


# ------------------------------------------------------------------ date ----

_MONTH_ALT = "|".join(sorted(MONTHS, key=len, reverse=True))
_WDAY_ALT = "|".join(sorted(WEEKDAYS, key=len, reverse=True))

_RE_MONTH_DAY = re.compile(
    rf"\b({_MONTH_ALT})\b[\s,]+(\d\d?)(?:st|nd|rd|th)?(?:[\s,]+(\d{{4}}))?")
_RE_DAY_MONTH = re.compile(
    rf"\b(\d\d?)(?:st|nd|rd|th)?\s+(?:of\s+)?({_MONTH_ALT})\b")
_RE_SLASH = re.compile(r"(?<!\d)(\d\d?)/(\d\d?)(?:/(\d{4}))?(?!\d)")
_RE_TOMORROW = re.compile(r"\btomorrow\b")
_RE_TODAY = re.compile(r"\btoday\b")
_RE_TONIGHT = re.compile(r"\btonight\b")
_RE_WEEKDAY = re.compile(rf"\b({_WDAY_ALT})\b")


def _find_date(t: str):
    """→ (dict(y, m, d, sameday, night), start, end) or None.

    sameday: the date is today by definition ("today"/"tonight"), so a past
    default time must move within the day, never to next year.
    """
    best = None

    def consider(s, e, y, m, d, sameday=False, night=False):
        nonlocal best
        if best is None or s < best[1]:
            best = ({"y": y, "m": m, "d": d, "sameday": sameday, "night": night}, s, e)

    now = time.localtime()

    m = _RE_MONTH_DAY.search(t)
    if m:
        yr = int(m.group(3)) if m.group(3) else None
        consider(m.start(), m.end(), yr, MONTHS[m.group(1)], int(m.group(2)))
    m = _RE_DAY_MONTH.search(t)
    if m:
        consider(m.start(), m.end(), None, MONTHS[m.group(2)], int(m.group(1)))
    m = _RE_SLASH.search(t)
    if m:
        yr = int(m.group(3)) if m.group(3) else None
        consider(m.start(), m.end(), yr, int(m.group(1)), int(m.group(2)))
    m = _RE_TOMORROW.search(t)
    if m:
        n = time.localtime(time.time() + 86400)
        consider(m.start(), m.end(), n.tm_year, n.tm_mon, n.tm_mday)
    m = _RE_TODAY.search(t)
    if m:
        consider(m.start(), m.end(), now.tm_year, now.tm_mon, now.tm_mday,
                 sameday=True)
    else:
        m = _RE_TONIGHT.search(t)
        if m:
            consider(m.start(), m.end(), now.tm_year, now.tm_mon, now.tm_mday,
                     sameday=True, night=True)
    m = _RE_WEEKDAY.search(t)
    if m:
        delta = (WEEKDAYS[m.group(1)] - now.tm_wday + 7) % 7
        if delta == 0:
            delta = 7  # "monday" on a Monday means next Monday
        n = time.localtime(time.time() + delta * 86400)
        consider(m.start(), m.end(), n.tm_year, n.tm_mon, n.tm_mday)

    if best is None or not best[0]["m"] or not best[0]["d"]:
        return None
    return best


# ------------------------------------------------------------------ time ----
# Ordered like the Lua original: am/pm forms first, then colonless speech
# forms, then bare "at N". `explicit` = am/pm was stated, so no
# next-occurrence guessing is needed.

_TIME_PATTERNS = [
    (re.compile(r"\bat\s+(\d{1,2}):(\d{2})\s*([ap])\.?m\.?"), "hm+ap"),
    (re.compile(r"(?<!\d)(\d{1,2}):(\d{2})\s*([ap])\.?m\.?"), "hm+ap"),
    (re.compile(r"\bat\s+(\d{1,2})\s*([ap])\.?m\.?"), "h+ap"),
    (re.compile(r"(?<!\d)(\d{1,2})\s*([ap])\.?m\.?"), "h+ap"),
    # speech drops the colon: "at 130 pm"
    (re.compile(r"\bat\s+(\d)(\d{2})\s*([ap])\.?m\.?"), "hm+ap"),
    (re.compile(r"\bat\s+(\d{2})(\d{2})\s*([ap])\.?m\.?"), "hm+ap"),
    # no am/pm — resolve to the next occurrence
    (re.compile(r"\bat\s+(\d{1,2}):(\d{2})"), "hm"),
    (re.compile(r"\bat\s+(\d)(\d{2})(?!\d)"), "hm"),     # "at 130"
    (re.compile(r"\bat\s+(\d{2})(\d{2})(?!\d)"), "hm"),  # "at 1130"
    (re.compile(r"\bat\s+(\d{1,2})\s+(\d{2})(?!\d)"), "hm"),  # "at 1 30"
    (re.compile(r"\bat\s+(\d{1,2})(?!\d)"), "h"),        # "at 4"
    (re.compile(r"(?<!\d)(\d{1,2}):(\d{2})"), "hm"),
    (re.compile(r"\bnoon\b"), "noon"),
    (re.compile(r"\bmidnight\b"), "midnight"),
]


def _find_time(t: str):
    """→ (dict(hour, min, explicit), start, end) or None."""
    for pat, kind in _TIME_PATTERNS:
        m = pat.search(t)
        if not m:
            continue
        if kind == "noon":
            return {"hour": 12, "min": 0, "explicit": True}, m.start(), m.end()
        if kind == "midnight":
            return {"hour": 0, "min": 0, "explicit": True}, m.start(), m.end()
        g = m.groups()
        if kind == "hm+ap":
            hour, mins, ap = int(g[0]), int(g[1]), g[2]
        elif kind == "h+ap":
            hour, mins, ap = int(g[0]), 0, g[1]
        elif kind == "hm":
            hour, mins, ap = int(g[0]), int(g[1]), None
        else:
            hour, mins, ap = int(g[0]), 0, None
        if hour <= 24 and mins < 60:
            if ap == "p" and hour < 12:
                hour += 12
            if ap == "a" and hour == 12:
                hour = 0
            return {"hour": hour, "min": mins, "explicit": ap is not None}, m.start(), m.end()
    return None


# ------------------------------------------------------------- relative -----

_RE_HALF_HOUR = re.compile(r"\bin half an hour\b")
_RE_N_AND_HALF = re.compile(r"\bin\s+(\w+)\s+and\s+a\s+half\s+([a-z]+)")
# Speech pads numbers with hedges — "in like five minutes". Without these the
# phrase doesn't parse at all, and the reminder silently loses its time.
_RE_RELATIVE = re.compile(
    r"\bin\s+(?:like\s+|about\s+|around\s+|roughly\s+|maybe\s+|just\s+)?(\w+)\s+([a-z]+)")


def _find_relative(t: str):
    m = _RE_HALF_HOUR.search(t)
    if m:
        return int(time.time()) + 1800, m.start(), m.end()
    m = _RE_N_AND_HALF.search(t)
    if m:
        v, u = _num(m.group(1)), UNIT_SECONDS.get(m.group(2))
        if v and u:
            return int(time.time()) + int(v * u + u / 2), m.start(), m.end()
    m = _RE_RELATIVE.search(t)
    if m:
        v, u = _num(m.group(1)), UNIT_SECONDS.get(m.group(2))
        if v and u:
            return int(time.time()) + v * u, m.start(), m.end()
    return None


# ------------------------------------------------------------------ api -----

def extract(text: str):
    """text → (clean_text, trigger_epoch | None, phrase | None)"""
    lower = text.lower()

    # "in N minutes" is self-contained: it means from *now*.
    rel = _find_relative(lower)
    if rel:
        at, rs, re_ = rel
        return _cut(text, rs, re_), at, text[rs:re_]

    date_hit = _find_date(lower)
    time_hit = _find_time(lower)
    if not date_hit and not time_hit:
        return text, None, None

    date = date_hit[0] if date_hit else None
    tm = time_hit[0] if time_hit else None
    now = time.localtime()
    when = dict(
        year=(date["y"] or now.tm_year) if date else now.tm_year,
        month=date["m"] if date else now.tm_mon,
        day=date["d"] if date else now.tm_mday,
        # a date with no time means 9am; "tonight" with no time means 8pm
        hour=tm["hour"] if tm else (20 if date and date["night"] else 9),
        minute=tm["min"] if tm else 0,
    )

    def to_epoch(w):
        try:
            return int(time.mktime((w["year"], w["month"], w["day"],
                                    w["hour"], w["minute"], 0, -1, -1, -1)))
        except (OverflowError, ValueError):
            return None

    at = to_epoch(when)
    if at is None:
        return text, None, None

    now_s = int(time.time())
    if not date:
        # Time only. Roll forward to the next occurrence so "at 130" at 1:32pm
        # means tomorrow, never two minutes ago.
        if not (tm and tm["explicit"]) and at <= now_s and when["hour"] < 12:
            at += 12 * 3600  # "at 4" after 4am can still mean 4pm today
        while at <= now_s:
            at += 86400
    elif at <= now_s:
        if date["sameday"] and not tm:
            # "today" whose default 9am already passed still means *today*:
            # the evening, or an hour out if the evening is gone too.
            when["hour"], when["minute"] = 20, 0
            at = to_epoch(when)
            if not at or at <= now_s:
                at = now_s + 3600
        elif not date["y"]:
            # A bare "august 1" that already passed means next year. ("today
            # at 2pm" said at 3pm keeps its past time and fires now — you're
            # late, and hearing so beats it silently moving.)
            when["year"] += 1
            at = to_epoch(when) or at

    # Cut the later span first so the earlier index stays valid.
    spans = []
    if date_hit:
        spans.append((date_hit[1], date_hit[2]))
    if time_hit:
        spans.append((time_hit[1], time_hit[2]))
    spans.sort(key=lambda sp: -sp[0])
    out, phrase = text, []
    for s, e in spans:
        phrase.append(lower[s:e])
        out = _cut(out, s, e)
    return out, at, " ".join(phrase)


def fmt_due(at) -> str | None:
    """"in 4 min (5:23 PM)" / "Fri Aug 07, 9:00 AM (in 5 days)" — for toasts."""
    if not at:
        return None
    delta = at - int(time.time())
    clock = time.strftime("%I:%M %p", time.localtime(at)).lstrip("0")
    if delta < 0:
        rel = "now"
    elif delta < 90:
        rel = f"{delta}s"
    elif delta < 5400:
        rel = f"{round(delta / 60)} min"
    elif delta < 129600:
        rel = f"{delta / 3600:.1f}".rstrip("0").rstrip(".") + " hr"
    else:
        rel = f"{round(delta / 86400)} days"
    day = ""
    if time.strftime("%x", time.localtime(at)) != time.strftime("%x"):
        day = time.strftime("%a %b %d, ", time.localtime(at))
    return f"{day}{clock} (in {rel})"
