"""
Long-lived daemon that owns the display's serial port and tails a state file.
The port is auto-detected by USB VID:PID (see KNOWN_VID_PIDS); if the device
isn't attached the daemon waits for it and connects whenever it appears, so
it can safely start at login before the display is plugged in.

Each Claude Code hook just writes the desired LCD command(s) to the state file
(see notify.py). This daemon polls the file mtime, and on change writes the new
lines to the Arduino. Holding the port open avoids the ~1.5 s DTR reset that
would otherwise happen on every hook fire.

While IDLE, the daemon periodically fetches the user's actual plan usage from
`https://api.anthropic.com/api/oauth/usage` (authenticated with the OAuth
access token Claude Code stores in `~/.claude/.credentials.json`) and pushes
the result onto row 3 as a `Q:` line. Successive refreshes alternate between
the 5-hour session line and the 7-day weekly line so both percentages — the
same numbers the claude.ai Usage settings panel shows — are visible to the
user without a separate Arduino-side toggle.

After `SCREENSAVER_AFTER_SECONDS` of continuous IDLE the daemon stops the
usage refresh and switches the LCD into clock-screensaver mode (`K:HH:MM`)
instead.

Pay-as-you-go / API-key accounts have no OAuth session and so no 5h/7d usage
concept at all -- `_read_oauth_token()` simply finds nothing, the gauge/quota/
limit commands never fire, and the device just runs the core WORKING/IDLE/
screensaver/WAITING/PERMISSION screens. The one thing added for that case is
a one-time on-screen notice (see the `payg_notified` block in `main()`) so
the absence of usage data reads as "different plan" rather than "broken".

Display power: the daemon listens for Windows monitor-power and system
suspend/resume events (see monitor_power.py) and forwards `M0`/`M1` to the
Arduino so the LCD blanks together with the PC monitors.

The daemon writes its PID to %TEMP%/claude_lcd_daemon.pid and refuses to start
if another live instance already holds that PID. It self-exits after a long
idle (no state changes for IDLE_EXIT_SECONDS) so it doesn't linger forever.

Caveat: `/api/oauth/usage` is undocumented and beta-gated (note the
`anthropic-beta: oauth-2025-04-20` header). Anthropic may change the shape
without warning; the daemon logs and degrades gracefully if a fetch fails.
"""
from __future__ import annotations
import gzip
import json
import os
import random
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import monitor_power
from verbs import VERBS


# COM port number varies by physical USB port/hub, so the board is located by
# VID:PID rather than a fixed port. CLAUDE_LCD_PORT still overrides both, for
# manual pinning or troubleshooting.
KNOWN_VID_PIDS = {
    (0x2341, 0x0043),  # genuine Arduino Uno (ATmega16u2)
    (0x1A86, 0x7523),  # CH340 (Nano clones)
}
BAUD = 9600
# Suppress the brief Windows console flash that subprocess otherwise creates
# for every tasklist / npx invocation.
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000) if os.name == "nt" else 0
STATE_FILE = Path(tempfile.gettempdir()) / "claude_lcd_state.txt"
PID_FILE = Path(tempfile.gettempdir()) / "claude_lcd_daemon.pid"
LOG_FILE = Path(tempfile.gettempdir()) / "claude_lcd_daemon.log"
LOG_FILE_OLD = LOG_FILE.with_name(LOG_FILE.name + ".old")
LOG_MAX_BYTES = 2 * 1024 * 1024  # rotate past this so the log can't grow unbounded
# Touch this file to make the daemon exit cleanly (port closed in finally).
# Force-killing the process instead can wedge the CH340's open handle so
# badly that every later open fails until the device is physically replugged.
EXIT_FILE = Path(tempfile.gettempdir()) / "claude_lcd_daemon.exit"
SESSIONS_DIR = Path.home() / ".claude" / "sessions"
POLL_SECONDS = 0.1
RECONNECT_SECONDS = 2.0                # device-scan cadence while disconnected
IDLE_EXIT_SECONDS = 60 * 60 * 6        # 6 hours of inactivity → exit
QUOTA_REFRESH_SECONDS = 10             # quota poll cadence in all states
ONLINE_CHECK_SECONDS = 5               # scan sessions dir at this cadence
SCREENSAVER_AFTER_SECONDS = 5 * 60     # IDLE this long → switch LCD to clock
VERB_ROTATE_SECONDS = 20               # rotate working verb this often


def _serial_safe(text: str, max_len: int = 40) -> str:
    """Strip CR/LF from text that will be embedded in a raw serial line.
    The firmware's command reader splits on '\\n'/'\\r', so any untrusted
    text carrying one -- e.g. a city name from a third-party geocoding API
    -- could otherwise inject an extra command line."""
    return text.replace("\r", " ").replace("\n", " ")[:max_len]


def log(msg: str) -> None:
    try:
        try:
            # Single-backup rotation: keep the log from growing unbounded
            # over weeks of always-on autostart use without pulling in
            # logging.handlers for what's otherwise a plain append-only file.
            if LOG_FILE.stat().st_size > LOG_MAX_BYTES:
                LOG_FILE.replace(LOG_FILE_OLD)
        except FileNotFoundError:
            pass
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def pid_alive(pid: int) -> bool:
    if os.name != "nt":
        # POSIX: signal 0 probes existence without touching the process.
        try:
            os.kill(pid, 0)
            return True
        except PermissionError:
            return True     # exists, owned by someone else
        except OSError:
            return False
    try:
        out = subprocess.check_output(
            ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
            stderr=subprocess.DEVNULL,
            text=True,
            creationflags=CREATE_NO_WINDOW,
        )
        return f'"{pid}"' in out
    except Exception:
        return False


def already_running() -> bool:
    if not PID_FILE.exists():
        return False
    try:
        pid = int(PID_FILE.read_text().strip())
    except (ValueError, OSError):
        return False
    if pid == os.getpid():
        return False
    return pid_alive(pid)


