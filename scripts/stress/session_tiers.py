#!/usr/bin/env python3
"""Real-run check of the session tiers of bin/term (holder + core).

    python3 -I scripts/stress/session_tiers.py [path/to/term]

Runs on a private TERM_SESSION_DIR under /tmp and prints the numbers:
kill -9 of the core during a flood, a viewer stopped for 10 s while
flooding, idle CPU, kill -9 of the holder. Exit 1 when a check fails.
"""
import ctypes
import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_wire import CREDIT, DATA, V_INPUT, Link, Stream, pump  # noqa: E402

TERM = os.path.abspath(sys.argv[1] if len(sys.argv) in (2, 5) else "bin/term")
DIR = os.environ.get("TERM_SESSION_DIR") or "/tmp/tst-%d" % os.getpid()
ENV = dict(os.environ, TERM_SESSION_DIR=DIR)
SOCK = DIR + "/core.sock"
FAILED = []


def check(ok, what):
    print("  [%s] %s" % ("ok" if ok else "FAIL", what), flush=True)
    if not ok:
        FAILED.append(what)


def pids(role):
    out = subprocess.run(["pgrep", "-f", "^%s --%s" % (TERM, role)], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def tier_pid(role):
    found = pids(role)
    return found[0] if found else None


class _TaskInfo(ctypes.Structure):  # struct proc_taskinfo (sys/proc_info.h)
    _fields_ = [("virtual", ctypes.c_uint64), ("resident", ctypes.c_uint64),
                ("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("rest", ctypes.c_uint8 * 64)]


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
_TB = _Timebase()
ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(_TB))


def task_info(pid):
    """(resident MB, CPU seconds) of pid; `ps -o rss,time` needs an entitlement here."""
    ti = _TaskInfo()
    if _LIBPROC.proc_pidinfo(pid, 4, ctypes.c_uint64(0), ctypes.byref(ti), ctypes.sizeof(ti)) <= 0:
        return 0.0, 0.0
    ticks = ti.user + ti.system  # mach absolute time units
    return ti.resident / (1 << 20), ticks * _TB.numer / _TB.denom / 1e9


def session_ls():
    return subprocess.run([TERM, "session", "ls"], env=ENV, capture_output=True, text=True).stdout


def descendants(root):
    rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout.split("\n")
    kids, out = {}, []
    for r in rows:
        if r.strip():
            p, pp = map(int, r.split())
            kids.setdefault(pp, []).append(p)
    todo = [root]
    while todo:
        for k in kids.get(todo.pop(), []):
            out.append(k)
            todo.append(k)
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def flood_kill_core():
    print("kill -9 of the core during a flood")
    big = DIR + "/big.txt"
    with open(big, "wb") as f:
        f.write((b"0123456789abcdefghijklmnopqrstuvwxyz-cat-flood-line\n") * (100 * 1024 * 1024 // 52))
    v = Link(SOCK)
    ida, cha = v.create(["/bin/sh", "-c", "yes | head -c 200000000 | cat; echo; echo FLOOD-A-DONE; sleep 300"])
    idb, chb = v.create(["/bin/sh", "-c", "cat %s; echo; echo FLOOD-B-DONE; sleep 300" % big])
    a, b = Stream(cha, b"FLOOD-A-DONE"), Stream(chb, b"FLOOD-B-DONE")
    pump(v, [a, b], 1.0)
    old = tier_pid("core")
    os.kill(old, signal.SIGKILL)
    t0 = time.time()
    v.close()
    while not ((tier_pid("core") or old) != old and os.path.exists(SOCK)) and time.time() - t0 < 30:
        time.sleep(0.05)
    v = Link(SOCK, timeout=10)
    print("  core back after %.2f s (pid %s -> %s); %.1f MB relayed before the kill" % (
        time.time() - t0, old, tier_pid("core"), (a.bytes + b.bytes) / 1e6))
    ids = [int(r.split()[0]) for r in session_ls().strip().split("\n")[1:]]
    check(sorted(ids) == sorted([ida, idb]), "term session ls lists both sessions: %s" % ids)
    a, b = Stream(v.attach(ida), b"FLOOD-A-DONE"), Stream(v.attach(idb), b"FLOOD-B-DONE")
    t1 = time.time()
    check(pump(v, [a, b], 180, until_done=True), "both floods finish after the restart")
    dt = time.time() - t1
    print("  floods done %.1f s after re-attach (%.1f MB to the viewer)" % (dt, (a.bytes + b.bytes) / 1e6))
    os.unlink(big)
    v.close()
    return (a.bytes + b.bytes) / dt


def stalled_viewer(size):
    print("viewer SIGSTOPped for 10 s while flooding")
    v = Link(SOCK)
    sid, ch = v.create(["/bin/sh", "-c", "yes | head -c %d | cat; echo; echo FLOOD-C-DONE; sleep 300" % size])
    stat = DIR + ".viewer.json"  # beside the session dir: the tiers remove it when they end
    child = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), TERM, "viewer", str(sid), stat], env=ENV)
    live = Stream(ch, b"FLOOD-C-DONE")
    pump(v, [live], 1.0)
    os.kill(child.pid, signal.SIGSTOP)
    before, rss = live.bytes, []
    for _ in range(10):
        pump(v, [live], 1.0)
        rss.append((task_info(tier_pid("holder"))[0], task_info(tier_pid("core"))[0]))
    os.kill(child.pid, signal.SIGCONT)
    print("  healthy viewer got %.1f MB/s while the other was stopped" % ((live.bytes - before) / 10e6))
    hmax, cmax = max(r[0] for r in rss), max(r[1] for r in rss)
    print("  RSS during the stop: holder max %.1f MB, core max %.1f MB" % (hmax, cmax))
    check(hmax < 64, "holder RSS bounded (< 64 MB)")
    check(pump(v, [live], 120, until_done=True), "healthy viewer sees the end of the flood")
    child.wait(60)
    with open(stat) as f:
        s = json.load(f)
    os.unlink(stat)
    print("  stopped viewer: %d repaint(s), %.1f MB received, done=%s, link dropped=%s" % (
        s["paints"], s["bytes"] / 1e6, s["done"], s["eof"]))
    check(s["done"] and not s["eof"] and s["paints"] >= 2, "stopped viewer got a repaint and caught up")
    v.close()


def idle_cpu():
    print("idle CPU of core + holder over 5 s (sessions idle, one viewer attached)")
    v = Link(SOCK)
    v.attach(int(session_ls().split("\n")[1].split()[0]))
    pump(v, [], 1.0)
    pc, ph = tier_pid("core"), tier_pid("holder")
    c0, h0 = task_info(pc)[1], task_info(ph)[1]
    time.sleep(5)
    dc, dh = task_info(pc)[1] - c0, task_info(ph)[1] - h0
    print("  core %.6f s, holder %.6f s CPU" % (dc, dh))
    check(dc == 0 and dh == 0, "idle core and holder do no work")
    v.close()


def echo_latency(n=2000):
    print("keystroke -> echo latency (kernel tty echo, a reader drains the input)")
    v = Link(SOCK)
    sid, ch = v.create(["/bin/sh", "-c", "stty -icanon; exec cat >/dev/null"])
    pump(v, [Stream(ch)], 0.5)
    samples = []
    for i in range(n):
        key = b"abcdefghij"[i % 10:i % 10 + 1]
        t0 = time.perf_counter()
        v.send(V_INPUT, ch, key)
        while True:
            f = v.next(2)
            if f is None:
                check(False, "echo of key %d arrived" % i)
                return
            kind, c, p = f
            if c == ch and kind == DATA:
                v.send(CREDIT, ch, len(p).to_bytes(4, "little"))
                if key in p:
                    break
        samples.append((time.perf_counter() - t0) * 1e3)
    samples.sort()
    p50, p99 = samples[n // 2], samples[n * 99 // 100]
    print("  %d keys: p50 %.3f ms, p99 %.3f ms, max %.3f ms" % (n, p50, p99, samples[-1]))
    check(p99 < 1.0, "p99 keystroke -> echo under 1 ms")
    v.close()


def kill_holder():
    print("kill -9 of the holder")
    h = tier_pid("holder")
    progs = descendants(h)
    os.kill(h, signal.SIGKILL)
    deadline = time.time() + 5
    while any(alive(p) for p in progs) and time.time() < deadline:
        time.sleep(0.05)
    left = [p for p in progs if alive(p)]
    print("  %d program processes before, %d left" % (len(progs), len(left)))
    check(not left, "no orphans: every program ended with its holder")
    ls = session_ls()
    rows = ls.strip().split("\n")[1:]
    check(rows and all(r.split()[1] == "exited" for r in rows), "core reports every session exited")
    for r in rows:
        subprocess.run([TERM, "session", "kill", r.split()[0]], env=ENV, check=False)


def viewer_main(sid, stat):
    v = Link(SOCK)
    s = Stream(v.attach(sid), b"FLOOD-C-DONE")
    eof = False
    try:
        pump(v, [s], 120, until_done=True)
    except EOFError:
        eof = True
    with open(stat, "w") as f:
        json.dump({"paints": s.paints, "bytes": s.bytes, "done": s.done, "eof": eof}, f)


def main():
    subprocess.Popen([TERM, "--core"], env=ENV, stdin=subprocess.DEVNULL, start_new_session=True)
    Link(SOCK, timeout=10).close()
    try:
        rate = flood_kill_core()
        stalled_viewer(int(rate * 16))  # outlasts the 10 s stop
        idle_cpu()
        echo_latency()
        kill_holder()
    finally:
        deadline = time.time() + 10
        while (tier_pid("core") or tier_pid("holder")) and time.time() < deadline:
            time.sleep(0.1)
    check(not tier_pid("core") and not tier_pid("holder") and not os.path.exists(DIR), "tiers exit and remove the dir")
    print("FAILED: " + ", ".join(FAILED) if FAILED else "all checks passed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[2] == "viewer":
        viewer_main(int(sys.argv[3]), sys.argv[4])
    else:
        sys.exit(main())
