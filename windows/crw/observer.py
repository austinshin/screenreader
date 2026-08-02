"""Screen context observer — port of cr/observer.lua onto Win32.

Samples "what is the user looking at" using the cheap rungs: foreground
window title + owning process (rung 1), media playback via the system's SMTC
API when winsdk is installed (rung 3). No screenshots, no OCR.

Windows differences worth naming:
- App identity is the process executable ("Code.exe"), where macOS used the
  bundle id. Chromium browsers put the tab title in the window title, so
  title binding covers tabs without an AppleScript equivalent; snap["url"]
  stays None until a URL source (UIA or an extension) lands.
- "wake" has no clean event without a hidden window for WM_POWERBROADCAST, so
  it is inferred: idle above the away threshold collapsing to ~zero IS the
  user returning. Same seam, cheaper sensor.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import time
from pathlib import Path

from . import config, eventlog

current: dict | None = None
previous: dict | None = None
running = False

_subscribers = []       # fn(snap, prev) on every context change
_tick_subscribers = []  # fn(snap) on EVERY poll — cooldown needs unchanged samples too
_last_key = None
_polls_since_log = 0
_last_idle = 0.0

_user32 = ctypes.windll.user32
_kernel32 = ctypes.windll.kernel32


class _LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", wt.UINT), ("dwTime", wt.DWORD)]


def idle_seconds() -> float:
    lii = _LASTINPUTINFO()
    lii.cbSize = ctypes.sizeof(lii)
    if not _user32.GetLastInputInfo(ctypes.byref(lii)):
        return 0.0
    return max(0.0, (_kernel32.GetTickCount() - lii.dwTime) / 1000.0)


def _foreground() -> tuple[str | None, str | None]:
    """→ (exe basename, window title) of the foreground window."""
    hwnd = _user32.GetForegroundWindow()
    if not hwnd:
        return None, None
    buf = ctypes.create_unicode_buffer(512)
    _user32.GetWindowTextW(hwnd, buf, 512)
    title = buf.value or None

    pid = wt.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    exe = None
    if pid.value:
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        h = _kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if h:
            try:
                size = wt.DWORD(1024)
                path_buf = ctypes.create_unicode_buffer(size.value)
                if _kernel32.QueryFullProcessImageNameW(h, 0, path_buf,
                                                        ctypes.byref(size)):
                    exe = Path(path_buf.value).name
            finally:
                _kernel32.CloseHandle(h)
    return exe, title


# media (optional): the SMTC session manager knows what any modern app is
# playing — browsers included — which is strictly better than macOS needed
# a third-party CLI for. Guarded import; absent winsdk degrades to None.
_media_cache = None
_media_thread = None


def _media_loop():
    global _media_cache
    try:
        import asyncio

        from winsdk.windows.media.control import (
            GlobalSystemMediaTransportControlsSessionManager as Manager,
        )
    except ImportError:
        return  # no winsdk: media stays None forever, matcher degrades

    async def read():
        mgr = await Manager.request_async()
        s = mgr.get_current_session()
        if not s:
            return None
        info = await s.try_get_media_properties_async()
        playing = s.get_playback_info().playback_status == 4  # PLAYING
        return {"title": info.title, "playing": playing} if info.title else None

    while running:
        try:
            _media_cache = asyncio.run(read())
        except Exception:
            _media_cache = None
        time.sleep(config.POLL_INTERVAL)


def _take_snapshot(reason: str) -> dict:
    exe, title = _foreground()
    app = exe[:-4] if exe and exe.lower().endswith(".exe") else exe
    return {
        "event": "context",
        "reason": reason,
        "app": app,
        "exe": exe,
        "title": title,
        "url": None,   # future: UIA address-bar read or a browser extension
        "tab": None,
        "media": _media_cache,
        "idle": int(idle_seconds()),
    }


def _key_of(s: dict) -> str:
    media = s.get("media")
    return "|".join([s.get("app") or "", s.get("title") or "", s.get("url") or "",
                     ("playing" if media and media.get("playing") else
                      "paused" if media else "")])


def poll(reason: str = "manual") -> dict:
    global current, previous, _last_key, _polls_since_log, _last_idle
    snap = _take_snapshot(reason)

    # returning from a real absence is a seam exactly like an app switch
    if reason == "timer" and _last_idle >= config.IDLE_THRESHOLD and snap["idle"] < 5:
        snap["reason"] = reason = "wake"
    _last_idle = snap["idle"] if reason != "wake" else 0

    key = _key_of(snap)
    _polls_since_log += 1
    if key != _last_key:
        snap["event"] = "context.change"
        eventlog.append(dict(snap))
        _polls_since_log = 0
        _last_key = key
        previous = current
        current = snap
        for fn in _subscribers:
            try:
                fn(snap, previous)
            except Exception:
                pass
    else:
        current = snap
        if _polls_since_log >= config.HEARTBEAT_EVERY:
            snap["event"] = "context.heartbeat"
            eventlog.append(dict(snap))
            _polls_since_log = 0
    for fn in _tick_subscribers:
        try:
            fn(snap)
        except Exception:
            pass
    return snap


def subscribe(fn) -> None:
    _subscribers.append(fn)


def subscribe_tick(fn) -> None:
    _tick_subscribers.append(fn)


def start() -> None:
    global running, _media_thread
    if running:
        return
    running = True
    import threading
    _media_thread = threading.Thread(target=_media_loop, daemon=True)
    _media_thread.start()
    eventlog.append({"event": "observer.start"})
    poll("start")


def stop() -> None:
    global running
    running = False
    eventlog.append({"event": "observer.stop"})
