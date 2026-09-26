#!/usr/bin/env bash
#
# resize_e2e_real.sh — Real, externally-driven window-resize E2E for `term`.
#
# What this does
# --------------
# Builds the `term` app, then — for each of two Instruments templates
# ("Time Profiler" and "Metal System Trace") — launches the app under
# `xctrace record` and drives a REAL window resize from OUTSIDE the app.
# The resize is performed by Apple "System Events" via `osascript`, which
# exercises the genuine AppKit `windowDidResize` path in the running app —
# NOT the app resizing itself (that is `scripts/profile_resize_stress.sh`).
#
# Resize ladder (relative to the initial window size):
#   width : 100% → 50% → 70% → 40% → 90% → 30% → 100%
#   height: 100% → 50% → 70% → 40% → 90% → 30% → 100%
#
# Requirements / permissions
# --------------------------
# - macOS with the Xcode command-line tools (`xcrun xctrace`) and `osascript`.
# - Accessibility permission is REQUIRED. The terminal (and `osascript`) must
#   be allowed to control System Events; without it every osascript call fails
#   and this script exits with code 2.
#       System Settings → Privacy & Security → Accessibility
#       → enable your terminal app, then re-run.
#
# Usage
# -----
#   scripts/resize_e2e_real.sh
#
# Output
# ------
#   artifacts/real-resize-<timestamp>/time-profiler.trace
#   artifacts/real-resize-<timestamp>/metal-system-trace.trace
#   plus a per-template <slug>.log capturing the xctrace run.
#
set -euo pipefail

# --- Paths & toolchain -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT_DIR/bin/term"

# --- Tunables (lifted from the spec so they are easy to adjust) ------------
FALLBACK_WIDTH=800
FALLBACK_HEIGHT=500
LADDER_PERCENTS="50 70 40 90 30 100"
WINDOW_WAIT_SECONDS=30
POLL_INTERVAL_SECONDS=0.2
LADDER_STEP_SECONDS=0.06

# --- Shared osascript state & cleanup --------------------------------------
OSASCRIPT_OUT=""
OSASCRIPT_ERR=""
TRACE_PID=""

cleanup() {
    if [[ -n "$TRACE_PID" ]] && kill -0 "$TRACE_PID" 2>/dev/null; then
        kill "$TRACE_PID" 2>/dev/null || true
    fi
    pkill -x term 2>/dev/null || true
}
trap cleanup EXIT

# Runs a one-liner AppleScript through System Events and returns 0/1.
# Captures stdout in OSASCRIPT_OUT and stderr in OSASCRIPT_ERR.
run_osascript() {
    local script="$1"
    local err_file="$RUN_DIR/osascript-last.stderr"
    if OSASCRIPT_OUT="$(osascript -e "$script" 2>"$err_file")"; then
        OSASCRIPT_ERR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        return 0
    else
        OSASCRIPT_ERR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        return 1
    fi
}

# True when the last osascript failure is a permissions problem (permanent),
# as opposed to a transient error such as "process not found yet".
is_accessibility_error() {
    [[ "$OSASCRIPT_ERR" == *"assistive access"* ]] ||
        [[ "$OSASCRIPT_ERR" == *"not allowed"* ]] ||
        [[ "$OSASCRIPT_ERR" == *"authorized"* ]]
}

fail_accessibility() {
    local where="$1"
    {
        echo "error: osascript/System Events failed while $where"
        echo "       This script resizes the app from OUTSIDE via Apple System Events,"
        echo "       which requires macOS Accessibility permission."
        echo "       Grant Accessibility to your terminal app (and osascript):"
        echo "         System Settings -> Privacy & Security -> Accessibility"
        echo "       then re-run this script."
        echo "       Last osascript error: ${OSASCRIPT_ERR:-<none>}"
    } >&2
    exit 2
}

# --- Preflight -------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script requires macOS (uses System Events and xctrace)" >&2
    exit 2
fi
command -v xcrun >/dev/null 2>&1 || { echo "error: xcrun not found (install the Xcode command-line tools)" >&2; exit 2; }
command -v osascript >/dev/null 2>&1 || { echo "error: osascript not found" >&2; exit 2; }

# --- Build -----------------------------------------------------------------
if ! (cd "$ROOT_DIR" && make build); then
    echo "error: make build failed" >&2
    exit 1
fi

# --- Artifact directory ----------------------------------------------------
RUN_DIR="$ROOT_DIR/artifacts/real-resize-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

# --- Per-template helpers --------------------------------------------------

