=====================================================
  Klavdii I / Claude Code LCD Status -- Technical Notes
=====================================================

The main document for installation and everyday use is the PDF
on this drive: "Клавдій I -- Посібник користувача.pdf".
This file is for the technically curious: how the thing works,
the wire protocol, file locations, and manual procedures.


ARCHITECTURE
------------
  Claude Code hooks --> notify.py --> state file --> lcd_daemon.py
                                                     |  (serial, 9600)
                                                     v
                                              Arduino firmware

  - Five Claude Code hooks (UserPromptSubmit, PreToolUse,
    PostToolUse, Notification, Stop) run notify.py /
    hook_pretool.py. Each hook is a fast fire-and-forget write
    of one or more protocol lines into a tiny state file.
  - lcd_daemon.py is a single-instance background process (PID
    file lock). It owns the serial port permanently -- opening
    the port per hook would pulse DTR and reboot the board every
    time. It tails the state file (mtime poll, 100 ms) and
    forwards lines to the device.
  - The daemon also generates its own traffic: plan-usage quota
    (the OAuth endpoint Claude Code itself uses), weather
    (Open-Meteo), air-raid alerts (two keyless public feeds,
    ubilling.net.ua and siren.pp.ua, cross-checked every poll --
    see AIR-RAID ALERTS below), clock screensaver, monitor power
    state, and a rotating "working verb" every 20 s.
  - The firmware is a state machine (BOOT/IDLE/WORKING/WAITING/
    PERMISSION/OFFLINE/CLOCK/ALERT) with diff-based row writes
    (only changed characters hit the I2C bus) and software-PWM
    backlight dimming.

HARDWARE
--------
  MCU        Arduino Nano clone, ATmega328P, OLD bootloader
             (57600 baud); USB-serial: CH340 (VID:PID 1A86:7523)
  Display    2004 character LCD, HD44780 + PCF8574 I2C backpack
             (address 0x27, 0x3F auto-probed)
  Wiring     LCD SDA->A4, SCL->A5, VCC->5V, GND->GND
             button OUT->D7 (module VCC fed from D4), buzzer->D3
  Power      USB-C (power + data). No RTC battery in this
             version: the daemon sets date/time on every connect
             (R: command), and re-sends it on each READY.

SERIAL PROTOCOL (9600 baud, newline-terminated ASCII)
-----------------------------------------------------
  host -> device
    I               IDLE
    W  / W:<verb>   WORKING (optional spinner verb for row 2)
    T:<tool>        tool name, row 3 in WORKING (when no gauge)
    P               WAITING FOR INPUT
    X               PERMISSION?
    N:<text>        note for row 3 (marquee if >20 chars);
                    implies WAITING unless already WAITING/PERM.
    O               OFFLINE
    B               boot splash    B:<n>  play beep pattern n
    Q:<text>        quota line (row 3 in IDLE)
    G:<0-100>       5h-usage gauge bar (row 3 in WORKING)
    H:<text>        row-0 header (project name); empty = default
    K:<t>|<d>|<w>   clock screensaver: time | date | weather
    R:<Y-m-d H:M:S> set date/time
    L:<0-100>       backlight brightness (software PWM)
    M0 / M1         monitor power: blank / restore display
    A:<CITY>        air-raid alert (siren once, then keepalive)
    V               all-clear (melody + screen)
    Z:<freq>,<ms>   ad-hoc chirp
  device -> host
    READY           board (re)booted -- daemon replays state
    SW:0 / SW:1     button toggled display off / on

  The daemon-side extension "C:<project>" (PostToolUse) never
  reaches the device: the daemon converts it to H:+W: only when
  the LCD is stuck on PERMISSION?, else drops it.

