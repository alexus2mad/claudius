"""
Interactive backlight brightness controller.

Arrow up/down  : ±5 %
Page up/down   : ±20 %
0-9            : set to N×10 % (0=0%, 9=90%, but type '100' + Enter for 100%)
Enter a number : set exact value, confirm with Enter
q / Ctrl-C     : quit
"""
import sys
import tempfile
from pathlib import Path

STATE_FILE  = Path(tempfile.gettempdir()) / "claude_lcd_state.txt"
CURRENT_FILE = Path(tempfile.gettempdir()) / "claude_lcd_brightness.txt"


def get_current() -> int:
    try:
        return max(0, min(100, int(CURRENT_FILE.read_text().strip())))
    except Exception:
        return 20


def apply(pct: int) -> int:
    pct = max(0, min(100, pct))
    STATE_FILE.write_text(f"L:{pct}\n", encoding="ascii")
    CURRENT_FILE.write_text(str(pct), encoding="ascii")
    return pct


def draw(pct: int, typing: str = "") -> None:
    bar_len = 30
    filled  = round(pct * bar_len / 100)
    bar     = "\u2588" * filled + "\u2591" * (bar_len - filled)
    suffix  = f"  typing: {typing}_" if typing else ""
    print(f"\r  {pct:3d}%  [{bar}]{suffix}   ", end="", flush=True)


def main() -> None:
    # Non-interactive: pass value as argument
    if len(sys.argv) > 1:
        arg = sys.argv[1].strip()
        cur = get_current()
        if arg.startswith(("+", "-")):
            pct = apply(cur + int(arg))
        else:
            pct = apply(int(arg))
        print(f"Brightness: {pct}%")
        return

    try:
        import msvcrt
    except ImportError:
        print("Interactive mode requires Windows (msvcrt). Use: python bl.py <value>")
        sys.exit(1)

    pct = get_current()
    print("Backlight brightness  [↑↓ ±5]  [PgUp/PgDn ±20]  [0-9 ×10%]  [q quit]")
    draw(pct)

    typing = ""
    while True:
        ch = msvcrt.getch()

        # Arrow / Page keys come as two-byte sequences: 0xe0 + code
        if ch in (b"\xe0", b"\x00"):
            ch2 = msvcrt.getch()
            if ch2 == b"H":        # up
                pct = apply(pct + 5)
                typing = ""
            elif ch2 == b"P":      # down
                pct = apply(pct - 5)
                typing = ""
            elif ch2 == b"I":      # page up
                pct = apply(pct + 20)
                typing = ""
            elif ch2 == b"Q":      # page down
                pct = apply(pct - 20)
                typing = ""
            draw(pct, typing)
            continue

        c = ch.decode("latin-1", errors="replace")

        if c in ("q", "Q"):
            print(f"\rBrightness set to {pct}%.{' ' * 40}")
            break

        if c in ("\r", "\n"):
            if typing:
                try:
                    pct = apply(int(typing))
                except ValueError:
                    pass
                typing = ""
            draw(pct, typing)
            continue

        if c == "\x03":  # Ctrl-C
            print()
            break

        if c.isdigit():
            typing += c
            if len(typing) == 1 and c != "1":
                # Single digit 0-9: instant set to N×10
                pct = apply(int(c) * 10)
                typing = ""
            elif len(typing) >= 3:
                try:
                    pct = apply(int(typing))
                except ValueError:
                    pass
                typing = ""

        draw(pct, typing)


if __name__ == "__main__":
    main()
