#!/usr/bin/env bash
# ClaudeStatus LCD — installer for Linux and macOS.
#
#   bash setup.sh                 # interactive (city prompt etc.)
#   bash setup.sh --no-weather    # skip weather/alerts entirely
#   bash setup.sh --port /dev/ttyUSB0   # override auto-detection
#   bash setup.sh --no-autostart  # don't install a login service
#
# What it does (mirrors setup.ps1 on Windows):
#   - ensures python3 + pyserial + avrdude (distro package manager / brew)
#   - Linux: makes sure you can open the serial port (dialout/uucp group)
#   - finds the board by USB VID:PID and flashes hex/claude_status.hex
#   - copies the daemon + hook scripts to ~/.local/share/claude-status/app
#   - registers the five Claude Code hooks in ~/.claude/settings.json
#   - installs autostart (systemd user service / macOS LaunchAgent)
#
# CH340 note: Linux ships the ch341 driver in-kernel; macOS 11+ includes a
# driver too (device shows up as /dev/cu.usbserial* or /dev/cu.wchusbserial*).
# No driver installation is needed on either OS.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/tools/unix_helper.py"
HEX="$HERE/hex/claude_status.hex"
APPDIR="$HOME/.local/share/claude-status/app"
OS="$(uname -s)"

PORT=""
NO_WEATHER=0
NO_AUTOSTART=0
while [ $# -gt 0 ]; do
    case "$1" in
        --port)         PORT="$2"; shift 2 ;;
        --no-weather)   NO_WEATHER=1; shift ;;
        --no-autostart) NO_AUTOSTART=1; shift ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mOK: %s\033[0m\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*"; exit 1; }

# ── Package installation helpers ─────────────────────────────────────────────
linux_install() {  # linux_install <package> [alt-package ...]
    if command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y "$1"
    elif command -v dnf   >/dev/null 2>&1; then sudo dnf install -y "$1"
    elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --noconfirm "${2:-$1}"
    elif command -v zypper >/dev/null 2>&1; then sudo zypper install -y "$1"
    else return 1
    fi
}

ensure_python() {
    step "Checking python3"
    if command -v python3 >/dev/null 2>&1; then ok "$(python3 --version)"; return; fi
    if [ "$OS" = "Darwin" ]; then
        die "python3 not found. Install it with 'brew install python3' or from python.org, then re-run."
    fi
    info "Installing python3 via the package manager (sudo may prompt)"
    linux_install python3 python || die "Could not install python3 — install it manually and re-run."
    ok "$(python3 --version)"
}

ensure_pyserial() {
    step "Checking pyserial"
    if python3 -c 'import serial' 2>/dev/null; then ok "pyserial present"; return; fi
    info "Installing pyserial"
    python3 -m pip install --user pyserial 2>/dev/null \
        || python3 -m pip install --user --break-system-packages pyserial 2>/dev/null \
        || { [ "$OS" = "Linux" ] && linux_install python3-serial python-pyserial; } \
        || die "Could not install pyserial. Try: python3 -m pip install --user pyserial"
    python3 -c 'import serial' 2>/dev/null || die "pyserial still not importable."
    ok "pyserial installed"
}

ensure_avrdude() {
    step "Checking avrdude"
    if command -v avrdude >/dev/null 2>&1; then ok "$(command -v avrdude)"; return; fi
    if [ "$OS" = "Darwin" ]; then
        command -v brew >/dev/null 2>&1 || die "avrdude not found and Homebrew is missing. Install Homebrew (https://brew.sh) or avrdude, then re-run."
        info "Installing avrdude via Homebrew"
        brew install avrdude || die "brew install avrdude failed."
    else
        info "Installing avrdude via the package manager (sudo may prompt)"
        linux_install avrdude || die "Could not install avrdude — install it manually and re-run."
    fi
    ok "avrdude installed"
}

ensure_serial_access() {
    [ "$OS" = "Linux" ] || return 0
    step "Checking serial-port permissions"
    local grp=""
    if getent group dialout >/dev/null 2>&1; then grp=dialout
    elif getent group uucp  >/dev/null 2>&1; then grp=uucp
    fi
    [ -n "$grp" ] || { info "no dialout/uucp group on this distro — skipping"; return 0; }
    if id -nG "$USER" | tr ' ' '\n' | grep -qx "$grp"; then
        ok "user already in '$grp'"
        return 0
    fi
    info "Adding $USER to '$grp' (sudo may prompt)"
    sudo usermod -aG "$grp" "$USER" && ok "added — takes effect at next login"
    if [ -n "$PORT" ] && [ -e "$PORT" ]; then
        # Make this session work without re-logging in.
        sudo chmod a+rw "$PORT" && info "temporary rw access granted on $PORT for this session"
    fi
}

# ── Board ────────────────────────────────────────────────────────────────────
IS_CH340=0
detect_port() {
    step "Detecting the display board"
    if [ -n "$PORT" ]; then
        info "using --port $PORT"
        case "$PORT" in *wchusbserial*|*ttyUSB*) IS_CH340=1 ;; esac
        return
    fi
    local out
    if out="$(python3 "$HELPER" findport)"; then
        PORT="${out%%|*}"
        IS_CH340="${out##*|}"
        ok "found $PORT$( [ "$IS_CH340" = 1 ] && echo ' (CH340)' )"
    else
        die "Could not find the board (VID 1A86:7523 / 2341:0043). Plug it in with a DATA cable and re-run, or pass --port."
    fi
}

