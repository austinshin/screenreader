"""Notification-area icon — the menu bar equivalent, in raw Win32.

Deliberately ctypes over pystray: the tray is core UI, and core stays on the
standard library. The icon itself is generated (a ◉, same glyph the macOS
menu bar uses) so no binary asset lives in the repo.

Everything here runs on the winloop thread, which already owns a message
loop — a tray icon is just a hidden window that receives the icon's callback
messages. Menu picks and clicks are translated to the same action ids the
hotkeys produce and put on the app queue; nothing here touches UI or state.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import math
import struct

from . import config, eventlog

# Private WinDLL instances (not ctypes.windll.*): the signatures declared
# below must not leak onto the process-wide cached function objects that
# observer/winloop share.
_user32 = ctypes.WinDLL("user32")
_shell32 = ctypes.WinDLL("shell32")
_kernel32 = ctypes.WinDLL("kernel32")

# Every signature declared, nothing left to ctypes' 32-bit int defaults.
# The lesson behind this block: menu messages (WM_INITMENUPOPUP,
# WM_ENTERIDLE, …) carry handle-sized params, and an untyped
# DefWindowProcW call raised OverflowError on them *inside the WNDPROC* —
# ctypes swallows the exception and returns 0, Windows' default menu logic
# never runs, and the context menu renders as a blank white box.
_LRESULT = ctypes.c_ssize_t
_WPARAM = ctypes.c_size_t
_LPARAM = ctypes.c_ssize_t
_user32.DefWindowProcW.restype = _LRESULT
_user32.DefWindowProcW.argtypes = [wt.HWND, wt.UINT, _WPARAM, _LPARAM]
_user32.CreatePopupMenu.restype = wt.HMENU
_user32.AppendMenuW.restype = wt.BOOL
_user32.AppendMenuW.argtypes = [wt.HMENU, wt.UINT, ctypes.c_size_t, wt.LPCWSTR]
_user32.TrackPopupMenu.restype = ctypes.c_int  # item id under TPM_RETURNCMD
_user32.TrackPopupMenu.argtypes = [wt.HMENU, wt.UINT, ctypes.c_int,
                                   ctypes.c_int, ctypes.c_int, wt.HWND,
                                   ctypes.c_void_p]
_user32.DestroyMenu.argtypes = [wt.HMENU]
_user32.SetForegroundWindow.argtypes = [wt.HWND]
_user32.PostMessageW.argtypes = [wt.HWND, wt.UINT, _WPARAM, _LPARAM]
_user32.CreateWindowExW.restype = wt.HWND
_user32.CreateWindowExW.argtypes = [wt.DWORD, wt.LPCWSTR, wt.LPCWSTR,
                                    wt.DWORD, ctypes.c_int, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_int, wt.HWND,
                                    wt.HMENU, wt.HINSTANCE, ctypes.c_void_p]
_user32.LoadImageW.restype = wt.HANDLE
_user32.LoadImageW.argtypes = [wt.HINSTANCE, wt.LPCWSTR, wt.UINT,
                               ctypes.c_int, ctypes.c_int, wt.UINT]
_kernel32.GetModuleHandleW.restype = wt.HMODULE
_kernel32.GetModuleHandleW.argtypes = [wt.LPCWSTR]
_shell32.Shell_NotifyIconW.restype = wt.BOOL
_shell32.Shell_NotifyIconW.argtypes = [wt.DWORD, ctypes.c_void_p]

WM_APP_TRAY = 0x8001          # uCallbackMessage for the icon
_WM_DESTROY = 0x0002
_WM_COMMAND = 0x0111
_WM_LBUTTONUP = 0x0202
_WM_RBUTTONUP = 0x0205

_NIF_MESSAGE, _NIF_ICON, _NIF_TIP = 0x1, 0x2, 0x4
_NIM_ADD, _NIM_MODIFY, _NIM_DELETE = 0x0, 0x1, 0x2

_MENU = [  # (command id, label, action id on the app queue)
    (1, "New reminder\tCtrl+Alt+N", "reminder"),
    (2, "Show my reminders\tCtrl+Alt+R", "glance"),
    (3, "Send a test card\tCtrl+Alt+T", "test"),
    (4, "Open logs folder", "logs"),
    (0, None, None),  # separator
    (5, "Quit\tCtrl+Alt+Q", "quit"),
]

_WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wt.HWND, wt.UINT,
                              ctypes.c_size_t, ctypes.c_ssize_t)


class _NOTIFYICONDATAW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wt.DWORD), ("hWnd", wt.HWND), ("uID", wt.UINT),
        ("uFlags", wt.UINT), ("uCallbackMessage", wt.UINT),
        ("hIcon", wt.HICON), ("szTip", wt.WCHAR * 128),
        ("dwState", wt.DWORD), ("dwStateMask", wt.DWORD),
        ("szInfo", wt.WCHAR * 256), ("uVersion", wt.UINT),
        ("szInfoTitle", wt.WCHAR * 64), ("dwInfoFlags", wt.DWORD),
    ]


_queue = None
_hwnd = None
_hicon = None
_wndproc_ref = None       # the callback must outlive the window
_taskbar_created = None


def _write_icon() -> str:
    """Generate a 32×32 ◉ as a real .ico — a ring plus a center dot in the
    project's accent blue, alpha-blended edges, transparent background. The
    ICO container is simple enough that struct-packing it beats shipping a
    binary blob nobody can diff."""
    path = config.data_dir() / "cr.ico"
    if path.exists():
        return str(path)
    size = 32
    cx = (size - 1) / 2
    b, g, r = 0xF7, 0xA2, 0x7A  # #7AA2F7, BGRA order

    def coverage(d):
        # ring 9.5..13.5, dot <= 4.5, both with a 1px soft edge
        ring = min(d - 8.5, 14.5 - d)
        dot = 5.5 - d
        a = max(ring, dot)
        return max(0.0, min(1.0, a))

    rows = []
    for y in range(size - 1, -1, -1):  # BMP rows are bottom-up
        row = bytearray()
        for x in range(size):
            a = coverage(math.dist((x, y), (cx, cx)))
            row += bytes((b, g, r, int(a * 255)))
        rows.append(bytes(row))
    xor = b"".join(rows)
    and_mask = b"\x00" * (size * 4)  # alpha does the masking

    bih = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
                      len(xor) + len(and_mask), 0, 0, 0, 0)
    image = bih + xor + and_mask
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(image), 22)
    path.write_bytes(header + entry + image)
    return str(path)


def _show_menu() -> None:
    menu = _user32.CreatePopupMenu()
    for cmd, label, _ in _MENU:
        if label is None:
            ok = _user32.AppendMenuW(menu, 0x800, 0, None)     # MF_SEPARATOR
        else:
            ok = _user32.AppendMenuW(menu, 0x0, cmd, label)    # MF_STRING
        if not ok:
            eventlog.append({"event": "tray.menu_append_failed", "item": label})
    pt = wt.POINT()
    _user32.GetCursorPos(ctypes.byref(pt))
    # the classic tray-menu dance: without SetForegroundWindow the menu
    # refuses to dismiss when the user clicks away (KB135788)
    _user32.SetForegroundWindow(_hwnd)
    cmd = _user32.TrackPopupMenu(menu, 0x0100 | 0x0002,  # TPM_RETURNCMD|RIGHT
                                 pt.x, pt.y, 0, _hwnd, None)
    _user32.PostMessageW(_hwnd, 0, 0, 0)
    _user32.DestroyMenu(menu)
    for c, _, action in _MENU:
        if c == cmd and action:
            _queue.put((action, "tray"))


def _wndproc(hwnd, msg, wparam, lparam):
    # Exception-proof by construction: a WNDPROC that raises has its
    # exception eaten by ctypes and returns 0 for a message Windows needed
    # answered — which is invisible everywhere except the broken behavior it
    # causes. Anything unexpected falls through to DefWindowProc instead.
    try:
        if msg == WM_APP_TRAY:
            if lparam == _WM_LBUTTONUP:
                _queue.put(("glance", "tray"))
            elif lparam == _WM_RBUTTONUP:
                _show_menu()
            return 0
        if msg == _taskbar_created:
            _add_icon()  # explorer restarted; the icon died with it
            return 0
        if msg == _WM_DESTROY:
            remove()
            return 0
    except Exception as e:
        eventlog.append({"event": "tray.wndproc_error", "msg": msg,
                         "error": str(e)[:200]})
    return _user32.DefWindowProcW(hwnd, msg, wparam, lparam)


def _nid() -> _NOTIFYICONDATAW:
    nid = _NOTIFYICONDATAW()
    nid.cbSize = ctypes.sizeof(nid)
    nid.hWnd = _hwnd
    nid.uID = 1
    nid.uFlags = _NIF_MESSAGE | _NIF_ICON | _NIF_TIP
    nid.uCallbackMessage = WM_APP_TRAY
    nid.hIcon = _hicon
    nid.szTip = "Contextual Reminders"
    return nid


def _add_icon() -> None:
    _shell32.Shell_NotifyIconW(_NIM_ADD, ctypes.byref(_nid()))


def install(out_queue) -> bool:
    """Create the hidden window + icon. MUST run on the thread that runs the
    message loop (winloop calls this before entering GetMessage)."""
    global _queue, _hwnd, _hicon, _wndproc_ref, _taskbar_created
    _queue = out_queue
    try:
        _taskbar_created = _user32.RegisterWindowMessageW("TaskbarCreated")
        _wndproc_ref = _WNDPROC(_wndproc)

        class WNDCLASSW(ctypes.Structure):
            _fields_ = [("style", wt.UINT), ("lpfnWndProc", _WNDPROC),
                        ("cbClsExtra", ctypes.c_int), ("cbWndExtra", ctypes.c_int),
                        ("hInstance", wt.HINSTANCE), ("hIcon", wt.HICON),
                        ("hCursor", wt.HANDLE), ("hbrBackground", wt.HBRUSH),
                        ("lpszMenuName", wt.LPCWSTR), ("lpszClassName", wt.LPCWSTR)]

        wc = WNDCLASSW()
        wc.lpfnWndProc = _wndproc_ref
        wc.hInstance = _kernel32.GetModuleHandleW(None)
        wc.lpszClassName = "crw-tray"
        _user32.RegisterClassW(ctypes.byref(wc))
        # a real (hidden) top-level window, not message-only: TrackPopupMenu
        # needs a window that can hold foreground
        _hwnd = _user32.CreateWindowExW(0, "crw-tray", "crw-tray", 0,
                                        0, 0, 0, 0, None, None,
                                        wc.hInstance, None)
        _hicon = _user32.LoadImageW(None, _write_icon(), 1, 0, 0,
                                    0x10 | 0x40)  # LR_LOADFROMFILE|DEFAULTSIZE
        _add_icon()
        eventlog.append({"event": "tray.installed"})
        return True
    except Exception as e:
        # a missing tray icon is a cosmetic loss, never a startup failure
        eventlog.append({"event": "tray.failed", "error": str(e)[:200]})
        return False


def remove() -> None:
    if _hwnd:
        try:
            _shell32.Shell_NotifyIconW(_NIM_DELETE, ctypes.byref(_nid()))
        except Exception:
            pass
