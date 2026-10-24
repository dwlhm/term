#!/bin/sh
# Helper runner for the third-party esctest2 VT conformance test suite.
#
# esctest2 drives the terminal under test over its own PTY (raw stdin/stdout).
# This script launches Term with esctest2 as the shell command and reports
# the resulting log and summary.
#
# Usage:
#   scripts/run_esctest.sh [esctest2 args...]
#   make esctest [ESCTEST_ARGS="--include=test_CBT"]
#
# Environment variables:
#   TERM_BIN     Path to Term binary (default: bin/term)
#   ESCTEST_DIR  Path to esctest2 checkout (default: build/esctest2)
#   ESCTEST_OUT  Output directory for logs (default: build/esctest)

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TERM_BIN=${TERM_BIN:-$ROOT/bin/term}
ESCTEST_DIR=${ESCTEST_DIR:-$ROOT/build/esctest2}
OUT_DIR=${ESCTEST_OUT:-$ROOT/build/esctest}

if [ ! -x "$TERM_BIN" ]; then
	echo "Error: missing $TERM_BIN (build it first: make term)" >&2
	exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "Error: python3 is required to run esctest2" >&2
	exit 1
fi

if [ ! -f "$ESCTEST_DIR/esctest/esctest.py" ]; then
	echo "==> Cloning esctest2 into $ESCTEST_DIR" >&2
	mkdir -p "$(dirname -- "$ESCTEST_DIR")"
	git clone --depth 1 -q https://github.com/ThomasDickey/esctest2.git "$ESCTEST_DIR"
fi

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/esctest.log"
rm -f "$LOG"

# Build the command line. --xterm-checksum=336 selects the standard 16-bit DEC
# checksum calculation (without 2's-complement pre-#279 legacy inversion).
PY_CMD="python3 '$ESCTEST_DIR/esctest/esctest.py' --logfile='$LOG' --xterm-checksum=336 --timeout=0.5"
if [ "$#" -gt 0 ]; then
	PY_CMD="$PY_CMD $*"
fi

echo "==> Running esctest2 inside $TERM_BIN..." >&2
SHELL=/bin/sh "$TERM_BIN" -e "$PY_CMD ; exit \$?"

if [ ! -f "$LOG" ]; then
	echo "Error: esctest2 produced no log at $LOG" >&2
	exit 1
fi

SUMMARY=$(grep -E '^\*\*\* ' "$LOG" 2>/dev/null | tail -1 || true)
if [ -n "$SUMMARY" ]; then
	echo "Summary: $SUMMARY"
	echo "Log:     $LOG"
fi

FAILURES=$(grep -c '^\*\*\* TEST ' "$LOG" 2>/dev/null || true)
if [ "${FAILURES:-0}" -gt 0 ]; then
	echo "Failed:  $FAILURES test(s)"
	grep '^\*\*\* TEST ' "$LOG" | sed -e 's/^\*\*\* TEST //' -e 's/ FAILED:$//' | head -20 | sed 's/^/  /'
	exit 1
fi

exit 0
