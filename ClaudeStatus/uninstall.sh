#!/usr/bin/env bash
# ClaudeStatus LCD — uninstaller for Linux and macOS.
#
#   - stops the daemon (graceful exit-file first; a hard kill can wedge the
#     CH340 serial chip until the device is replugged)
#   - removes the systemd user service / LaunchAgent
#   - restores ~/.claude/settings.json from the backup setup.sh made, or
#     strips the six hooks by command-path match
#   - deletes ~/.local/share/claude-status
#   - does NOT touch python3, pyserial, avrdude, or the Arduino firmware

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/tools/unix_helper.py"
APPBASE="$HOME/.local/share/claude-status"
APPDIR="$APPBASE/app"
SETTINGS="$HOME/.claude/settings.json"
BACKUP="$SETTINGS.claudestatus_backup"
OS="$(uname -s)"

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mOK: %s\033[0m\n' "$*"; }

step "Stopping daemon"
if command -v python3 >/dev/null 2>&1; then
    python3 "$HELPER" stopdaemon || true
fi
rm -f "${TMPDIR:-/tmp}/claude_lcd_daemon.pid" \
      "${TMPDIR:-/tmp}/claude_lcd_daemon.exit" \
      "${TMPDIR:-/tmp}/claude_lcd_state.txt" \
      "${TMPDIR:-/tmp}/claude_lcd_daemon.log" 2>/dev/null
ok "daemon stopped"

step "Removing autostart"
if [ "$OS" = "Darwin" ]; then
    plist="$HOME/Library/LaunchAgents/com.claudestatus.lcd.plist"
    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        ok "LaunchAgent removed"
    else
        info "(no LaunchAgent installed)"
    fi
else
    unit="$HOME/.config/systemd/user/claude-status-lcd.service"
    if [ -f "$unit" ]; then
        systemctl --user disable --now claude-status-lcd.service 2>/dev/null || true
        rm -f "$unit"
        systemctl --user daemon-reload 2>/dev/null || true
        ok "systemd user service removed"
    else
        info "(no service installed)"
    fi
fi

step "Restoring ~/.claude/settings.json"
if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$SETTINGS" && rm -f "$BACKUP"
    ok "restored from backup"
elif [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$HELPER" striphooks "$APPDIR"
    ok "hooks stripped by path match"
else
    info "(no settings.json found)"
fi

step "Removing $APPBASE"
if [ -d "$APPBASE" ]; then
    rm -rf "$APPBASE"
    ok "files removed"
else
    info "(already gone)"
fi

echo
printf '\033[32mUninstall complete.\033[0m\n'
echo
