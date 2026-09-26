#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_ROOT="$ROOT_DIR/artifacts"
TIMEOUT_SECONDS="${TERM_PROFILE_RESIZE_TIMEOUT_SECONDS:-180}"
DRAG_MODE="${TERM_PROFILE_DRAG:-0}"
run_profiled() {
    env TERM_PROFILE_SCENARIO=1 TERM_PROFILE_RESIZE_TELEMETRY="$telemetry" TERM_PROFILE_RESIZE_TELEMETRY_FILE="$csv" TERM_PROFILE_RESIZE_STATUS_FILE="$status_file" "$@"
}

if [[ "${1:-}" == "--validate-env" ]]; then
    telemetry=1
    csv="/tmp/profile-telemetry-env-check.csv"
    status_file="/tmp/profile-status-env-check.txt"
    run_profiled bash -c '[[ "$TERM_PROFILE_SCENARIO" == 1 && "$TERM_PROFILE_RESIZE_TELEMETRY" == 1 && "$TERM_PROFILE_RESIZE_TELEMETRY_FILE" == /tmp/profile-telemetry-env-check.csv && "$TERM_PROFILE_RESIZE_STATUS_FILE" == /tmp/profile-status-env-check.txt && "$#" == 5 && "$1" == xcrun && "$2" == xctrace && "$3" == record && "$4" == --template && "$5" == "Time Profiler" ]]' profile-env xcrun xctrace record --template "Time Profiler"
    echo "profile environment propagation validated"
    exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find xctrace >/dev/null 2>&1; then
    echo "error: profiling requires macOS and Instruments (xcrun xctrace)" >&2
    exit 2
fi

mkdir -p "$ARTIFACT_ROOT"
RUN_DIR="$(mktemp -d "$ARTIFACT_ROOT/resize-profile-$(date +%Y%m%d-%H%M%S)-XXXXXX")"

if ! (cd "$ROOT_DIR" && make build); then
    echo "error: make build failed; partial artifacts preserved at $RUN_DIR" >&2
    exit 1
fi

