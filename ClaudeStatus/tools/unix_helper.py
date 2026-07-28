#!/usr/bin/env python3
"""
Helper for setup.sh / uninstall.sh (Linux + macOS). Subcommands:

  findport                     print "<device>|<1 if CH340 else 0>", or exit 1
  search <city name>           print "idx|name|country|cc|lat|lon" per match
  uaregion <lat> <lon>         print the Ukrainian oblast name (for alerts)
  writeconfig <path> <city> <lat> <lon> <cc> <region> <brightness> <sound> <allclear>
                               write config.json ("-" city disables weather)
  patchhooks <appdir>          register the five Claude Code hooks (python3)
  striphooks <appdir>          remove our hooks (uninstall, no-backup path)
  stopdaemon                   graceful daemon stop via exit file; hard kill
                               only if it ignores the request for 5 s

Keep the hook set and USB IDs in lock-step with setup.ps1 / lcd_daemon.py.
"""
from __future__ import annotations
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.parse
import urllib.request

KNOWN_VID_PIDS = {
    (0x2341, 0x0043),  # genuine Arduino Uno
    (0x1A86, 0x7523),  # CH340 (Nano clones)
}
UA = {"User-Agent": "claude-status-lcd-setup/1.0"}


def find_port() -> int:
    try:
        from serial.tools import list_ports
    except ImportError:
        print("pyserial missing", file=sys.stderr)
        return 1
    for p in list_ports.comports():
        if (p.vid, p.pid) in KNOWN_VID_PIDS:
            is_ch340 = 1 if p.vid == 0x1A86 else 0
            print(f"{p.device}|{is_ch340}")
            return 0
    return 1


def search(name: str) -> int:
    url = ("https://geocoding-api.open-meteo.com/v1/search?"
           + urllib.parse.urlencode({"name": name, "count": 5,
                                     "language": "en", "format": "json"}))
    with urllib.request.urlopen(
            urllib.request.Request(url, headers=UA), timeout=15) as resp:
        data = json.load(resp)
    results = data.get("results") or []
    for i, r in enumerate(results, 1):
        label = r.get("name", "?")
        admin = r.get("admin1", "")
        if admin and admin != label:
            label = f"{label} ({admin})"
        print(f"{i}|{label}|{r.get('country', '')}|"
              f"{str(r.get('country_code', '')).lower()}|"
              f"{r.get('latitude')}|{r.get('longitude')}")
    return 0 if results else 1


def uaregion(lat: str, lon: str) -> int:
    # Same source the Windows wizard uses: Nominatim reverse geocode with
    # Ukrainian labels; address.state is the oblast name the alert feeds use.
    url = ("https://nominatim.openstreetmap.org/reverse?"
           + urllib.parse.urlencode({"lat": lat, "lon": lon, "format": "json",
                                     "accept-language": "uk", "zoom": "10"}))
    try:
        with urllib.request.urlopen(
                urllib.request.Request(url, headers=UA), timeout=15) as resp:
            data = json.load(resp)
        print((data.get("address") or {}).get("state", ""))
    except Exception:
        print("")
    return 0


def writeconfig(path: str, city: str, lat: str, lon: str, cc: str,
                region: str, brightness: str, sound: str, allclear: str) -> int:
    cfg: dict = {
        "brightness": max(0, min(100, int(brightness))),
        "prefs": {"sound": sound == "1", "allclear": allclear == "1"},
    }
    if city == "-":
        cfg["weather"] = None
    else:
        cfg["weather"] = {
            "city": city,
            "latitude": float(lat),
            "longitude": float(lon),
            "country_code": cc,
            "alert_region": region,
        }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    return 0


SETTINGS = os.path.expanduser("~/.claude/settings.json")
BACKUP = SETTINGS + ".claudestatus_backup"
HOOK_EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse",
               "Notification", "Stop")


def _load_settings() -> dict:
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS, "r", encoding="utf-8-sig") as f:
        raw = f.read().strip()
    return json.loads(raw) if raw else {}


def _save_settings(data: dict) -> None:
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def patchhooks(appdir: str) -> int:
    if os.path.exists(SETTINGS) and not os.path.exists(BACKUP):
        shutil.copy2(SETTINGS, BACKUP)
    data = _load_settings()
    hooks = data.setdefault("hooks", {})

    def block(cmd: str, matcher: "str | None") -> list:
        b: dict = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
        if matcher is not None:
            b["matcher"] = matcher
        return [b]

    notify = f'python3 "{appdir}/notify.py"'
    hooks["UserPromptSubmit"] = block(f"{notify} W", None)
    hooks["PreToolUse"] = block(f'python3 "{appdir}/hook_pretool.py"', "")
    hooks["PostToolUse"] = block(f"{notify} C", "")
    hooks["Notification"] = block(f"{notify} P", None)
    hooks["Stop"] = block(f"{notify} I", None)
    _save_settings(data)
    return 0


def striphooks(appdir: str) -> int:
    data = _load_settings()
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0
    for evt in HOOK_EVENTS:
        entries = hooks.get(evt)
        if not isinstance(entries, list):
            continue
        kept = [b for b in entries
                if not any(appdir in str(h.get("command", ""))
                           for h in (b.get("hooks") or []))]
        if kept:
            hooks[evt] = kept
        else:
            hooks.pop(evt, None)
    if not hooks:
        data.pop("hooks", None)
    _save_settings(data)
    return 0


def stopdaemon() -> int:
    tmp = tempfile.gettempdir()
    pid_file = os.path.join(tmp, "claude_lcd_daemon.pid")
    exit_file = os.path.join(tmp, "claude_lcd_daemon.exit")
    try:
        with open(pid_file, "r", encoding="ascii") as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return 0
    def alive() -> bool:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    if not alive():
        return 0
    # Graceful: the daemon closes the serial port in its finally block. A
    # hard kill can wedge the CH340's handle until the device is replugged.
    open(exit_file, "w").close()
    for _ in range(25):
        time.sleep(0.2)
        if not alive():
            print("daemon exited cleanly")
            break
    else:
        try:
            os.kill(pid, 9)
            print("daemon force-killed (replug the device if its port misbehaves)")
        except OSError:
            pass
    try:
        os.remove(exit_file)
    except OSError:
        pass
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "findport":
        return find_port()
    if cmd == "search":
        return search(" ".join(args))
    if cmd == "uaregion":
        return uaregion(args[0], args[1])
    if cmd == "writeconfig":
        return writeconfig(*args)
    if cmd == "patchhooks":
        return patchhooks(args[0])
    if cmd == "striphooks":
        return striphooks(args[0])
    if cmd == "stopdaemon":
        return stopdaemon()
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
