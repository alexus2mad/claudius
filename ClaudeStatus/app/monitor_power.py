"""
Monitor-power / system-suspend listener.

Windows: a daemon thread owns a message-only window registered for
`GUID_CONSOLE_DISPLAY_STATE` power notifications (event-driven, also covers
suspend/resume).

macOS: a daemon thread polls `CGDisplayIsAsleep` (CoreGraphics via ctypes,
no third-party deps) every 2 s.

Linux: a daemon thread polls DPMS state via `xset q` (X11) and falls back to
the GNOME / freedesktop ScreenSaver D-Bus interface (covers Wayland GNOME).
Other Wayland compositors have no portable query — there the listener stays
silent and the LCD simply never blanks with the monitors.

Each event lands in a thread-safe `MonitorState` holder; the daemon main
loop polls it (`take_event`) and forwards `M0`/`M1` to the Arduino.
"""
from __future__ import annotations
import os
import sys
import threading
from typing import Optional

# 'off' | 'on' | 'dim' | 'suspend' | 'resume'
Event = str


class MonitorState:
    """Latch of the most recent unread event."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._pending: Optional[Event] = None

    def set_event(self, evt: Event) -> None:
        with self._lock:
            self._pending = evt

    def take_event(self) -> Optional[Event]:
        with self._lock:
            evt = self._pending
            self._pending = None
            return evt


_state = MonitorState()


def take_event() -> Optional[Event]:
    return _state.take_event()


# --- Windows implementation --------------------------------------------------

if os.name == "nt":
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    WM_POWERBROADCAST = 0x0218
    PBT_APMSUSPEND = 0x0004
    PBT_APMRESUMEAUTOMATIC = 0x0012
    PBT_APMRESUMESUSPEND = 0x0007
    PBT_POWERSETTINGCHANGE = 0x8013
    DEVICE_NOTIFY_WINDOW_HANDLE = 0
    HWND_MESSAGE = -3

    class GUID(ctypes.Structure):
        _fields_ = [
            ("Data1", wintypes.DWORD),
            ("Data2", wintypes.WORD),
            ("Data3", wintypes.WORD),
            ("Data4", ctypes.c_ubyte * 8),
        ]

    def _make_guid(s: str) -> GUID:
        s = s.strip("{}").replace("-", "")
        g = GUID()
        g.Data1 = int(s[0:8], 16)
        g.Data2 = int(s[8:12], 16)
        g.Data3 = int(s[12:16], 16)
        for i in range(8):
            g.Data4[i] = int(s[16 + 2 * i:18 + 2 * i], 16)
        return g

    # The "modern" monitor-power notification. Data byte: 0=off, 1=on, 2=dim.
    GUID_CONSOLE_DISPLAY_STATE = _make_guid("{6FE69556-704A-47A0-8F24-C28D936FDA47}")

    class POWERBROADCAST_SETTING(ctypes.Structure):
        _fields_ = [
            ("PowerSetting", GUID),
            ("DataLength", wintypes.DWORD),
            ("Data", ctypes.c_ubyte * 4),
        ]

    WNDPROC = ctypes.WINFUNCTYPE(
        ctypes.c_ssize_t, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM
    )

    class WNDCLASS(ctypes.Structure):
        _fields_ = [
            ("style", wintypes.UINT),
            ("lpfnWndProc", WNDPROC),
            ("cbClsExtra", ctypes.c_int),
            ("cbWndExtra", ctypes.c_int),
            ("hInstance", wintypes.HINSTANCE),
            ("hIcon", wintypes.HICON),
            ("hCursor", wintypes.HANDLE),
            ("hbrBackground", wintypes.HBRUSH),
            ("lpszMenuName", wintypes.LPCWSTR),
            ("lpszClassName", wintypes.LPCWSTR),
        ]

    user32.DefWindowProcW.restype = ctypes.c_ssize_t
    user32.DefWindowProcW.argtypes = [
        wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM
    ]
    user32.RegisterClassW.restype = wintypes.ATOM
    user32.RegisterClassW.argtypes = [ctypes.POINTER(WNDCLASS)]
    user32.CreateWindowExW.restype = wintypes.HWND
    user32.CreateWindowExW.argtypes = [
        wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, wintypes.LPVOID,
    ]
    user32.RegisterPowerSettingNotification.restype = wintypes.HANDLE
    user32.RegisterPowerSettingNotification.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(GUID), wintypes.DWORD
    ]
    user32.GetMessageW.argtypes = [
        ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT
    ]

    def _guid_eq(a: GUID, b: GUID) -> bool:
        return (a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3
                and bytes(a.Data4) == bytes(b.Data4))

    def _thread_main() -> None:
        # Keep the WNDPROC callable alive for the lifetime of the window.
        def _wndproc(hwnd, msg, wparam, lparam):
            if msg == WM_POWERBROADCAST:
                if wparam == PBT_POWERSETTINGCHANGE and lparam:
                    pbs = POWERBROADCAST_SETTING.from_address(lparam)
                    if _guid_eq(pbs.PowerSetting, GUID_CONSOLE_DISPLAY_STATE):
                        data = pbs.Data[0]
                        if data == 0:
                            _state.set_event("off")
                        elif data == 1:
                            _state.set_event("on")
                        elif data == 2:
                            _state.set_event("dim")
                elif wparam == PBT_APMSUSPEND:
                    _state.set_event("suspend")
                elif wparam in (PBT_APMRESUMEAUTOMATIC, PBT_APMRESUMESUSPEND):
                    _state.set_event("resume")
                return 1
            return user32.DefWindowProcW(hwnd, msg, wparam, lparam)

        wndproc_cb = WNDPROC(_wndproc)
        hinst = kernel32.GetModuleHandleW(None)

        cls = WNDCLASS()
        cls.lpfnWndProc = wndproc_cb
        cls.hInstance = hinst
        cls.lpszClassName = "ClaudeStatusPowerSink"
        atom = user32.RegisterClassW(ctypes.byref(cls))
        if not atom:
            return

        hwnd = user32.CreateWindowExW(
            0, "ClaudeStatusPowerSink", "ClaudeStatusPowerSink",
            0, 0, 0, 0, 0,
            wintypes.HWND(HWND_MESSAGE), None, hinst, None,
        )
        if not hwnd:
            return

        user32.RegisterPowerSettingNotification(
            hwnd, ctypes.byref(GUID_CONSOLE_DISPLAY_STATE), DEVICE_NOTIFY_WINDOW_HANDLE
        )

        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    _thread: Optional[threading.Thread] = None

    def start_listener() -> None:
        global _thread
        if _thread is not None and _thread.is_alive():
            return
        _thread = threading.Thread(target=_thread_main, name="claude-lcd-power", daemon=True)
        _thread.start()

elif sys.platform == "darwin":
    import ctypes
    import time

    _POLL_SECONDS = 2.0

    def _poll_mac() -> None:
        try:
            cg = ctypes.CDLL(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cg.CGMainDisplayID.restype = ctypes.c_uint32
            cg.CGDisplayIsAsleep.restype = ctypes.c_bool
            cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
        except OSError:
            return
        prev: Optional[bool] = None
        while True:
            try:
                asleep = bool(cg.CGDisplayIsAsleep(cg.CGMainDisplayID()))
            except Exception:
                return
            if prev is not None and asleep != prev:
                _state.set_event("off" if asleep else "on")
            prev = asleep
            time.sleep(_POLL_SECONDS)

    _thread: Optional[threading.Thread] = None

    def start_listener() -> None:  # type: ignore[no-redef]
        global _thread
        if _thread is not None and _thread.is_alive():
            return
        _thread = threading.Thread(target=_poll_mac,
                                   name="claude-lcd-power", daemon=True)
        _thread.start()

else:  # Linux / other POSIX
    import subprocess
    import time

    _POLL_SECONDS = 2.0

    def _display_off_linux() -> Optional[bool]:
        """True = screen off/locked, False = on, None = can't tell."""
        # X11: DPMS state via xset.
        if os.environ.get("DISPLAY"):
            try:
                out = subprocess.run(
                    ["xset", "q"], capture_output=True, text=True, timeout=3
                ).stdout
                if ("Monitor is Off" in out or "Monitor is in Suspend" in out
                        or "Monitor is in Standby" in out):
                    return True
                if "Monitor is On" in out:
                    return False
            except Exception:
                pass
        # Wayland GNOME (and most desktops): ScreenSaver D-Bus interface.
        for dest, path, iface in (
            ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
             "org.gnome.ScreenSaver"),
            ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
             "org.freedesktop.ScreenSaver"),
        ):
            try:
                res = subprocess.run(
                    ["gdbus", "call", "--session", "--dest", dest,
                     "--object-path", path, "--method", f"{iface}.GetActive"],
                    capture_output=True, text=True, timeout=3)
                if res.returncode == 0:
                    if "true" in res.stdout:
                        return True
                    if "false" in res.stdout:
                        return False
            except Exception:
                pass
        return None

    def _poll_linux() -> None:
        prev: Optional[bool] = None
        while True:
            off = _display_off_linux()
            if off is None:
                # No way to query on this session type — stop polling.
                return
            if prev is not None and off != prev:
                _state.set_event("off" if off else "on")
            prev = off
            time.sleep(_POLL_SECONDS)

    _thread: Optional[threading.Thread] = None

    def start_listener() -> None:  # type: ignore[no-redef]
        global _thread
        if _thread is not None and _thread.is_alive():
            return
        _thread = threading.Thread(target=_poll_linux,
                                   name="claude-lcd-power", daemon=True)
        _thread.start()