flash_firmware() {
    step "Stopping any running daemon (graceful — a hard kill can wedge the CH340)"
    python3 "$HELPER" stopdaemon
    step "Flashing firmware onto $PORT"
    [ -f "$HEX" ] || die "hex/claude_status.hex missing next to setup.sh"
    # CH340 Nano clones ship the old bootloader (57600); genuine Unos talk
    # 115200. Try the likely rate first, fall back to the other.
    local bauds
    if [ "$IS_CH340" = 1 ]; then bauds="57600 115200"; else bauds="115200 57600"; fi
    local b
    for b in $bauds; do
        info "trying $b baud..."
        if avrdude -p atmega328p -c arduino -P "$PORT" -b "$b" -D -U "flash:w:$HEX:i"; then
            ok "sketch flashed ($b baud)"
            return
        fi
        info "no response at $b baud"
    done
    die "avrdude failed at both baud rates. Check the cable/permissions and re-run. (Linux: a group change may need a re-login; 'sudo chmod a+rw $PORT' works for one session.)"
}

copy_app_files() {
    step "Installing files to $APPDIR"
    mkdir -p "$APPDIR"
    local f
    for f in lcd_daemon.py notify.py hook_pretool.py monitor_power.py verbs.py bl.py; do
        cp "$HERE/app/$f" "$APPDIR/" || die "missing app/$f"
    done
    ok "app files copied"
}

