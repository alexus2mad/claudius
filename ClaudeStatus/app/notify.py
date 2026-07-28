"""
Push a status command to the Claude-status LCD (Arduino on COM3).

Usage (from Claude Code hooks):
  python notify.py I                  # IDLE
  python notify.py W [tool name]      # WORKING [+ optional T:tool name]
  python notify.py P                  # WAITING — reads the Notification hook
                                      # JSON on stdin to classify the prompt:
                                      #   "permission" in message -> emits X
                                      #                              (PERMISSION)
                                      #   otherwise                -> emits P
                                      # In either case, when stdin gives a
                                      # message, it's also pushed as N:<text>
                                      # so row 3 shows what Claude wants.
  python notify.py C                  # clear a lingering PERMISSION screen —
                                      # fired from PostToolUse: once a tool has
                                      # run, any permission prompt was answered.
                                      # The daemon converts this to WORKING only
                                      # when the LCD is actually in PERMISSION;
                                      # otherwise it's a no-op.
  python notify.py B                  # BOOT

How it works:
  This script writes one or more status commands to a tiny state file. A
  long-lived daemon (lcd_daemon.py) keeps COM3 open and tails that state
  file, so each hook invocation is just a fast file write — no per-call
  Arduino reset. If the daemon isn't running, this script spawns it once,
  detached.
"""
from __future__ import annotations
import json
import os
import random
import sys
import subprocess
import tempfile
from pathlib import Path

try:
    from verbs import VERBS
except ImportError:
    VERBS = ()

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000) if os.name == "nt" else 0

HERE = Path(__file__).resolve().parent
STATE_FILE = Path(tempfile.gettempdir()) / "claude_lcd_state.txt"
PID_FILE = Path(tempfile.gettempdir()) / "claude_lcd_daemon.pid"
DAEMON = HERE / "lcd_daemon.py"


def daemon_alive() -> bool:
    if not PID_FILE.exists():
        return False
    try:
        pid = int(PID_FILE.read_text().strip())
    except (ValueError, OSError):
        return False
    if os.name != "nt":
        # POSIX: signal 0 probes existence without touching the process.
        try:
            os.kill(pid, 0)
            return True
        except PermissionError:
            return True     # exists, owned by someone else
        except OSError:
            return False
    # On Windows, check via tasklist (cheap-ish, runs only when in doubt).
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