# Polls System Events until a `term` window exists (up to ~WINDOW_WAIT_SECONDS).
# Transient osascript errors (e.g. process not up yet) are tolerated; a
# permissions failure is permanent and aborts via fail_accessibility.
wait_for_window() {
    local deadline=$(( SECONDS + WINDOW_WAIT_SECONDS ))
    while (( SECONDS < deadline )); do
        if run_osascript 'tell application "System Events" to count windows of process "term"'; then
            local count
            count="${OSASCRIPT_OUT//[^0-9]/}"
            if [[ -n "$count" && "$count" -ge 1 ]]; then
                return 0
            fi
        else
            if is_accessibility_error; then
                fail_accessibility "waiting for the 'term' window"
            fi
            # Otherwise treat as transient ("process not found") and retry.
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    echo "error: timed out after ${WINDOW_WAIT_SECONDS}s waiting for a 'term' window" >&2
    [[ -n "$OSASCRIPT_ERR" ]] && echo "       last osascript error: $OSASCRIPT_ERR" >&2
    return 1
}

type_ls_and_return() {
    run_osascript 'tell application "System Events" to set frontmost of process "term" to true' ||
        fail_accessibility "bringing 'term' to the front"
    run_osascript 'tell application "System Events" to keystroke "ls"' ||
        fail_accessibility "typing 'ls'"
    run_osascript 'tell application "System Events" to key code 36' ||
        fail_accessibility "sending Return"
}

# Reads "W, H" from System Events into the globals WIDTH and HEIGHT.
# Returns 0 on success, 1 if the value is unreadable/unparseable.
read_initial_size() {
    if run_osascript 'tell application "System Events" to tell process "term" to get size of window 1'; then
        local size="${OSASCRIPT_OUT// /}"
        local w="${size%%,*}"
        local h="${size##*,}"
        if [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
            WIDTH="$w"
            HEIGHT="$h"
            return 0
        fi
    elif is_accessibility_error; then
        fail_accessibility "reading the initial window size"
    fi
    return 1
}

resize_window() {
    local w="$1" h="$2"
    run_osascript "tell application \"System Events\" to tell process \"term\" to set size of window 1 to {$w, $h}" ||
        fail_accessibility "resizing the window to ${w}x${h}"
}

# Drives the width ladder (vary width, keep initial height), then the height
# ladder (keep initial width, vary height), using the configured percentages.
apply_ladder() {
    local iw="$1" ih="$2"
    local pct w h
    # shellcheck disable=SC2086  # intentional word-splitting of LADDER_PERCENTS
    for pct in $LADDER_PERCENTS; do
        w=$(( (iw * pct + 50) / 100 ))
        resize_window "$w" "$ih"
        sleep "$LADDER_STEP_SECONDS"
    done
    for pct in $LADDER_PERCENTS; do
        h=$(( (ih * pct + 50) / 100 ))
        resize_window "$iw" "$h"
        sleep "$LADDER_STEP_SECONDS"
    done
}

# --- Capture matrix --------------------------------------------------------
final_status=0

for trace_pair in "Time Profiler:time-profiler" "Metal System Trace:metal-system-trace"; do
    template="${trace_pair%%:*}"
    slug="${trace_pair#*:}"
    trace_path="$RUN_DIR/$slug.trace"
    log_path="$RUN_DIR/$slug.log"

    echo ""
    echo "== Recording '$template' -> $trace_path =="

    xcrun xctrace record --template "$template" --output "$trace_path" --launch -- "$BIN" >"$log_path" 2>&1 &
    TRACE_PID=$!

    if ! wait_for_window; then
        echo "error: no 'term' window appeared for template '$template'; skipping" >&2
        pkill -x term 2>/dev/null || true
        set +e
        wait "$TRACE_PID" 2>/dev/null
        set -e
        TRACE_PID=""
        final_status=1
        continue
    fi

    type_ls_and_return
    sleep 1

    WIDTH=""
    HEIGHT=""
    if read_initial_size; then
        echo "Initial window size: ${WIDTH}x${HEIGHT}"
    else
        echo "warning: could not read initial window size; using fallback ${FALLBACK_WIDTH}x${FALLBACK_HEIGHT}" >&2
        WIDTH="$FALLBACK_WIDTH"
        HEIGHT="$FALLBACK_HEIGHT"
    fi

    apply_ladder "$WIDTH" "$HEIGHT"

    # Stop the app so xctrace finalizes the trace (end-reason "Target app exited").
    pkill -x term 2>/dev/null || true

    set +e
    wait "$TRACE_PID"
    trace_status=$?
    set -e
    TRACE_PID=""
    if [[ $trace_status -ne 0 ]]; then
        echo "note: xctrace exited with status $trace_status for '$template' (expected when the target app exits)" >&2
    fi

    if [[ ! -e "$trace_path" ]]; then
        echo "warning: trace file was not produced: $trace_path" >&2
        final_status=1
    fi
done

# --- Summary ---------------------------------------------------------------
echo ""
echo "Real-resize E2E artifacts:"
for trace_pair in "Time Profiler:time-profiler" "Metal System Trace:metal-system-trace"; do
    slug="${trace_pair#*:}"
    if [[ -e "$RUN_DIR/$slug.trace" ]]; then
        echo "  $RUN_DIR/$slug.trace"
    else
        echo "  $RUN_DIR/$slug.trace  (missing)"
    fi
    echo "  $RUN_DIR/$slug.log"
done

exit "$final_status"