def write_pid() -> None:
    PID_FILE.write_text(str(os.getpid()), encoding="ascii")


def find_port() -> "str | None":
    override = os.environ.get("CLAUDE_LCD_PORT")
    if override:
        return override
    from serial.tools import list_ports
    for p in list_ports.comports():
        if (p.vid, p.pid) in KNOWN_VID_PIDS:
            return p.device
    return None


def open_serial():
    """Open the display's port, or return None when the device isn't attached."""
    import serial
    port = find_port()
    if port is None:
        return None
    s = serial.Serial()
    s.port = port
    s.baudrate = BAUD
    s.timeout = 0.5
    s.write_timeout = 0.5
    s.dtr = False
    s.rts = False
    s.open()
    log(f"opened {port}")
    return s


# --- plan usage (OAuth API) --------------------------------------------------

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USAGE_HEADERS = {
    "anthropic-beta": "oauth-2025-04-20",
    "anthropic-version": "2023-06-01",
    "User-Agent": "claude-status-lcd/1.0",
}
CREDS_PATH = Path.home() / ".claude" / ".credentials.json"

_usage_thread: "threading.Thread | None" = None
_usage_lock = threading.Lock()
_usage_pending: "dict | None" = None
_usage_pending_at: float = 0.0

# Anthropic rate-limits this endpoint. On 429 we apply an exponential
# cooldown so the daemon stops hammering — starts at 60 s and doubles each
# consecutive 429, capped at 30 minutes. A single successful fetch resets
# both `_usage_skip_until` (so polling resumes immediately) and
# `_usage_next_backoff` (so a future single 429 starts fresh at 60 s).
_USAGE_BACKOFF_MIN = 60.0
_USAGE_BACKOFF_MAX = 1800.0
_usage_skip_until:   float = 0.0
_usage_next_backoff: float = _USAGE_BACKOFF_MIN


def _read_oauth_token() -> "str | None":
    try:
        with CREDS_PATH.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        log(f"creds read failed: {e}")
        return None
    tok = (data.get("claudeAiOauth") or {}).get("accessToken")
    if not tok:
        log("creds: no claudeAiOauth.accessToken")
    return tok