def ensure_daemon() -> None:
    if daemon_alive():
        return
    # Detached background spawn that survives the hook process. On Windows,
    # CREATE_NO_WINDOW + DETACHED_PROCESS so no console window flashes; on
    # POSIX a new session detaches from the hook's process group instead
    # (passing creationflags there raises ValueError).
    kwargs = {}
    if os.name == "nt":
        DETACHED = 0x00000008
        NO_WINDOW = 0x08000000
        kwargs["creationflags"] = DETACHED | NO_WINDOW
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen(
            [sys.executable, str(DAEMON)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            **kwargs,
        )
    except Exception:
        pass


def write_state(lines: list[str]) -> None:
    try:
        STATE_FILE.write_text("\n".join(lines) + "\n", encoding="ascii", errors="ignore")
    except Exception:
        pass


def _looks_like_permission(msg: str) -> bool:
    """Claude Code's Notification hook fires both for plain 'idle waiting'
    prompts and for permission requests; we distinguish via a keyword check
    on the `message` field. Conservative — only matches phrases that very
    likely mean 'please decide on a tool call'."""
    if not msg:
        return False
    lower = msg.lower()
    return ("permission" in lower) or ("needs your approval" in lower)


def _is_generic_idle_prompt(msg: str) -> bool:
    """The default 'Claude is waiting for your input' notification fires every
    time you're idle past the threshold and adds nothing past what row 2's
    'WAITING FOR INPUT' label already says. Detect and drop its text so row 3
    stays blank instead of marqueeing the same sentence."""
    if not msg:
        return False
    lower = msg.lower()
    return "waiting for your input" in lower or "waiting for input" in lower


def _read_stdin_json() -> "dict | None":
    """Return the parsed hook payload (any of UserPromptSubmit / Notification /
    Stop deliver a JSON dict on stdin), or None when stdin is absent / empty /
    unparseable."""
    if sys.stdin.isatty():
        return None
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return None
        return json.loads(raw)
    except Exception:
        return None


# Directory names that are too generic to identify a project on the LCD.
_GENERIC_DIRS = {"app", "src", "dist", "build", "lib", "test", "tests",
                 "bin", "out", "target", "public", "static", "assets"}


def _project_name() -> str:
    """Return a meaningful project name for row 0 of the LCD (max 20 chars).
    Tries the git repo root first; falls back to cwd, skipping generic
    leaf names like 'app' or 'src' in favour of the parent directory."""
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL, text=True, timeout=2,
            creationflags=CREATE_NO_WINDOW,
        ).strip()
        if root:
            return Path(root).name[:20]
    except Exception:
        pass
    p = Path.cwd()
    name = p.name
    if name.lower() in _GENERIC_DIRS and p.parent != p:
        name = p.parent.name
    return name[:20]


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    tag = sys.argv[1].strip().upper()
    rest = " ".join(sys.argv[2:]).strip()
    rest = rest.replace("\r", " ").replace("\n", " ")[:20]

    # Read the hook payload (currently only the P branch consumes it, for
    # the `message` field — but stdin is read unconditionally so we don't
    # leave it lingering for any subprocess we spawn later).
    payload = _read_stdin_json()

    cmds: list[str] = []
    if tag == "I":
        cmds = ["I"]
    elif tag == "W":
        # Pick a fresh spinner verb each invocation; format as "Verb..." so
        # the LCD's row 2 mirrors Claude Code's own animated label rather
        # than the static "WORKING" word.
        verb_label = f"{random.choice(VERBS)}..." if VERBS else ""
        cmds = [f"W:{verb_label}" if verb_label else "W"]
        if rest:
            cmds.append(f"T:{rest}")
    elif tag == "P":
        msg = str((payload or {}).get("message") or "")
        # Firmware noteBuf holds 80 chars and marquees anything past 20 — let
        # the full sentence through rather than chopping it at 20.
        msg_clean = msg.replace("\r", " ").replace("\n", " ")[:80]
        if _looks_like_permission(msg):
            cmds = ["X"]
            if msg_clean:
                cmds.append(f"N:{msg_clean}")
        elif msg_clean and not _is_generic_idle_prompt(msg):
            # Substantive notification — show as N:, which implicitly enters
            # S_WAITING on the Arduino side.
            cmds = [f"N:{msg_clean}"]
        else:
            # Generic idle prompt: Claude Code's built-in "waiting for your
            # input" notification fires N seconds after Stop, but the LCD
            # is already in IDLE from that same Stop hook — flipping the
            # label to WAITING FOR INPUT (with a chirp) for the same
            # situation is confusing. Stay quiet.
            cmds = []
    elif tag == "C":
        # PostToolUse: a tool just finished, so any permission prompt has been
        # answered. Ship the project name along so the daemon can restore the
        # WORKING header if it does flip the state.
        cmds = [f"C:{_project_name()}"]
    elif tag == "B":
        cmds = ["B"]
    else:
        return 0

    if cmds:
        # In WORKING state show the project folder on row 0 so the user can
        # tell which terminal is active. All other states clear it back to
        # the default "== Claude Code ==" (H: with empty payload does that).
        # C is conditional — the daemon decides whether anything changes, so
        # it must not carry an unconditional header reset.
        if tag == "W":
            cmds = [f"H:{_project_name()}"] + cmds
        elif tag != "C":
            cmds = ["H:"] + cmds
        write_state(cmds)
    ensure_daemon()
    return 0


if __name__ == "__main__":
    sys.exit(main())
