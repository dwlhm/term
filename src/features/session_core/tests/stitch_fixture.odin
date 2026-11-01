package feature_session_core_tests

// The full-screen program the stitch test scrolls (written to a temp file and
// run with `python3 -I`): alternate screen, SGR mouse reports, 300 numbered
// lines, three lines per wheel notch, a fixed header.

// STITCH_FIXTURE is a full-screen program: alternate screen, SGR mouse
// reports, 300 numbered lines, three lines per wheel notch. An optional argv[1]
// (milliseconds) makes every repaint late, like a program on a loaded machine.
STITCH_FIXTURE :: `import os, sys, termios, time, tty

LINES = ["L%03d" % i for i in range(1, 301)]
BODY = 0
OFF = 0
KEY = ""
DELAY = float(sys.argv[1]) / 1000.0 if len(sys.argv) > 1 else 0.0

def draw():
    if DELAY > 0:
        time.sleep(DELAY)
    rows = ["LIST 300" + KEY]
    for i in range(OFF, OFF + BODY):
        rows.append(LINES[i] if i < len(LINES) else "")
    os.write(1, ("\x1b[H\x1b[2J" + "\r\n".join(rows)).encode())

def main():
    global BODY, OFF, KEY
    old = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        cols, rows = os.get_terminal_size()
        BODY = max(1, rows - 1)
        OFF = len(LINES) - BODY
        os.write(1, b"\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25l")
        draw()
        buf = b""
        while True:
            data = os.read(0, 4096)
            if not data:
                break
            buf += data
            moved = False
            i = 0
            while i < len(buf):
                if buf[i:i+2] == b"\x1b[":
                    end = -1
                    for k in range(i + 3, len(buf)):
                        if buf[k:k+1] in (b"M", b"m"):
                            end = k
                            break
                    if end < 0:
                        break
                    seq = buf[i+2:end]
                    i = end + 1
                    if seq[:1] == b"<":
                        btn = seq[1:].split(b";")[0]
                        if btn == b"64":
                            OFF = max(0, OFF - 3)
                            moved = True
                        elif btn == b"65":
                            OFF = min(len(LINES) - BODY, OFF + 3)
                            moved = True
                    continue
                c = buf[i:i+1]
                i += 1
                if c in (b"\r", b"\n", b"\x1b"):
                    continue
                KEY = " KEY " + c.decode("latin1").strip()
                moved = True
            buf = buf[i:]
            if moved:
                draw()
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)
        os.write(1, b"\x1b[?1049l\x1b[?1006l\x1b[?1000l\x1b[?25h")

main()
`