# ── Config wizard (CLI) ──────────────────────────────────────────────────────
write_config() {
    step "Configuration"
    local city="-" lat="" lon="" cc="" region="" brightness sound allclear
    if [ "$NO_WEATHER" = 0 ]; then
        while true; do
            printf '    City for weather/alerts (empty = disable): '
            read -r q || q=""
            [ -n "$q" ] || break
            local results
            if ! results="$(python3 "$HELPER" search "$q")"; then
                warn "no match for '$q' — try another spelling"
                continue
            fi
            printf '%s\n' "$results" | while IFS='|' read -r i name country _ _ _; do
                printf '      %s) %s, %s\n' "$i" "$name" "$country"
            done
            printf '    Pick a number (or press Enter to search again): '
            read -r pick || pick=""
            [ -n "$pick" ] || continue
            local line
            line="$(printf '%s\n' "$results" | awk -F'|' -v p="$pick" '$1 == p')"
            [ -n "$line" ] || { warn "no such option"; continue; }
            IFS='|' read -r _ city _ cc lat lon <<EOF
$line
EOF
            city="${city%% (*}"     # strip the "(admin1)" suffix for the LCD
            if [ "$cc" = "ua" ]; then
                region="$(python3 "$HELPER" uaregion "$lat" "$lon")"
                info "air-raid alerts enabled${region:+ — $region}"
            fi
            break
        done
    fi
    printf '    Display brightness 1-100 [20]: '
    read -r brightness || brightness=""
    case "$brightness" in ''|*[!0-9]*) brightness=20 ;; esac
    printf '    Enable sounds (chirps/alerts)? [Y/n]: '
    read -r sound || sound=""
    case "$sound" in [nN]*) sound=0 ;; *) sound=1 ;; esac
    printf '    Play the all-clear melody after alerts? [Y/n]: '
    read -r allclear || allclear=""
    case "$allclear" in [nN]*) allclear=0 ;; *) allclear=1 ;; esac
    python3 "$HELPER" writeconfig "$APPDIR/config.json" \
        "$city" "${lat:-0}" "${lon:-0}" "${cc:-}" "${region:-}" \
        "$brightness" "$sound" "$allclear"
    ok "config written: $APPDIR/config.json"
}

patch_hooks() {
    step "Registering Claude Code hooks in ~/.claude/settings.json"
    python3 "$HELPER" patchhooks "$APPDIR" || die "hook registration failed"
    ok "hooks registered (existing file backed up once as settings.json.claudestatus_backup)"
}

install_autostart() {
    [ "$NO_AUTOSTART" = 0 ] || { info "skipping autostart (--no-autostart)"; return; }
    if [ "$OS" = "Darwin" ]; then
        step "Installing LaunchAgent"
        local plist="$HOME/Library/LaunchAgents/com.claudestatus.lcd.plist"
        mkdir -p "$(dirname "$plist")"
        cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.claudestatus.lcd</string>
    <key>ProgramArguments</key><array>
        <string>$(command -v python3)</string>
        <string>$APPDIR/lcd_daemon.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict></plist>
EOF
        launchctl unload "$plist" 2>/dev/null || true
        launchctl load "$plist" && ok "LaunchAgent installed (runs at login)"
    else
        step "Installing systemd user service"
        if ! command -v systemctl >/dev/null 2>&1; then
            warn "systemd not available — daemon will start on demand from the hooks instead"
            return
        fi
        local unit="$HOME/.config/systemd/user/claude-status-lcd.service"
        mkdir -p "$(dirname "$unit")"
        cat > "$unit" <<EOF
[Unit]
Description=Claude Code LCD status daemon

[Service]
Type=simple
ExecStart=$(command -v python3) $APPDIR/lcd_daemon.py
Restart=no

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable claude-status-lcd.service >/dev/null 2>&1
        ok "systemd user service installed (starts at login)"
    fi
}

start_daemon() {
    step "Starting the daemon"
    if [ "$OS" != "Darwin" ] && command -v systemctl >/dev/null 2>&1 \
        && [ "$NO_AUTOSTART" = 0 ]; then
        systemctl --user restart claude-status-lcd.service \
            && ok "daemon running (systemd)" && return
    fi
    nohup python3 "$APPDIR/lcd_daemon.py" >/dev/null 2>&1 &
    ok "daemon started — the LCD will update momentarily"
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo
echo "==== ClaudeStatus LCD — Installer ($OS) ===="
echo
ensure_python
ensure_pyserial
ensure_avrdude
detect_port
ensure_serial_access
flash_firmware
copy_app_files
write_config
patch_hooks
install_autostart
start_daemon
echo
printf '\033[32mInstallation complete.\033[0m\n'
echo "Run 'claude' in any terminal to start using the LCD."
echo "Brightness later:  python3 \"$APPDIR/bl.py\" 50    (0-100)"
echo "Uninstall:         bash uninstall.sh"
echo