def fetch_usage_blocking() -> "dict | None":
    global _usage_skip_until, _usage_next_backoff
    token = _read_oauth_token()
    if not token:
        return None
    req = urllib.request.Request(USAGE_URL, headers={
        **USAGE_HEADERS,
        "Authorization": f"Bearer {token}",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", "ignore")
        _usage_skip_until = 0.0
        _usage_next_backoff = _USAGE_BACKOFF_MIN
        return json.loads(body)
    except urllib.error.HTTPError as e:
        log(f"usage HTTP {e.code}")
        if e.code == 429:
            cool = _usage_next_backoff
            _usage_skip_until = time.time() + cool
            _usage_next_backoff = min(cool * 2, _USAGE_BACKOFF_MAX)
            log(f"usage cooldown {int(cool)}s")
    except urllib.error.URLError as e:
        log(f"usage URL error: {e.reason}")
    except Exception as e:
        log(f"usage fetch error: {e}")
    return None


def _usage_worker() -> None:
    global _usage_pending, _usage_pending_at
    data = fetch_usage_blocking()
    with _usage_lock:
        _usage_pending = data
        _usage_pending_at = time.time()


def usage_kick() -> None:
    """Spawn the background usage-fetch thread if no fetch is in-flight and we
    aren't currently in a 429 cooldown window."""
    global _usage_thread
    if _usage_thread is not None and _usage_thread.is_alive():
        return
    if time.time() < _usage_skip_until:
        return
    _usage_thread = threading.Thread(
        target=_usage_worker, name="claude-usage", daemon=True
    )
    _usage_thread.start()


def usage_poll() -> "dict | None":
    """Return the latest fetched usage dict once, then None until the next fetch."""
    global _usage_pending, _usage_pending_at
    with _usage_lock:
        if _usage_pending_at == 0.0:
            return None
        data = _usage_pending
        _usage_pending = None
        _usage_pending_at = 0.0
        return data


def _pct(block: dict) -> "int | None":
    if not isinstance(block, dict):
        return None
    for k in ("utilization", "percent", "percentage"):
        v = block.get(k)
        if v is None:
            continue
        try:
            return int(round(float(v)))
        except (TypeError, ValueError):
            continue
    return None


def _resets_at(block: dict) -> str:
    if not isinstance(block, dict):
        return ""
    for k in ("resets_at", "reset_at", "resetAt"):
        v = block.get(k)
        if v:
            return str(v)
    return ""


def _format_relative_reset(resets_at: str) -> str:
    """Live countdown: seconds-precise under 10 min, minute-precise otherwise."""
    if not resets_at:
        return ""
    try:
        dt = datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
    except Exception:
        return ""
    secs = int((dt - datetime.now(timezone.utc)).total_seconds())
    if secs <= 0:
        return "now"
    h, rem = divmod(secs, 3600)
    m, s   = divmod(rem, 60)
    if h >= 1:
        return f"{h}h{m:02d}m"
    if m >= 10:
        return f"{m}m"
    if m >= 1:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def _format_hm_countdown(resets_at: str) -> str:
    """'HH:MM' countdown to resets_at, for the 5h S_LIMIT display. '00:00' if
    unknown or already past."""
    if not resets_at:
        return "00:00"
    try:
        dt = datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
    except Exception:
        return "00:00"
    secs = max(0, int((dt - datetime.now(timezone.utc)).total_seconds()))
    h, rem = divmod(secs, 3600)
    m, _ = divmod(rem, 60)
    return f"{h:02d}:{m:02d}"


def _format_dhm_countdown(resets_at: str) -> str:
    """'Xd:HH:MM' countdown to resets_at, for the weekly S_LIMIT display.
    Days is a single digit -- the 7-day window is never more than a few days
    from reset -- so no zero-padding there. '0d:00:00' if unknown or past."""
    if not resets_at:
        return "0d:00:00"
    try:
        dt = datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
    except Exception:
        return "0d:00:00"
    secs = max(0, int((dt - datetime.now(timezone.utc)).total_seconds()))
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    return f"{d}d:{h:02d}:{m:02d}"


def format_quota_line(usage: dict) -> str:
    """20-char-max LCD line for the 5-hour session.

    The 7-day weekly limit isn't shown on row 3 — it's lower-priority than the
    5-hour limit and the audio threshold alerts (B:3 / B:5) still scream when
    7d is approaching its caps.
    """
    five = usage.get("five_hour") or {}
    sp = _pct(five)
    sr = _format_relative_reset(_resets_at(five))
    sess = f"5h:{sp}%" if sp is not None else "5h:--"
    if sr:
        sess = f"{sess} in {sr}"
    return sess[:20]


# --- weather (Open-Meteo, no auth, free) ------------------------------------
WEATHER_REFRESH_SECONDS = 300       # 5 min cadence
WEATHER_THREAD_TIMEOUT  = 30        # abandon a hung fetch thread after this
WEATHER_STALE_SECONDS   = 4 * 3600  # 4 h — drop the line entirely past this

# Default location if no config.json sits next to this file. The installer
# normally writes config.json; dev runs (script invoked directly from the
# source tree) fall back to this default unless the user drops a config.json
# of their own.
_weather_location: "dict | None" = {
    "city": "Kyiv",
    "latitude": 50.45,
    "longitude": 30.52,
}
CONFIG_PATH = Path(__file__).resolve().parent / "config.json"

_weather_thread: "threading.Thread | None" = None
_weather_thread_started: float = 0.0
_weather_lock = threading.Lock()
_weather_temp_c: "int | None" = None
_weather_fetched_at: float = 0.0

# --- air raid alerts (keyless community feeds) -------------------------------
# Primary: ubilling.net.ua aggregates the official ukrainealarm feed into a
# per-oblast {alertnow, changed} map — no API key, refreshed server-side about
# every 30 s. Fallback: siren.pp.ua mirrors api.ukrainealarm.com (also keyless,
# district-level, always gzip-compressed). alerts.in.ua was dropped because its
# API-token request went unanswered.
ALERT_REFRESH_SECONDS = 60       # ubilling 429s on bursts; both cache ~30 s anyway
ALERT_URL_PRIMARY  = "https://ubilling.net.ua/aerialalerts/"
ALERT_URL_FALLBACK = "https://siren.pp.ua/api/v3/alerts"

_CITY_UA_MAP: "dict[str, str]" = {
    "Kyiv": "Київ", "Lviv": "Львів", "Kharkiv": "Харків",
    "Odessa": "Одеса", "Dnipro": "Дніпро", "Zaporizhzhia": "Запоріжжя",
    "Mykolaiv": "Миколаїв", "Kherson": "Херсон", "Poltava": "Полтава",
    "Sumy": "Суми", "Chernihiv": "Чернігів", "Vinnytsia": "Вінниця",
    "Zhytomyr": "Житомир", "Rivne": "Рівне", "Lutsk": "Луцьк",
    "Uzhhorod": "Ужгород", "Ivano-Frankivsk": "Івано-Франківськ",
    "Ternopil": "Тернопіль", "Khmelnytskyi": "Хмельницький",
    "Cherkasy": "Черкаси", "Kropyvnytskyi": "Кропивницький",
}

_alert_thread: "threading.Thread | None" = None
_alert_lock = threading.Lock()
_alert_active: "bool | None" = None   # None = not polled yet


_brightness: int = 20   # startup backlight %, overridden by config.json
_sound_enabled: bool = True
_allclear_enabled: bool = True


def load_config() -> None:
    """Load user-configurable settings from config.json. Missing file is fine."""
    global _weather_location, _brightness, _sound_enabled, _allclear_enabled
    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        return
    except Exception as e:
        log(f"config read error: {e}")
        return

    if "brightness" in cfg:
        try:
            _brightness = max(0, min(100, int(cfg["brightness"])))
            log(f"config: brightness={_brightness}%")
        except (TypeError, ValueError):
            pass

    prefs = cfg.get("prefs") or {}
    if "sound" in prefs:
        _sound_enabled = bool(prefs["sound"])
        log(f"config: alert sound={'on' if _sound_enabled else 'off'}")
    if "allclear" in prefs:
        _allclear_enabled = bool(prefs["allclear"])
        log(f"config: allclear sound={'on' if _allclear_enabled else 'off'}")

    if "weather" not in cfg:
        return
    w = cfg["weather"]
    if w is None:
        _weather_location = None
        log("config: weather disabled")
        return
    if not isinstance(w, dict):
        log(f"config: ignored weather (not a dict): {w!r}")
        return
    try:
        # city/alert_region round-trip through config.json from a third-party
        # geocoding API response (see setup.ps1's map wizard) and get embedded
        # directly into raw serial lines (K:/A: below) -- strip CR/LF so a
        # crafted or malformed API response can never inject an extra command
        # line into the newline-delimited protocol the firmware parses.
        _weather_location = {
            "city":         _serial_safe(str(w.get("city") or "?")),
            "latitude":     float(w["latitude"]),
            "longitude":    float(w["longitude"]),
            "country_code": str(w.get("country_code") or "").lower(),
            "alert_region": _serial_safe(str(w.get("alert_region") or "")),
        }
        log(f"config: weather -> {_weather_location['city']} "
            f"({_weather_location['latitude']}, {_weather_location['longitude']})"
            f" cc={_weather_location['country_code'] or '?'}")
    except (KeyError, TypeError, ValueError) as e:
        log(f"config: invalid weather entry, keeping default: {e}")


def _weather_url() -> "str | None":
    if not _weather_location:
        return None
    return (
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={_weather_location['latitude']}"
        f"&longitude={_weather_location['longitude']}"
        "&current=temperature_2m"
    )


def _weather_worker() -> None:
    global _weather_temp_c, _weather_fetched_at
    url = _weather_url()
    if url is None:
        return
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "claude-status-lcd/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
        temp = (data.get("current") or {}).get("temperature_2m")
        if temp is None:
            return
        with _weather_lock:
            _weather_temp_c = int(round(float(temp)))
            _weather_fetched_at = time.time()
        city = (_weather_location or {}).get("city", "?")
        log(f"weather: {city} {_weather_temp_c}C")
    except Exception as e:
        log(f"weather fetch error: {e}")


def weather_kick() -> None:
    global _weather_thread, _weather_thread_started
    if _weather_thread is not None and _weather_thread.is_alive():
        # Abandon a thread that has been running longer than the hard timeout
        # (e.g. urllib stalled despite the per-request timeout).
        if time.time() - _weather_thread_started < WEATHER_THREAD_TIMEOUT:
            return
        log("weather: previous fetch thread timed out, spawning new one")
    if _weather_url() is None:
        return  # disabled by config — don't even spawn the thread
    _weather_thread = threading.Thread(
        target=_weather_worker, name="claude-weather", daemon=True
    )
    _weather_thread_started = time.time()
    _weather_thread.start()


def current_temp() -> "int | None":
    with _weather_lock:
        if _weather_fetched_at == 0.0:
            return None
        if time.time() - _weather_fetched_at > WEATHER_STALE_SECONDS:
            return None
        return _weather_temp_c


def _fetch_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "claude-status-lcd/1.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read()
    if raw[:2] == b"\x1f\x8b":       # siren.pp.ua gzips regardless of headers
        raw = gzip.decompress(raw)
    return json.loads(raw)


def _alert_region() -> str:
    """Ukrainian region name to match against the feeds. Prefer the oblast
    stored by the map picker; fall back to the static English→Ukrainian city
    map for configs that predate it (and for the built-in Kyiv default)."""
    loc = _weather_location or {}
    region = loc.get("alert_region", "")
    if not region:
        city_en = loc.get("city", "")
        region = _CITY_UA_MAP.get(city_en, city_en)
    return region


def _region_matches(region: str, name: str) -> bool:
    """Exact match, plus the 'м. Київ' form both feeds use for cities with
    special status. Deliberately not a substring match so an oblast-only
    alert doesn't ring the city (and vice versa)."""
    return name == region or name == f"м. {region}"


def _region_matches_loose(region: str, name: str) -> bool:
    """Fallback-feed matching. siren.pp.ua names regions by hromada/district
    ('м. Харків та Харківська територіальна громада', 'Харківський район'),
    so for an oblast we match on the adjective stem: 'Харківська область' →
    'Харківськ', which appears in every inflected form. City regions match on
    the 'м. <city>' prefix."""
    if _region_matches(region, name):
        return True
    if region.endswith(" область"):
        stem = region[: -len(" область")].rstrip("аий")
        return stem in name
    return name.startswith(f"м. {region}")


def _poll_ubilling(region: str) -> "bool | None":
    states = _fetch_json(ALERT_URL_PRIMARY).get("states") or {}
    if not states:
        raise ValueError("empty states map")
    return any(
        bool(v.get("alertnow")) and _region_matches(region, k)
        for k, v in states.items()
    )


def _poll_siren(region: str) -> "bool | None":
    data = _fetch_json(ALERT_URL_FALLBACK)
    return any(
        _region_matches_loose(region, str(r.get("regionName", "")))
        and any(a.get("type") == "AIR" for a in (r.get("activeAlerts") or []))
        for r in data
    )


def _alert_worker() -> None:
    global _alert_active
    region = _alert_region()
    if not region:
        return
    # Query both sources every poll and OR the results rather than treating
    # the second as a failover-only path: the two aggregators cover the
    # official feed with different lag/granularity, and for a siren that's
    # supposed to warn you, a missed real alert is worse than an extra HTTP
    # call. Confirmed 2026-07-28: ubilling reported м. Київ clear (stale
    # since ~21:30) while siren.pp.ua correctly showed it active — an OR
    # catches this, a failover-only fallback does not.
    results: "dict[str, bool | None]" = {}
    for name, poll in (("ubilling", _poll_ubilling), ("siren.pp.ua", _poll_siren)):
        try:
            results[name] = poll(region)
        except Exception as e:
            log(f"alert fetch failed [{name}]: {e}")
            results[name] = None
    values = [v for v in results.values() if v is not None]
    if not values:
        log("alert poll: both sources failed, keeping previous state")
        return
    active = any(values)
    with _alert_lock:
        _alert_active = active
    detail = ", ".join(f"{k}={'?' if v is None else v}" for k, v in results.items())
    log(f"alert poll: {'ACTIVE' if active else 'clear'} ({region}) [{detail}]")


def alert_kick() -> None:
    global _alert_thread
    # Alerts are Ukraine-specific. New configs store country_code from the
    # map picker; old configs without it fall back to the city-name map.
    loc = _weather_location or {}
    cc = loc.get("country_code", "")
    if cc:
        if cc != "ua":
            return
    else:
        if loc.get("city", "") not in _CITY_UA_MAP:
            return
    if _alert_thread is not None and _alert_thread.is_alive():
        return
    _alert_thread = threading.Thread(
        target=_alert_worker, name="claude-alert", daemon=True
    )
    _alert_thread.start()


# --- threshold alerts (audible) ---------------------------------------------
# Pattern IDs are kept in lock-step with claude_status.ino's PATTERN_* table.
PATTERN_5H_WARN    = 2
PATTERN_7D_WARN    = 3
PATTERN_5H_URGENT  = 4
PATTERN_7D_URGENT  = 5
PATTERN_ALERT_OVER = 8

# Last-seen percentages. None = no baseline yet (first fetch after daemon
# start), so we never chirp on cold-start alone — only on a real upward
# crossing observed between two consecutive fetches.
_prev_five_pct:  "int | None" = None
_prev_seven_pct: "int | None" = None


def quota_alert_commands(usage: dict) -> "list[bytes]":
    """Return any `U:`/`B:<id>\\n` payloads to push to the Arduino because a
    usage line just crossed 75 % or 90 % upward. The U: toast is sent first
    so the screen already explains itself by the time the beep (queued right
    after) draws attention -- otherwise a threshold beep landing during the
    idle screensaver has no visible cause. Updates the prev-% trackers as a
    side effect. Returns an empty list when nothing crossed.
    """
    global _prev_five_pct, _prev_seven_pct
    cmds: "list[bytes]" = []

    five = _pct(usage.get("five_hour") or {})
    if five is not None:
        if _prev_five_pct is not None:
            if _prev_five_pct < 90 <= five:
                cmds.append(b"U:5h 90% reached\n")
                cmds.append(f"B:{PATTERN_5H_URGENT}\n".encode("ascii"))
                log(f"alert: 5h crossed 90% ({_prev_five_pct}→{five})")
            elif _prev_five_pct < 75 <= five:
                cmds.append(b"U:5h 75% reached\n")
                cmds.append(f"B:{PATTERN_5H_WARN}\n".encode("ascii"))
                log(f"alert: 5h crossed 75% ({_prev_five_pct}→{five})")
        _prev_five_pct = five

    seven = _pct(usage.get("seven_day") or {})
    if seven is not None:
        if _prev_seven_pct is not None:
            if _prev_seven_pct < 90 <= seven:
                cmds.append(b"U:Weekly 90% reached\n")
                cmds.append(f"B:{PATTERN_7D_URGENT}\n".encode("ascii"))
                log(f"alert: 7d crossed 90% ({_prev_seven_pct}→{seven})")
            elif _prev_seven_pct < 75 <= seven:
                cmds.append(b"U:Weekly 75% reached\n")
                cmds.append(f"B:{PATTERN_7D_WARN}\n".encode("ascii"))
                log(f"alert: 7d crossed 75% ({_prev_seven_pct}→{seven})")
        _prev_seven_pct = seven

    return cmds


# --- session liveness --------------------------------------------------------


def claude_online() -> bool:
    """True iff at least one session file under ~/.claude/sessions/ has a
    live PID."""
    if not SESSIONS_DIR.exists():
        return False
    for f in SESSIONS_DIR.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            pid = int(data.get("pid") or 0)
        except Exception:
            continue
        if pid > 0 and pid_alive(pid):
            return True
    return False


# -----------------------------------------------------------------------------


def main() -> int:
    if already_running():
        log(f"another daemon (pid in {PID_FILE}) is alive; exiting")
        return 0
    write_pid()
    try:
        EXIT_FILE.unlink()   # stale request from a previous run must not kill us
    except OSError:
        pass
    log(f"daemon start pid={os.getpid()}")

    load_config()
    monitor_power.start_listener()

    # The device may not be attached yet (daemon can start at login, before
    # the display is plugged in). Instead of exiting, poll for it and connect
    # whenever it appears; ser_write reconnects on demand after unplugs.
    ser = None
    last_conn_try = 0.0
    conn_wait_logged = False

    def ensure_serial() -> bool:
        """Connect if not connected. Rate-limited to RECONNECT_SECONDS so the
        disconnected path stays cheap and the log stays quiet."""
        nonlocal ser, last_conn_try, conn_wait_logged
        if ser is not None:
            return True
        now_c = time.time()
        if now_c - last_conn_try < RECONNECT_SECONDS:
            return False
        last_conn_try = now_c
        try:
            ser = open_serial()
        except Exception as e:
            if not conn_wait_logged:
                log(f"serial open failed: {e}; retrying every {RECONNECT_SECONDS:g}s")
                conn_wait_logged = True
            ser = None
            return False
        if ser is None:
            if not conn_wait_logged:
                log("device not attached; waiting for it to appear")
                conn_wait_logged = True
            return False
        conn_wait_logged = False
        # Opening the port pulses DTR, which reboots the board. Give the
        # bootloader time to run, then push the basics. The READY handler
        # re-sends these on the board's own announcement — harmless overlap
        # that also covers adapters that don't reset on open.
        time.sleep(2.0)
        try:
            ser.write(b"H:\n")
            ser.write(datetime.now().strftime("R:%Y-%m-%d %H:%M:%S\n").encode("ascii"))
            ser.write(f"L:{_brightness}\n".encode("ascii"))
            log(f"startup: brightness={_brightness}%")
        except Exception:
            pass
        return True

    def drop_serial(reason: str) -> None:
        nonlocal ser
        log(f"{reason}; reconnecting")
        try:
            ser.close()
        except Exception:
            pass
        ser = None

    def ser_write(payload: bytes) -> bool:
        """Write to serial, (re)connecting as needed. Returns True on success."""
        nonlocal ser
        if not ensure_serial():
            return False
        try:
            ser.write(payload)
            return True
        except Exception as e:
            drop_serial(f"write failed: {e}")
            if not ensure_serial():
                return False
            try:
                ser.write(payload)
                return True
            except Exception as ee:
                drop_serial(f"rewrite failed: {ee}")
                return False

    ensure_serial()
    last_mtime = 0.0
    last_change = time.time()
    current_state: "str | None" = None  # 'I', 'W', 'P', 'X', 'B', 'O'
    last_quota_kick = 0.0
    last_online_check = 0.0
    online_known: "bool | None" = None
    rx_buf = b""
    monitor_on = True                # last value forwarded to Arduino (M1=on, M0=off)
    idle_since: "float | None" = None
    screensaver_active = False
    last_clock_payload = ""
    last_weather_kick = 0.0
    last_alert_kick = 0.0
    prev_alert_active = False
    payg_no_token_count = 0   # consecutive quota-poll cycles with no OAuth token found
    payg_notified = False     # one-shot: told the user usage limits aren't available
    cached_five: "dict" = {}
    cached_seven: "dict" = {}
    last_quota_line_tick = 0.0
    last_quota_line = ""          # last Q: string sent — skip write if unchanged
    limit_active = False          # showing the S_LIMIT display right now
    last_limit_tick = 0.0
    last_limit_text = ""          # last E: payload sent — skip write if unchanged
    last_gauge_pct: "int | None" = None  # last G: value — skip write if unchanged
    last_verb_tick = 0.0          # last verb rotation while WORKING

    def send_clock(now_dt: datetime) -> None:
        """Push the multi-row screensaver payload as K:time|date|temp|usage.
        Re-sends only when the rendered string actually changes (covers
        minute roll-over, weather refresh, and usage pct/countdown ticks).
        The usage field is blank for pay-as-you-go accounts (no cached_five
        data), which the Arduino side renders as an empty row rather than a
        stale "== Claude Code ==" header."""
        nonlocal last_clock_payload
        hhmm = now_dt.strftime("%H:%M")
        date_str = now_dt.strftime("%a, %b %d")
        temp = current_temp()
        # 0xDF is the HD44780 native ° glyph; we send raw via latin-1.
        if temp is not None and _weather_location:
            temp_str = f"{_weather_location['city']} {temp}\xdfC"
        else:
            temp_str = ""
        usage_pct = _pct(cached_five) if cached_five else None
        if usage_pct is not None:
            countdown = _format_hm_countdown(_resets_at(cached_five))
            usage_str = f"{usage_pct}% resets in {countdown}"[:20]
        else:
            usage_str = ""
        payload = f"{hhmm}|{date_str}|{temp_str}|{usage_str}"
        if payload == last_clock_payload:
            return
        if ser_write(f"K:{payload}\n".encode("latin-1", "ignore")):
            last_clock_payload = payload
            # log with the printable ° in place of the raw byte
            log(f"clock: {hhmm} | {date_str} | "
                f"{temp_str.replace(chr(0xdf), chr(0xb0))} | {usage_str}")

    def enter_idle_tracking() -> None:
        nonlocal idle_since, screensaver_active, last_clock_payload
        idle_since = time.time()
        screensaver_active = False
        last_clock_payload = ""

    def leave_idle_tracking() -> None:
        nonlocal idle_since, screensaver_active, last_clock_payload
        idle_since = None
        screensaver_active = False
        last_clock_payload = ""

    try:
        while True:
            now = time.time()

            # 0a. Keep scanning for the device while disconnected (rate-limited
            # inside). Writes also reconnect on demand, but quiet states like
            # OFFLINE never write, so don't rely on that alone.
            ensure_serial()

            # 0. Monitor power events
            evt = monitor_power.take_event()
            if evt == "off":
                if monitor_on:
                    if ser_write(b"M0\n"):
                        monitor_on = False
                        log("→ monitor OFF")
            elif evt in ("on", "dim"):
                if not monitor_on:
                    if ser_write(b"M1\n"):
                        monitor_on = True
                        log(f"→ monitor ON ({evt})")
            elif evt == "suspend":
                log("system suspend")
                # Pre-emptively blank: even if USB power persists briefly, we
                # don't want a stale frame sitting on the LCD as the host goes
                # down. Arduino will lose power shortly anyway.
                if monitor_on:
                    ser_write(b"M0\n")
                    monitor_on = False
            elif evt == "resume":
                log("system resume → restoring monitor on")
                # Don't wait for a separate Windows monitor-on event: when
                # the PC just woke up, the user wants their LCD back. If the
                # monitors actually stayed off, the next display-state event
                # will re-blank us. The Arduino reboot path (READY below)
                # also restores monitor_on for the case where USB power
                # dropped.
                if not monitor_on:
                    if ser_write(b"M1\n"):
                        monitor_on = True

            # 1. Hook-driven state file changes
            try:
                mtime = STATE_FILE.stat().st_mtime
            except FileNotFoundError:
                mtime = 0.0

            if mtime > last_mtime:
                last_mtime = mtime
                last_change = now
                try:
                    payload = STATE_FILE.read_text(encoding="ascii", errors="ignore")
                except Exception:
                    payload = ""
                lines = [ln.strip() for ln in payload.splitlines() if ln.strip()]
                log(f"write: {lines}")
                prev_state = current_state
                for ln in lines:
                    if ln[0] == "C":
                        # PostToolUse fired: a tool completed, so a pending
                        # permission prompt was necessarily answered. Only
                        # meaningful when the LCD is stuck on PERMISSION —
                        # flip it back to WORKING (project header travels in
                        # the payload). Any other state: no-op. Never
                        # forwarded to the Arduino, which has no C command.
                        if current_state == "X":
                            current_state = "W"
                            if not limit_active:
                                proj = ln[2:] if ln[1:2] == ":" else ""
                                verb = random.choice(VERBS) if VERBS else ""
                                ser_write(f"H:{proj}\n".encode("ascii", "ignore"))
                                ser_write((f"W:{verb}...\n" if verb else "W\n")
                                          .encode("ascii", "ignore"))
                                log("permission answered (PostToolUse) → WORKING")
                        continue
                    if ln[0] in "IWPXBO":
                        current_state = ln[0]
                    # While a usage window is fully spent, the S_LIMIT screen
                    # owns the display -- hook-driven commands (Claude Code
                    # keeps firing UserPromptSubmit/PreToolUse/Stop even while
                    # rate-limited) would otherwise flip the Arduino back to
                    # WORKING/IDLE/etc. with a stale 100% gauge. Still track
                    # current_state above so behavior resumes correctly once
                    # the window resets, just don't forward to the device.
                    if limit_active:
                        continue
                    # A failed write means the device is unplugged; state is
                    # still tracked and replayed by the READY resync when the
                    # board comes back, so just carry on.
                    ser_write((ln + "\n").encode("ascii", "ignore"))
                # Idle-tracking transitions
                if current_state == "I" and prev_state != "I":
                    enter_idle_tracking()
                    last_quota_line = ""
                    last_gauge_pct = None
                elif current_state != "I" and prev_state == "I":
                    leave_idle_tracking()
                    last_quota_line = ""
                    last_gauge_pct = None
                # Verb rotation: reset clock when entering WORKING so first
                # rotation happens VERB_ROTATE_SECONDS after the hook fires.
                if current_state == "W" and prev_state != "W":
                    last_verb_tick = now

            # 2. Online/offline detection
            if now - last_online_check > ONLINE_CHECK_SECONDS:
                last_online_check = now
                online_now = claude_online()
                if online_known is None:
                    online_known = online_now
                    # First scan after daemon start: only push OFFLINE if
                    # Claude isn't running. If a session is live, we leave
                    # current_state None so the pre-host send_clock branch
                    # in the main loop keeps the LCD in S_CLOCK with fresh
                    # date/time/temp until a real hook fires.
                    if not online_now:
                        if ser_write(b"O\n"):
                            current_state = "O"
                            leave_idle_tracking()
                            log("→ OFFLINE (no session at boot)")
                elif online_now != online_known:
                    online_known = online_now
                    # Same reasoning as the hook-forwarding block above: while
                    # S_LIMIT owns the display, don't let an online/offline
                    # flip kick the Arduino back to O/I. Track current_state
                    # so things resume correctly once the window resets.
                    if not online_now:
                        current_state = "O"
                        if not limit_active:
                            if ser_write(b"O\n"):
                                leave_idle_tracking()
                                log("→ OFFLINE (session ended)")
                    else:
                        current_state = "I"
                        if not limit_active:
                            # session came back; flip to IDLE so the next hook
                            # can set the real state (quota refresh kicks in too).
                            if ser_write(b"I\n"):
                                enter_idle_tracking()
                                log("→ ONLINE (session started)")

            # 3a. Screensaver: after SCREENSAVER_AFTER_SECONDS in IDLE, show clock.
            # Suppressed while S_LIMIT owns the display -- same reasoning as
            # the hook-forwarding block above.
            if (not limit_active and current_state == "I" and idle_since is not None
                    and now - idle_since >= SCREENSAVER_AFTER_SECONDS):
                if not screensaver_active:
                    screensaver_active = True
                    last_clock_payload = ""
                    log("→ screensaver (idle 5 min)")
                send_clock(datetime.now())
            elif not limit_active and current_state is None:
                # Pre-host display — keep refreshing the screensaver until
                # the first hook lands. send_clock dedupes by payload so
                # this is a no-op until the minute rolls or weather lands.
                send_clock(datetime.now())

            # 3a'. Weather refresh — fire on cold-start and every 10 min after.
            if now - last_weather_kick > WEATHER_REFRESH_SECONDS:
                last_weather_kick = now
                weather_kick()

            # 3b. Plan-usage refresh — uniform 10 s in all states so threshold
            # crossings and the progress bar stay current regardless of whether
            # Claude is actively working or idle.
            if now - last_quota_kick > QUOTA_REFRESH_SECONDS:
                last_quota_kick = now
                usage_kick()
                # Pay-as-you-go / API-key accounts have no OAuth session, so
                # this endpoint has nothing to report for them -- not an
                # error, just a different plan with no 5h/7d limit concept.
                # Once that's been true for a while (long enough to rule out
                # a fresh install where ~/.claude/.credentials.json just
                # hasn't been written yet), say so once rather than leaving
                # the missing usage line unexplained forever.
                if not payg_notified:
                    if _read_oauth_token() is None:
                        payg_no_token_count += 1
                        if payg_no_token_count >= 3:
                            payg_notified = True
                            ser_write(b"U:Pay-as-you-go|no usage data shown\n")
                            log("usage: no OAuth token found -- pay-as-you-go, limit monitoring disabled")
                    else:
                        payg_no_token_count = 0

            # 3c. Air raid alert polling (keyless community feeds, Ukraine only)
            if now - last_alert_kick > ALERT_REFRESH_SECONDS:
                last_alert_kick = now
                alert_kick()

            # 3d. Verb rotation — pick a new spinner verb every 20 s while WORKING
            if (current_state == "W" and not limit_active
                    and now - last_verb_tick > VERB_ROTATE_SECONDS):
                last_verb_tick = now
                verb = random.choice(VERBS)
                ser_write(f"W:{verb}...\n".encode("ascii", "ignore"))
                log(f"verb: {verb}...")

            with _alert_lock:
                current_alert = _alert_active
            if current_alert is not None:
                if current_alert:
                    # Re-send A: on every poll — firmware plays siren only on the
                    # first arrival; subsequent ones silently extend the keepalive.
                    city = (_weather_location or {}).get("city", "AREA").upper()
                    ser_write(f"A:{city}\n".encode("ascii", "ignore"))
                    if not prev_alert_active:
                        log(f"alert: AIR RAID ALERT in {city}")
                        prev_alert_active = True
                elif prev_alert_active:
                    ser_write(b"V\n")
                    log("alert: all clear")
                    prev_alert_active = False

            usage_data = usage_poll()
            if usage_data:
                # Audible alerts first — they should fire regardless of what
                # the LCD is currently displaying.
                for cmd in quota_alert_commands(usage_data):
                    ser_write(cmd)
                # Gauge percentage — sent in all states so the WORKING
                # progress bar stays current while Claude is active.
                five = (usage_data.get("five_hour") or {})
                cached_five = five
                cached_seven = (usage_data.get("seven_day") or {})
                pct = _pct(five)
                if pct is not None and pct != last_gauge_pct:
                    # Only latch pct as "sent" if the write actually went out.
                    # Right after a fresh install the daemon is often still
                    # racing to open the just-flashed port when this first
                    # fetch resolves -- a dropped write must not be treated
                    # as delivered, or the (usually unchanged) percentage on
                    # every later poll would never win the dedup check above,
                    # leaving the gauge blank for the rest of the session.
                    if ser_write(f"G:{pct}\n".encode("ascii")):
                        last_gauge_pct = pct
                last_quota_line_tick = 0.0  # force immediate Q: redraw on new data
                last_limit_tick = 0.0       # force immediate E: redraw on new data

            # Q: line refresh — independent tick so countdown updates every
            # QUOTA_REFRESH_SECONDS even when no fresh API data has arrived.
            if (current_state == "I" and not screensaver_active
                    and cached_five
                    and now - last_quota_line_tick > QUOTA_REFRESH_SECONDS):
                last_quota_line_tick = now
                line = format_quota_line({"five_hour": cached_five})
                if line != last_quota_line:
                    # Same dropped-write concern as the gauge above: only
                    # latch once the write actually succeeds.
                    if ser_write((f"Q:{line}\n").encode("ascii", "ignore")):
                        last_quota_line = line
                        log(f"quota: {line}")

            # E: limit-reached display — takes over the screen for as long as
            # either usage window is fully spent, with a live countdown to
            # the reset. Weekly takes priority: if both are capped, a fresh
            # 5h window doesn't help while the week is still capped. Resent
            # every QUOTA_REFRESH_SECONDS (independent of whether the raw %
            # changed) purely so the countdown keeps ticking.
            five_pct_now  = _pct(cached_five)  if cached_five  else None
            seven_pct_now = _pct(cached_seven) if cached_seven else None
            limit_kind = None
            if seven_pct_now is not None and seven_pct_now >= 100:
                limit_kind = "7"
            elif five_pct_now is not None and five_pct_now >= 100:
                limit_kind = "5"

            if limit_kind and now - last_limit_tick > QUOTA_REFRESH_SECONDS:
                last_limit_tick = now
                if limit_kind == "7":
                    countdown = _format_dhm_countdown(_resets_at(cached_seven))
                    payload = f"E:Weekly limit reached|{countdown}\n"
                else:
                    countdown = _format_hm_countdown(_resets_at(cached_five))
                    payload = f"E:5h limit reached|{countdown}\n"
                if payload != last_limit_text:
                    if ser_write(payload.encode("ascii", "ignore")):
                        last_limit_text = payload
                        limit_active = True
                        log(f"limit: showing {payload.strip()}")
            elif not limit_kind and limit_active:
                limit_active = False
                last_limit_text = ""
                ser_write(f"B:{PATTERN_ALERT_OVER}\n".encode("ascii"))
                if ser_write(b"I\n"):
                    current_state = "I"
                    enter_idle_tracking()
                    last_quota_line = ""
                    last_gauge_pct = None
                log("limit: window reset, back to IDLE")

            # 4. Read anything the Arduino has to say (READY, SW:0/SW:1, ...)
            # A read failure means the device vanished mid-session — drop the
            # handle so ensure_serial starts scanning for its return.
            try:
                avail = ser.in_waiting if ser is not None else 0
                if avail:
                    rx_buf += ser.read(avail)
                while b"\n" in rx_buf:
                    line_b, rx_buf = rx_buf.split(b"\n", 1)
                    line_s = line_b.decode("ascii", "ignore").strip()
                    if not line_s:
                        continue
                    log(f"<< {line_s}")
                    if line_s == "READY":
                        # Arduino just (re)booted — daemon-start DTR reset,
                        # host resume, or a manual reset. Bring the LCD
                        # back to a useful frame immediately.
                        log("resync after READY")
                        monitor_on = True
                        ser_write(b"M1\n")
                        # Battery-backed RTC keeps the time across power
                        # loss, but we still nudge it to the host's clock
                        # in case NTP moved.
                        ser_write(datetime.now().strftime(
                            "R:%Y-%m-%d %H:%M:%S\n").encode("ascii"))
                        ser_write(f"L:{_brightness}\n".encode("ascii"))
                        # Always push a fresh K: so the device leaves the
                        # boot-only header and lands in S_CLOCK with date /
                        # time / weather right away — even if no hook has
                        # ever fired.
                        last_clock_payload = ""
                        send_clock(datetime.now())
                        # If we already know the host's state (resync after
                        # a mid-life reboot), replay it so the LCD ends up
                        # back where it was; the K: above is momentary in
                        # that case.
                        if current_state:
                            ser_write((current_state + "\n").encode("ascii"))
            except Exception as e:
                if ser is not None:
                    drop_serial(f"serial read failed: {e}")

            # 5a. Graceful shutdown request (see EXIT_FILE comment).
            if EXIT_FILE.exists():
                try:
                    EXIT_FILE.unlink()
                except OSError:
                    pass
                log("exit requested via exit file")
                return 0

            # 5. Idle timeout — but never while the display is attached: the
            # daemon is what keeps its clock/screensaver alive, and exiting
            # would force a DTR reboot on the next hook-driven respawn.
            if now - last_change > IDLE_EXIT_SECONDS and ser is None:
                log("idle timeout; exiting")
                return 0

            time.sleep(POLL_SECONDS)
    finally:
        try:
            if ser is not None:
                ser.close()
        except Exception: pass
        try: PID_FILE.unlink()
        except Exception: pass
        log("daemon stop")


if __name__ == "__main__":
    sys.exit(main())
