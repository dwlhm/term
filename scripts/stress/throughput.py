#!/usr/bin/env python3
"""Output throughput of bin/term per pipeline stage.

    python3 -I scripts/stress/throughput.py [-t bin/term] [-m noview,view,gui] [-r 3] [FILE…]

Each run times `/bin/cat FILE` inside a session (PTY → holder → core …):
  noview  real holder + core on a private TERM_SESSION_DIR, no viewer
  view    the same plus one Python viewer that credits every chunk
  gui     `term -e` (GUI viewer, telemetry: what the GUI parsed itself)
Prints cat wall time, MB/s of FILE and CPU (user+sys) per tier. CPU covers
the cat in noview/view and the whole run in gui. Without FILE it writes two
payloads: `short` (1..10M, one number per line) and `long` (300k lines of
199 characters). Every run is killed (SIGKILL) after 120 s.
"""
import argparse
import json
import os
import random
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_wire import Link, Stream, pump  # noqa: E402
from tier_proc import cpu_s, pids, task_info, tier_pid  # noqa: E402

DEADLINE_S = 120
MARK = b"CAT-DONE-MARK"


def payloads(d):
    short, long_ = os.path.join(d, "short"), os.path.join(d, "long")
    with open(short, "w") as f:
        f.write("".join("%d\n" % i for i in range(1, 10_000_001)))
    rnd, cs = random.Random(1), "abcdefghijklmnopqrstuvwxyz0123456789 "
    with open(long_, "w") as f:
        f.write("".join("".join(rnd.choices(cs, k=199)) + "\n" for _ in range(300_000)))
    return [short, long_]


def cat_cmd(path, timefile):
    """Shell line: time the cat into timefile (renamed in place once complete)."""
    return "/usr/bin/time -p /bin/cat %s 2>%s.tmp; mv %s.tmp %s; echo; echo %s" % (
        path, timefile, timefile, timefile, MARK.decode())


def wait_file(path, deadline):
    while not os.path.exists(path):
        if time.time() > deadline:
            raise TimeoutError("no %s" % path)
        time.sleep(0.01)
    return float(open(path).read().split()[1])  # "real <s>"


def cpu_line(names_tasks):
    return " ".join("%s=%.0f+%.0fms" % (n, t.user_s * 1e3, t.sys_s * 1e3) for n, t in names_tasks)


def delta(a, b):
    return type(a)(b.rss_mb, b.user_s - a.user_s, b.sys_s - a.sys_s)


class Tiers:
    """holder + core of `term` on a private session dir, killed on close."""

    def __init__(self, term, size):
        self.term, self.size = term, size
        self.dir = tempfile.mkdtemp(prefix="tput-", dir="/tmp")
        self.env = dict(os.environ, TERM_SESSION_DIR=self.dir)
        subprocess.Popen([term, "--core"], env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        Link(self.dir + "/core.sock", timeout=10).close()

    def tasks(self):
        return [task_info(tier_pid(self.term, r)) for r in ("core", "holder")]

    def run(self, path, n, view):
        tf = "%s/t%d" % (self.dir, n)
        cols, rows = self.size
        before, t0 = self.tasks(), time.time()
        extra = ""
        if view:
            v = Link(self.dir + "/core.sock")
            _, ch = v.create(["/bin/sh", "-c", cat_cmd(path, tf)], cols=cols, rows=rows)
            s, r0 = Stream(ch, MARK), os.times()
            if not pump(v, [s], DEADLINE_S, until_done=True):
                raise TimeoutError("viewer did not see the end")
            r1 = os.times()
            extra = " viewer=%.0fms got=%.1fMB paints=%d" % (
                (r1.user + r1.system - r0.user - r0.system) * 1e3, s.bytes / 1e6, s.paints)
            v.close()
        else:
            subprocess.run([self.term, "session", "new", "-s", "%dx%d" % (cols, rows), "--", "/bin/sh", "-c",
                            cat_cmd(path, tf)], env=self.env, check=True, capture_output=True)
        real = wait_file(tf, t0 + DEADLINE_S)
        after = self.tasks()
        return real, cpu_line(zip(("core", "holder"), map(delta, before, after))) + extra

    def close(self):
        for role in ("core", "holder"):
            for p in pids(self.term, role):
                os.kill(p, signal.SIGKILL)
        shutil.rmtree(self.dir, ignore_errors=True)


def gui_run(term, path, n, work):
    """One `term -e` run; CPU is each process's last sample before it ended."""
    tf, tel = "%s/g%d" % (work, n), "%s/g%d.ndjson" % (work, n)
    old = set(pids(term, "core") + pids(term, "holder"))
    gui = subprocess.Popen([term, "--telemetry", tel, "-e", "sleep 1; %s; sleep 0.5; exit" % cat_cmd(path, tf)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    last, deadline = {}, time.time() + DEADLINE_S
    while gui.poll() is None:
        if time.time() > deadline:
            gui.kill()
            raise TimeoutError("GUI run did not end")
        found = {"gui": gui.pid}
        for role in ("core", "holder"):
            found.update({role: p for p in pids(term, role) if p not in old})
        for name, p in found.items():
            t = task_info(p)
            if t.user_s or t.sys_s:
                last[name] = t
        time.sleep(0.05)
    with open(tel) as f:
        summary = json.loads(f.read().strip().split("\n")[-1])
    real = wait_file(tf, deadline)
    return real, cpu_line(sorted(last.items())) + " gui_parsed=%.1fMB frames=%d" % (
        summary["total_bytes"] / 1e6, summary["frames"])


def bench(args, files, work):
    for mode in args.modes.split(","):
        for path in files:
            size, rates = os.path.getsize(path), []
            tiers = Tiers(args.term, args.size) if mode != "gui" else None
            try:
                for n in range(args.runs):
                    real, info = tiers.run(path, n, mode == "view") if tiers else gui_run(args.term, path, n, work)
                    rates.append(size / real / 1e6)
                    print("%-6s %-6s run%d cat=%.2fs %4.0f MB/s %s" % (
                        mode, os.path.basename(path), n, real, rates[-1], info), flush=True)
            finally:
                if tiers:
                    tiers.close()
            print("%-6s %-6s median %.0f MB/s" % (mode, os.path.basename(path), statistics.median(rates)), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("-t", "--term", default="bin/term")
    ap.add_argument("-m", "--modes", default="noview,view,gui")
    ap.add_argument("-r", "--runs", type=int, default=3)
    ap.add_argument("-s", "--size", default="200x50")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    args.term = os.path.abspath(args.term)
    args.size = tuple(int(x) for x in args.size.split("x"))
    work = tempfile.mkdtemp(prefix="tput-work-")
    try:
        bench(args, [os.path.abspath(f) for f in args.files] or payloads(work), work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