FILE MAP
--------
  Windows                              Linux / macOS
    %LOCALAPPDATA%\ClaudeStatus\app      ~/.local/share/claude-status/app
      lcd_daemon.py notify.py hook_pretool.py monitor_power.py
      verbs.py bl.py config.json
    %TEMP%\claude_lcd_state.txt          $TMPDIR/claude_lcd_state.txt
    %TEMP%\claude_lcd_daemon.pid         (same names in $TMPDIR;
    %TEMP%\claude_lcd_daemon.log          /tmp on most Linux)
    %TEMP%\claude_lcd_daemon.exit
  Hooks live in ~/.claude/settings.json (the installer backs the
  file up once as settings.json.claudestatus_backup).
  Autostart: Task Scheduler "ClaudeStatusDaemon" (Windows),
  systemd user service claude-status-lcd (Linux), LaunchAgent
  com.claudestatus.lcd (macOS).

DAEMON NOTES
------------
  - Port discovery is by USB VID:PID (1A86:7523 CH340 clones,
    2341:0043 genuine Uno); COM numbers/devices may change
    freely. Override with env var CLAUDE_LCD_PORT.
  - Device unplugged? The daemon rescans every 2 s and resyncs
    via the READY handshake; hooks keep updating the state file
    meanwhile, nothing is lost.
  - To stop the daemon cleanly, create the .exit file (see FILE
    MAP) -- it closes the port in a finally block and exits
    within ~1 s. DO NOT kill the process: an abruptly killed
    handle can wedge the CH340 so that every subsequent open
    fails with "device not functioning" until you physically
    replug the device.
  - Quota: GET https://api.anthropic.com/api/oauth/usage with
    the token from ~/.claude/.credentials.json (undocumented,
    beta-gated; the daemon degrades gracefully on failure and
    backs off exponentially on 429).
  - Air-raid alerts poll every 60 s, Ukraine only, no API keys.
    Both feeds are queried every poll and OR'd (active if either
    says so), not "try B only if A errors": the two community
    aggregators can silently disagree even when both respond
    normally (observed 2026-07-28: ubilling reported Kyiv city
    cleared ~15 min after siren.pp.ua still showed it active --
    m. Kyiv is administratively separate from Kyiv Oblast and
    easy for one aggregator's pipeline to drop). A missed alert
    is worse than one extra HTTP call.
  - Monitor tracking: Windows = power-broadcast events;
    macOS = CGDisplayIsAsleep poll; Linux = xset DPMS (X11) or
    GNOME/freedesktop ScreenSaver D-Bus (Wayland GNOME).
  - The daemon self-exits after 6 h with no state changes AND no
    device attached; hooks respawn it on demand.

MANUAL FLASHING
---------------
  The installers do this for you (and stop the daemon first so
  the port is free). By hand:
    avrdude -p atmega328p -c arduino -P <port> -b 57600 -D \
            -U flash:w:ClaudeStatus/hex/claude_status.hex:i
  Old-bootloader clones talk 57600; genuine Unos 115200.
  arduino-cli FQBN: arduino:avr:nano:cpu=atmega328old

CH340 ON WINDOWS (the saga)
---------------------------
  WCH driver v3.9 (2024) enumerates fine but fails every port
  open ("A device attached to the system is not functioning")
  on many clone chips; v3.4 (2014) works. setup.ps1 detects a
  newer bound driver, removes it and installs the bundled v3.4
  from ClaudeStatus\driver\ (one UAC prompt). Windows Update may
  re-install v3.9 later -- re-running setup.ps1 fixes it again.
  Note the same error can also mean a wedged chip after a killed
  port handle: try a replug before blaming the driver.

INSTALLER FLAGS
---------------
  setup.ps1:  -Port COM7   -City "Berlin"   -NoWeather
              -NoAutostart
  setup.sh:   --port /dev/ttyUSB0   --no-weather  --no-autostart
  Re-running an installer is idempotent: present dependencies
  are detected and skipped, settings are re-asked and rewritten.

MORE
----
  ClaudeStatus/README.md -- full developer README (build,
  options, troubleshooting).
  Firmware/daemon sources ship inside ClaudeStatus/app (Python)
  and as claude_status.hex (compiled firmware).

Enjoy, and mind the marquee.
