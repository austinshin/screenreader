"""Hotkeys + foreground-change events — the Win32 message loop thread.

RegisterHotKey is the Carbon-hotkey equivalent and carries the same lesson
the macOS port learned the hard way: it costs nothing until pressed. The
alternative — a low-level keyboard hook (WH_KEYBOARD_LL) — runs a callback on
every keystroke system-wide and starves under load exactly like hs.eventtap
did, dropping input everywhere. So: no hooks, ever.

The same thread owns a WinEventHook for EVENT_SYSTEM_FOREGROUND, which is
what makes the seam gate event-driven: an app switch reaches the trigger FSM
the moment it happens instead of up to five seconds later.

Hold detection: RegisterHotKey only reports key-DOWN. For the push-to-talk
chord the release is watched by polling GetAsyncKeyState every 30ms — only
while recording, so the cost rounds to zero.

Everything discovered here is put on a queue the tk main loop drains; nothing
in this thread touches UI or reminder state directly.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import threading
import time

from . import config, eventlog

_user32 = ctypes.windll.user32

_MODS = {"alt": 0x1, "ctrl": 0x2, "shift": 0x4, "win": 0x8}
_MOD_NOREPEAT = 0x4000
_WM_HOTKEY = 0x0312
_WM_QUIT = 0x0012
_EVENT_SYSTEM_FOREGROUND = 0x0003
_WINEVENT_OUTOFCONTEXT = 0x0000

_WinEventProc = ctypes.WINFUNCTYPE(
    None, wt.HANDLE, wt.DWORD, wt.HWND, wt.LONG, wt.LONG, wt.DWORD, wt.DWORD)

queue = None          # set by start(): a queue.Queue the app drains
_thread = None
_thread_id = None
_hook_ref = None      # keep the callback alive or it gets collected mid-call
_hold_ids = set()     # action ids bound as hold (press/release) rather than tap
_holding = {}         # action id → True while its key is down

registered = {}       # action id → human chord string, for the startup banner
failed = {}           # action id → chord that RegisterHotKey refused


def _vk(key: str) -> int:
    return ord(key.upper())


def describe(mods, key) -> str:
    return "+".join([*(m.capitalize() for m in mods), key.upper()])


def _watch_release(action_id: str, vk: int) -> None:
    """Poll for key-up; RegisterHotKey never reports it."""
    while _holding.get(action_id):
        if not (_user32.GetAsyncKeyState(vk) & 0x8000):
            _holding[action_id] = False
            queue.put((action_id, "up"))
            return
        time.sleep(0.03)


def _loop(hold_ids) -> None:
    global _thread_id, _hook_ref
    _thread_id = ctypes.windll.kernel32.GetCurrentThreadId()

    ids = {}
    for i, (action_id, (mods, key)) in enumerate(config.HOTKEYS.items(), start=1):
        flags = 0
        for m in mods:
            flags |= _MODS.get(m, 0)
        # NOREPEAT everywhere: taps must not machine-gun, and the hold chord
        # detects its release by polling, not by watching repeats stop
        if _user32.RegisterHotKey(None, i, flags | _MOD_NOREPEAT, _vk(key)):
            ids[i] = (action_id, _vk(key))
            registered[action_id] = describe(mods, key)
        else:
            failed[action_id] = describe(mods, key)
            eventlog.append({"event": "hotkey.bind_failed", "id": action_id,
                             "chord": describe(mods, key)})

    def on_foreground(hook, event, hwnd, obj, child, tid, t):
        queue.put(("__app_switch__", None))

    _hook_ref = _WinEventProc(on_foreground)
    _user32.SetWinEventHook(_EVENT_SYSTEM_FOREGROUND, _EVENT_SYSTEM_FOREGROUND,
                            None, _hook_ref, 0, 0, _WINEVENT_OUTOFCONTEXT)

    msg = wt.MSG()
    while _user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        if msg.message == _WM_HOTKEY and msg.wParam in ids:
            action_id, vk = ids[msg.wParam]
            if action_id in hold_ids:
                if not _holding.get(action_id):
                    _holding[action_id] = True
                    queue.put((action_id, "down"))
                    threading.Thread(target=_watch_release,
                                     args=(action_id, vk), daemon=True).start()
            else:
                queue.put((action_id, "tap"))
        _user32.TranslateMessage(ctypes.byref(msg))
        _user32.DispatchMessageW(ctypes.byref(msg))

    for i in ids:
        _user32.UnregisterHotKey(None, i)


def start(out_queue, hold_ids=("dictate",)) -> None:
    global queue, _thread
    queue = out_queue
    _hold_ids.update(hold_ids)
    _thread = threading.Thread(target=_loop, args=(set(hold_ids),), daemon=True)
    _thread.start()


def stop() -> None:
    if _thread_id:
        _user32.PostThreadMessageW(_thread_id, _WM_QUIT, 0, 0)
