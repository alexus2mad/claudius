# Claude Code LCD Status — Installer

Hardware-side status display for Claude Code on Windows, Linux and macOS.
An Arduino Uno or
Nano (ATmega328P) with a 20×4 I²C LCD shows whether Claude is IDLE / WORKING /
WAITING FOR INPUT / OFFLINE, plus your real plan-usage bars: the 5-hour
session % and the 7-day weekly %, alternated on the bottom row during IDLE.

The percentages are the same numbers `claude.ai/settings/usage` shows. They
come from an undocumented OAuth endpoint authenticated with the access token
Claude Code itself stores in `~/.claude/.credentials.json` — no cookies, no
extra logins. Because the endpoint is unofficial it may change without
warning; the daemon logs failures and falls back to a blank usage line.

For users in Ukraine (detected from the setup-wizard location) the daemon
also cross-checks two public air-raid feeds — `ubilling.net.ua/aerialalerts`
and `siren.pp.ua`, both keyless — once a minute and drives a siren +
full-screen warning on the LCD while the configured oblast/city is under an
air-raid alert on either source. No API token is needed. Querying both
instead of only falling back on error matters in practice: the two
aggregators can disagree (observed 2026-07-28, one showed Kyiv city cleared
while the other still had it active), so the daemon treats an alert as
active if either source reports it.

The LCD also tracks the host's display state: it blanks together with the
PC monitors when they turn off for power saving (and on suspend), and
re-lights itself when they come back. On Windows this is event-driven via
power notifications; on macOS (CGDisplayIsAsleep) and Linux (X11 DPMS via
`xset`, or the GNOME/freedesktop ScreenSaver D-Bus interface on Wayland
GNOME) it's a 2-second poll. After 5 minutes of
continuous IDLE the LCD switches to a clock screensaver (time, date and
local temperature), refreshed once a minute, until Claude does something
again.

## What gets installed

| Component | Where |
|---|---|
| Python 3.11 + `pyserial` | system PATH (via winget if missing) |
| Daemon & hook scripts (`notify.py`, `hook_pretool.py`, `lcd_daemon.py`, `monitor_power.py`) | `%LOCALAPPDATA%\ClaudeStatus\app\` |
| Claude Code hooks (UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop) | `~/.claude/settings.json` (existing file is backed up) |
| `claude_status.hex` | flashed onto the Arduino |
| Task Scheduler entry `ClaudeStatusDaemon` | runs daemon at user logon |

Admin rights are only requested (one UAC prompt) if a CH340-based board
needs its driver fixed — everything else goes under the user profile.

## Prerequisites

- Windows 10 / 11
- `winget` (default on Windows 10 ≥ 2004 / 11)
- Arduino Uno or Nano (ATmega328P) with these connections to a 20×4 I²C LCD
  (HW-061 backpack, address 0x27 or 0x3F):
  - LCD GND → Arduino GND
  - LCD VCC → Arduino 5V
  - LCD SDA → Arduino A4
  - LCD SCL → Arduino A5
- Optional power button (AOC599 / TTP223-style touch module):
  - VCC → Arduino D4
  - GND → Arduino GND
  - OUT → Arduino D7 (D2 is taken by onboard RGB LEDs on some Nano clones)
- Optional passive buzzer (HW-508): signal → Arduino D3, GND → GND
- Optional DS3231 RTC module on the same I²C bus (keeps the clock across
  power loss; auto-detected)
- Claude Code installed and logged in

CH340/CH341 clone boards are handled automatically on Windows: the installer
bundles the WCH v3.4 driver and installs it when needed. Driver versions
newer than v3.4 enumerate fine but fail every port open ("a device attached
to the system is not functioning") on many clone chips, so the installer also
replaces a newer driver if one is bound. On Linux the ch341 driver is
in-kernel and on macOS 11+ a driver ships with the OS — no driver step needed.

## Install (Windows)

```powershell
# Allow this script for the current session if needed:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\setup.ps1
```

Options:

- `-Port COM7` — override Arduino COM port (default: auto-detect)
- `-City "Berlin"` — non-interactive weather location (still resolved via
  Open-Meteo geocoding so lat/long is correct)
- `-NoWeather` — disable the screensaver weather line entirely (no API
  polling at runtime)
- `-NoAutostart` — skip Task Scheduler entry (daemon will only run while
  Claude Code is open)

If you run with neither `-City` nor `-NoWeather`, the installer prompts
interactively for a city and shows the resolved match before saving.
Your selection is persisted at `%LOCALAPPDATA%\ClaudeStatus\app\config.json`;
re-running the installer will overwrite it.

Then launch `claude` in a terminal — the LCD updates on the first hook fire.

## Install (Linux / macOS)

```bash
bash setup.sh                       # interactive city/brightness/sound prompts
bash setup.sh --no-weather          # skip weather + alerts
bash setup.sh --port /dev/ttyUSB0   # override port auto-detection
bash setup.sh --no-autostart        # no login service
```

The script installs python3 / pyserial / avrdude through the system package
manager (apt, dnf, pacman, zypper, or Homebrew on macOS — sudo may prompt),
adds you to the `dialout`/`uucp` group on Linux if needed (a re-login makes
it permanent; the script grants temporary access for the current session),
flashes the firmware, and registers the same five hooks. Files go to
`~/.local/share/claude-status/app`; autostart is a systemd user service on
Linux and a LaunchAgent on macOS. The location wizard is a terminal prompt
rather than the browser map.

## Uninstall

```powershell
.\uninstall.ps1        # Windows
```

```bash
bash uninstall.sh      # Linux / macOS
```

Removes app files, the autostart entry, stops the daemon (gracefully — see
the exit-file note below), and restores the backed-up
`~/.claude/settings.json`. Python, avrdude and the firmware are left alone.

## Troubleshooting

- Inspect the daemon log at `%TEMP%\claude_lcd_daemon.log`.
- The Arduino sketch prints `READY` once at boot and `SW:0` / `SW:1` on
  power-button events — those appear in the daemon log as `<< READY`,
  `<< SW:1`, etc.
- If `setup.ps1` can't auto-detect the COM port, plug the Arduino in, run
  `Get-PnpDevice -Class Ports`, find the COM number, and re-run with
  `-Port COMx`.
- Flashing tries 57600 baud first on CH340 boards (Nano clones ship the old
  bootloader) and 115200 otherwise, falling back to the other automatically.
- "A device attached to the system is not functioning" when opening the COM
  port means a too-new CH340 driver is bound — re-run `setup.ps1`, which
  swaps it for the bundled v3.4.
- The COM number may change when the board is plugged into a different USB
  port; the daemon finds the board by USB VID:PID, so no reconfiguration is
  needed.
- To stop the daemon manually, create the file `%TEMP%\claude_lcd_daemon.exit`
  — it exits within a second, closing the COM port cleanly. Avoid killing
  the process: an abruptly closed handle can wedge the CH340 so every port
  open fails ("device not functioning") until the device is replugged.
