"""
PreToolUse hook entry. Reads {"tool_name": ...} on stdin and forwards a
WORKING command with the tool name to the LCD via notify.py.

Designed to be invoked by Claude Code hooks, so it must:
- never block (notify.py is fire-and-forget — daemon does the I/O)
- never raise (a hook failure shouldn't disturb the tool call)
"""
from __future__ import annotations
import json
import os
import sys
import subprocess
from pathlib import Path

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000) if os.name == "nt" else 0

HERE = Path(__file__).resolve().parent
NOTIFY = HERE / "notify.py"


def main() -> int:
    tool_name = ""
    try:
        data = json.load(sys.stdin)
        tool_name = str(data.get("tool_name") or "")[:20]
    except Exception:
        pass
    try:
        subprocess.run(
            [sys.executable, str(NOTIFY), "W", tool_name],
            check=False,
            timeout=5,
            creationflags=CREATE_NO_WINDOW,
        )
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
