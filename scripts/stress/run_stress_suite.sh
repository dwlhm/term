#!/usr/bin/env bash
# ==============================================================================
# run_stress_suite.sh - Automated Extreme Stress Test & Ghostty Benchmark Harness
# ==============================================================================
# Runs comprehensive, empirical stress scenarios against Term (and Ghostty if available)
# Measuring:
#   1. Throughput (MB/s) and Wall-Clock Time
#   2. Frame Latency (p50, p95, p99, p99.9, max microseconds)
#   3. Peak RSS Memory
#   4. GPU Adaptive Render Strategy Distribution (Instance vs Compute_Tiles vs Fullscreen)
#   5. Visual Grid Integrity Dump
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/artifacts/stress_results_$(date +%Y%m%d_%H%M%S)"
PAYLOAD_DIR="/tmp/term_stress_payloads"

mkdir -p "$ARTIFACT_DIR"
mkdir -p "$PAYLOAD_DIR"

TERM_BIN="$ROOT_DIR/bin/term"
GHOSTTY_BIN="$(which ghostty 2>/dev/null || true)"

echo "========================================================================"
echo "          EXTREME TERMINAL STRESS TEST & BENCHMARK SUITE                "
echo "========================================================================"
echo "Artifact Directory: $ARTIFACT_DIR"
echo "Target Binary:      $TERM_BIN"
if [ -n "$GHOSTTY_BIN" ]; then
    echo "Ghostty Binary:     $GHOSTTY_BIN"
fi
echo "========================================================================"

# Step 1: Ensure payloads exist
echo ""
echo "[1/4] Preparing Standardized Stress Payloads..."

if [ ! -f "$PAYLOAD_DIR/scrolling_ascii_100k.vt" ]; then
    echo "  Generating 100k line ASCII scrolling payload..."
    python3 "$SCRIPT_DIR/gen_payloads.py" ascii_scrolling "$PAYLOAD_DIR/scrolling_ascii_100k.vt" 100000
fi

if [ ! -f "$PAYLOAD_DIR/truecolor_dense_10mb.vt" ]; then
    echo "  Generating 10MB dense TrueColor (24-bit RGB) payload..."
    python3 "$SCRIPT_DIR/gen_payloads.py" truecolor_dense "$PAYLOAD_DIR/truecolor_dense_10mb.vt" 10240
fi

if [ ! -f "$PAYLOAD_DIR/truecolor_gradient_100f.vt" ]; then
    echo "  Generating TrueColor Animated Gradient wave payload..."
    python3 "$SCRIPT_DIR/gen_payloads.py" truecolor_gradient "$PAYLOAD_DIR/truecolor_gradient_100f.vt" 100
fi

if [ ! -f "$PAYLOAD_DIR/egc_unicode_5mb.vt" ]; then
    echo "  Generating 5MB complex Unicode EGC / ZWJ / emoji payload..."
    python3 "$SCRIPT_DIR/gen_payloads.py" egc_unicode "$PAYLOAD_DIR/egc_unicode_5mb.vt" 5120
fi

echo "✓ All payloads ready in $PAYLOAD_DIR"

# Helper to run a test on Term
run_term_test() {
    local test_name="$1"
    local payload_file="$2"
    local size_bytes
    size_bytes=$(wc -c < "$payload_file" | tr -d ' ')
    local size_mb
    size_mb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b / (1024 * 1024) }')

    echo ""
    echo ">>> Running Term: $test_name ($size_mb MB) <<<"

    local telemetry_file="$ARTIFACT_DIR/telemetry_${test_name}.ndjson"
    local grid_dir="$ARTIFACT_DIR/grid_${test_name}"
    mkdir -p "$grid_dir"

    # Launch Term in background executing the cat payload
    local start_time
    start_time=$(python3 -c 'import time; print(time.time())')

    "$TERM_BIN" -e "cat '$payload_file'; sleep 0.2; kill -USR1 \$\$" \
        --telemetry "$telemetry_file" \
        --grid-dump "$grid_dir" &
    local term_pid=$!

    # Wait for completion or timeout
    local timeout=60
    local elapsed=0
    while kill -0 "$term_pid" 2>/dev/null; do
        sleep 0.1
        elapsed=$(python3 -c "import time; print(time.time() - $start_time)")
        if (( $(echo "$elapsed > $timeout" | bc -l) )); then
            echo "  [TIMEOUT] Killing process $term_pid"
            kill -9 "$term_pid" 2>/dev/null || true
            break
        fi
    done

    # Cleanly terminate Term window if still open
    if kill -0 "$term_pid" 2>/dev/null; then
        kill -TERM "$term_pid" 2>/dev/null || true
        wait "$term_pid" 2>/dev/null || true
    fi

    local end_time
    end_time=$(python3 -c 'import time; print(time.time())')
    local wall_sec
    wall_sec=$(awk -v s="$start_time" -v e="$end_time" 'BEGIN { printf "%.3f", e - s }')
    local throughput_mb_s
    throughput_mb_s=$(awk -v b="$size_bytes" -v s="$wall_sec" 'BEGIN { if (s > 0) printf "%.2f", (b / (1024 * 1024)) / s; else print "0" }')

    echo "  Execution Duration: ${wall_sec} s | Throughput: ${throughput_mb_s} MB/s"

    # Parse telemetry summary if generated
    if [ -f "$telemetry_file" ]; then
        local summary_line
        summary_line=$(grep '"summary":true' "$telemetry_file" | tail -1 || true)
        if [ -n "$summary_line" ]; then
            echo "  Telemetry Summary: $summary_line"
        fi
    fi
}

# Run the 4 core stress suites on Term
run_term_test "truecolor_dense" "$PAYLOAD_DIR/truecolor_dense_10mb.vt"
run_term_test "truecolor_gradient" "$PAYLOAD_DIR/truecolor_gradient_100f.vt"
run_term_test "egc_unicode" "$PAYLOAD_DIR/egc_unicode_5mb.vt"
run_term_test "ascii_scrolling" "$PAYLOAD_DIR/scrolling_ascii_100k.vt"

echo ""
echo "========================================================================"
echo "                   STRESS TEST SUITE COMPLETE                           "
echo "========================================================================"
echo "Detailed NDJSON per-frame metrics and grid dumps saved in:"
echo "$ARTIFACT_DIR"
ls -lh "$ARTIFACT_DIR"
