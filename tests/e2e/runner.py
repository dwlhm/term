#!/usr/bin/env python3
"""
Declarative Real E2E Test Runner for Term.
Parses TOML specifications and executes them against bin/term_driver.
"""

import json
import os
import sys
import time
import tomllib
from pathlib import Path
import subprocess

RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
GRAY = "\033[90m"


class TermDriverClient:
    def __init__(self, binary_path: str):
        self.binary_path = binary_path
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(
            [self.binary_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def send_cmd(self, cmd: dict) -> dict:
        if not self.proc or self.proc.poll() is not None:
            raise RuntimeError("term_driver process is not running")
        line = json.dumps(cmd) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()
        resp_line = self.proc.stdout.readline()
        if not resp_line:
            err = self.proc.stderr.read()
            raise RuntimeError(f"term_driver closed pipe unexpectedly: {err}")
        return json.loads(resp_line.strip())

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.send_cmd({"action": "quit"})
            except Exception:
                pass
            self.proc.terminate()
            try:
                self.proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None


def format_grid_display(grid: list[str], max_rows: int = 12) -> str:
    rows = []
    for i, line in enumerate(grid[:max_rows]):
        trimmed = line.rstrip()
        rows.append(f"  {GRAY}{i:02d}|{RESET} {trimmed}")
    if len(grid) > max_rows:
        rows.append(f"  {GRAY}... ({len(grid) - max_rows} more rows){RESET}")
    return "\n".join(rows)


def run_spec(driver_bin: str, spec_path: Path) -> tuple[bool, str]:
    with open(spec_path, "rb") as f:
        spec = tomllib.load(f)

    name = spec.get("name", spec_path.stem)
    cols = spec.get("cols", 80)
    rows = spec.get("rows", 24)
    shell = spec.get("shell", "/bin/sh")

    client = TermDriverClient(driver_bin)
    client.start()

    try:
        init_resp = client.send_cmd({
            "action": "init",
            "cols": cols,
            "rows": rows,
            "shell": shell,
        })
        if init_resp.get("status") != "ok":
            return False, f"Failed to initialize driver: {init_resp}"

        current_state = None

        for idx, step in enumerate(spec.get("steps", [])):
            action = step.get("action")

            if action == "send":
                client.send_cmd({"action": "send", "text": step["text"]})
            elif action == "feed":
                current_state = client.send_cmd({"action": "feed", "text": step["text"]})
            elif action == "key":
                client.send_cmd({"action": "key", "key": step["key"]})
            elif action == "resize":
                client.send_cmd({"action": "resize", "cols": step["cols"], "rows": step["rows"]})
            elif action == "split":
                client.send_cmd({
                    "action": "split",
                    "direction": step.get("direction", "horizontal"),
                    "ratio": step.get("ratio", 0.5),
                })
            elif action == "tab_new":
                client.send_cmd({"action": "tab_new"})
            elif action == "tab_close":
                client.send_cmd({"action": "tab_close", "tab_index": step.get("tab_index", -1)})
            elif action == "sleep":
                time.sleep(step.get("duration", 0.1))
            elif action == "wait_for":
                resp = client.send_cmd({
                    "action": "drain",
                    "timeout_ms": step.get("timeout_ms", 1200),
                    "wait_text": step["text"],
                })
                if resp.get("status") != "ok":
                    return False, f"Step {idx + 1} timed out waiting for: {step['text']!r}"
                current_state = resp

            # Evaluate assertions
            has_assertions = any(k.startswith("assert_") for k in step.keys())
            if has_assertions:
                if action not in ("wait_for", "feed") or not current_state:
                    current_state = client.send_cmd({"action": "get_state"})

                grid = current_state.get("grid", [])
                grid_text = "\n".join(grid)

                if "assert_contains" in step:
                    targets = step["assert_contains"]
                    if isinstance(targets, str):
                        targets = [targets]
                    for target in targets:
                        if target not in grid_text:
                            diff = format_grid_display(grid)
                            return False, (
                                f"Step {idx + 1} failed: Expected grid to contain {target!r}\n"
                                f"Current Visible Grid:\n{diff}"
                            )

                if "assert_not_contains" in step:
                    targets = step["assert_not_contains"]
                    if isinstance(targets, str):
                        targets = [targets]
                    for target in targets:
                        if target in grid_text:
                            diff = format_grid_display(grid)
                            return False, (
                                f"Step {idx + 1} failed: Expected grid NOT to contain {target!r}\n"
                                f"Current Visible Grid:\n{diff}"
                            )

                if "assert_cursor" in step:
                    exp_cursor = step["assert_cursor"]
                    act_cursor = current_state.get("cursor")
                    if exp_cursor != act_cursor:
                        return False, (
                            f"Step {idx + 1} failed: Cursor mismatch. "
                            f"Expected {exp_cursor}, got {act_cursor}"
                        )

                if "assert_alt_screen" in step:
                    exp_alt = step["assert_alt_screen"]
                    act_alt = current_state.get("alt_screen")
                    if exp_alt != act_alt:
                        return False, (
                            f"Step {idx + 1} failed: Alt screen mismatch. "
                            f"Expected {exp_alt}, got {act_alt}"
                        )

                if "assert_tab_count" in step:
                    exp_tabs = step["assert_tab_count"]
                    act_tabs = current_state.get("tab_count")
                    if exp_tabs != act_tabs:
                        return False, (
                            f"Step {idx + 1} failed: Tab count mismatch. "
                            f"Expected {exp_tabs}, got {act_tabs}"
                        )

                if "assert_history_min" in step:
                    min_hist = step["assert_history_min"]
                    act_hist = current_state.get("history", 0)
                    if act_hist < min_hist:
                        return False, (
                            f"Step {idx + 1} failed: Scrollback history too low. "
                            f"Expected >= {min_hist}, got {act_hist}"
                        )

        return True, ""
    except Exception as e:
        return False, f"Execution exception: {e}"
    finally:
        client.stop()


def main():
    root = Path(__file__).resolve().parent.parent.parent
    driver_bin = root / "bin" / "term_driver"

    if not driver_bin.exists():
        print(f"{RED}Error: Driver binary not found at {driver_bin}. Run `make term-driver` first.{RESET}")
        sys.exit(1)

    specs_dir = root / "tests" / "e2e" / "specs"
    if not specs_dir.exists():
        print(f"{RED}Error: Specs directory not found at {specs_dir}{RESET}")
        sys.exit(1)

    # Filter by arg if provided
    filter_arg = sys.argv[1] if len(sys.argv) > 1 else None
    all_specs = sorted(specs_dir.glob("*.toml"))

    if filter_arg:
        target_specs = [
            s for s in all_specs
            if filter_arg in s.name or filter_arg in str(s)
        ]
        if not target_specs and Path(filter_arg).exists():
            target_specs = [Path(filter_arg)]
    else:
        target_specs = all_specs

    if not target_specs:
        print(f"{YELLOW}No test specifications matched.{RESET}")
        sys.exit(0)

    print("=" * 78)
    print(f"{BOLD}         TERM DECLARATIVE REAL END-TO-END (E2E) TEST SUITE{RESET}")
    print("=" * 78)
    print(f"Target Specs: {len(target_specs)} scenario(s) | Driver: {driver_bin.name}")
    print("-" * 78)

    passed = 0
    failed = 0
    start_total = time.time()

    for spec_path in target_specs:
        t0 = time.time()
        ok, msg = run_spec(str(driver_bin), spec_path)
        dt = (time.time() - t0) * 1000

        if ok:
            passed += 1
            print(f"  {GREEN}✔ PASS{RESET}  {spec_path.stem:<36} {GRAY}({dt:.1f}ms){RESET}")
        else:
            failed += 1
            print(f"  {RED}✖ FAIL{RESET}  {spec_path.stem:<36} {GRAY}({dt:.1f}ms){RESET}")
            print(f"{RED}{msg}{RESET}\n")

    total_time = time.time() - start_total
    print("=" * 78)
    status_color = GREEN if failed == 0 else RED
    print(
        f"{status_color}{BOLD}VERDICT: {passed} passed, {failed} failed "
        f"in {total_time:.2f}s{RESET}"
    )
    print("=" * 78)

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