capture_one() {
    local telemetry="$1" template="$2" trace_name="$3"
    local name="telemetry-${telemetry}-${trace_name}-programmatic"
    local dir="$RUN_DIR/$name"
    mkdir -p "$dir"
    local log="$dir/app.log" config="$dir/config.txt" csv="$dir/telemetry.csv" trace="$dir/capture.trace" status_file="$dir/scenario.status"
    cat >"$config" <<EOF
variant=programmatic
telemetry=$telemetry
template=$template
TERM_PROFILE_SCENARIO=1
TERM_PROFILE_RESIZE_TELEMETRY=$telemetry
TERM_PROFILE_RESIZE_TELEMETRY_FILE=$csv
TERM_PROFILE_RESIZE_STATUS_FILE=$status_file
TERM_PROFILE_RESIZE_TIMEOUT_SECONDS=$TIMEOUT_SECONDS
EOF
    local trace_pid="" watchdog_pid=""
    cleanup_one() {
        [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" 2>/dev/null || true
        if [[ -n "$trace_pid" ]] && kill -0 "$trace_pid" 2>/dev/null; then
            kill -TERM "$trace_pid" 2>/dev/null || true
            wait "$trace_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_one RETURN
    (
        sleep "$TIMEOUT_SECONDS"
        echo "TIMEOUT: ${name} exceeded ${TIMEOUT_SECONDS}s" >>"$log"
        kill -TERM "$$" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    set +e
    run_profiled xcrun xctrace record --template "$template" --output "$trace" --target-stdout "$log" --launch -- "$ROOT_DIR/bin/term" >"$log" 2>&1 &
    trace_pid=$!
    wait "$trace_pid"
    local status=$?
    set -e
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid="" trace_pid=""
    if grep -q 'TIMEOUT:' "$log"; then
        echo "error: timeout in $name; partial artifacts preserved at $dir" >&2
        return 124
    fi
    if [[ $status -ne 0 || ! -e "$trace" ]]; then
        echo "error: trace failed or missing in $name; partial artifacts preserved at $dir" >&2
        return "${status:-1}"
    fi
    scenario_status=""
    scenario_reason="missing status file"
    if [[ -f "$status_file" ]]; then
        IFS= read -r scenario_status <"$status_file" || true
        scenario_reason="$(sed -n 's/^reason=//p' "$status_file")"
    fi
    if [[ "$scenario_status" != valid ]]; then
        echo "error: scenario did not complete validly in $name (status=${scenario_status:-missing}, reason=${scenario_reason:-unspecified})" >&2
        return 1
    fi
    local dropped_records="N/A"
    if [[ "$telemetry" == 1 ]]; then
        if [[ "$DRAG_MODE" == 1 ]]; then
            if [[ ! -s "$csv" ]] || ! awk -F, 'NR == 1 {if ($5 != "requested_pixel_w" || $7 != "actual_pixel_w" || $9 != "requested_rows" || $11 != "actual_rows") hbad=1; next} $3 == 0 {p0=1} $3 == 1 {p1=1} $3 == 2 {p2=1} $4 == 2 {re++} END {if (!p0) print "error: no Scenario_Phase (phase=0) row" > "/dev/stderr"; if (!p1) print "error: no Resize_Begin (phase=1) row" > "/dev/stderr"; if (!p2) print "error: no Resize_End (phase=2) row" > "/dev/stderr"; if (hbad) print "error: telemetry header column names mismatch" > "/dev/stderr"; if (re < 30) print "error: expected at least 30 Resize_End drag rows (kind=2), found " re > "/dev/stderr"; exit !(p0 && p1 && p2 && !hbad && re >= 30)}' "$csv"; then
                echo "error: missing phase records or drag resize rows in $name" >&2
                return 1
            fi
        else
        if [[ ! -s "$csv" ]] || ! awk -F, 'NR == 1 {if ($5 != "requested_pixel_w" || $7 != "actual_pixel_w" || $9 != "requested_rows" || $11 != "actual_rows") hbad=1; next} $3 == 0 && !i {i=1; initial_w=$7; initial_h=$8} $3 == 1 {r=1} $3 == 2 {c=1} $4 == 11 {wc++; wsw[wc]=$5; wsh[wc]=$6; wsaw[wc]=$7; wsah[wc]=$8; if (hc > 0) orderbad=1} $4 == 12 {hc++; hsw[hc]=$5; hsh[hc]=$6; hsaw[hc]=$7; hsah[hc]=$8} END {if (!i) print "error: no Scenario_Phase (phase=0) row to derive initial dims" > "/dev/stderr"; if (!r) print "error: no Resize_Begin (phase=1) row" > "/dev/stderr"; if (!c) print "error: no Resize_End (phase=2) row" > "/dev/stderr"; if (hbad) print "error: telemetry header column names mismatch" > "/dev/stderr"; if (wc != 6) print "error: expected 6 width ladder rows (kind=11), found " wc > "/dev/stderr"; if (hc != 6) print "error: expected 6 height ladder rows (kind=12), found " hc > "/dev/stderr"; if (orderbad) print "error: height ladder rows (kind=12) precede width ladder rows (kind=11)" > "/dev/stderr"; split("50 70 40 90 30 100", pcts, " "); for (idx = 1; idx <= 6; idx++) {ew = int(initial_w * pcts[idx] / 100 + 0.5); eh = int(initial_h * pcts[idx] / 100 + 0.5); if (wsw[idx] != ew) {bad=1; print "error: width ladder step " idx " requested pixel w " wsw[idx] ", expected " ew > "/dev/stderr"} if (wsh[idx] != initial_h) {bad=1; print "error: width ladder step " idx " requested pixel h " wsh[idx] ", expected " initial_h > "/dev/stderr"} if (wsaw[idx] > ew + 1 || wsaw[idx] < ew - 1) {bad=1; print "error: width ladder step " idx " actual pixel w " wsaw[idx] " outside ±1 of " ew > "/dev/stderr"} if (wsah[idx] > initial_h + 1 || wsah[idx] < initial_h - 1) {bad=1; print "error: width ladder step " idx " actual pixel h " wsah[idx] " outside ±1 of " initial_h > "/dev/stderr"} if (hsw[idx] != initial_w) {bad=1; print "error: height ladder step " idx " requested pixel w " hsw[idx] ", expected " initial_w > "/dev/stderr"} if (hsh[idx] != eh) {bad=1; print "error: height ladder step " idx " requested pixel h " hsh[idx] ", expected " eh > "/dev/stderr"} if (hsaw[idx] > initial_w + 1 || hsaw[idx] < initial_w - 1) {bad=1; print "error: height ladder step " idx " actual pixel w " hsaw[idx] " outside ±1 of " initial_w > "/dev/stderr"} if (hsah[idx] > eh + 1 || hsah[idx] < eh - 1) {bad=1; print "error: height ladder step " idx " actual pixel h " hsah[idx] " outside ±1 of " eh > "/dev/stderr"}} exit !(i && r && c && !hbad && wc == 6 && hc == 6 && !orderbad && !bad)}' "$csv"; then
            echo "error: missing phase records or resize-ladder rows in $name" >&2
            return 1
        fi
        fi
        if ! dropped_records="$(awk -F, 'NR > 1 && $4 == 6 {found++; if ($13 !~ /^[0-9]+$/) malformed=1; else drops=$13} END {if (found != 1) {print "error: dropped-record summary missing or duplicated" > "/dev/stderr"; exit 1} if (malformed) {print "error: dropped-record summary has invalid count" > "/dev/stderr"; exit 1} print drops}' "$csv")"; then
            echo "error: invalid telemetry drop summary in $name" >&2
            return 1
        fi
    fi
    echo "Captured $name: $trace dropped_records=$dropped_records"
}

status=0
for telemetry in 0 1; do
    for trace_pair in "Time Profiler:time-profiler" "Metal System Trace:metal-system-trace"; do
        template="${trace_pair%%:*}"
        trace_name="${trace_pair#*:}"
        capture_one "$telemetry" "$template" "$trace_name" || status=$?
    done
done
cat >"$RUN_DIR/README.txt" <<EOF
Variant: programmatic resize automation
Captures: telemetry disabled/enabled, each with separate Time Profiler and Metal System Trace.
Startup is included for every launch. The scenario waits for the shell prompt, disables
terminal echo, runs 'ls', waits for the completion marker to land in the terminal grid,
then drives a width ladder (50/70/40/90/30/100 percent of the initial window width)
followed by a height ladder with the same percentages, all relative to the initial
window pixel size.
A GPU resize cost is not established unless Metal System Trace shows correlated GPU/display work.
Resize actions are generated by the app scenario; no manual-drag mode is supported.
TERM_PROFILE_DRAG=1 runs a live-drag simulation (no ladder), used to measure per-event resize cost and GPU cadence.
TERM_PROFILE_SCROLLBACK_LINES (default 0) makes the scenario emit that many lines via 'seq' before the resize ladder; scrollback is capped at 1000 lines.
EOF
if [[ $status -ne 0 ]]; then
    echo "error: one or more captures failed; partial artifacts preserved at $RUN_DIR" >&2
    exit "$status"
fi
echo "Capture matrix complete: $RUN_DIR"
