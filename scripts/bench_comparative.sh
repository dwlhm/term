#!/usr/bin/env bash
# ==============================================================================
# bench_comparative.sh - Comparative Benchmarking Harness for Terminal Emulators
# ==============================================================================
# Verifies Cargo and vtebench, generates standardized VT payloads into /tmp,
# and prints execution instructions for comparative testing across:
#   - Term
#   - Alacritty
#   - Ghostty
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Path Resolution
# ------------------------------------------------------------------------------
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

PAYLOAD_DIR="${TMPDIR:-/tmp}"
PAYLOAD_DIR="${PAYLOAD_DIR%/}"

SCROLL_PAYLOAD="${PAYLOAD_DIR}/vte_scroll.txt"
COLOR_PAYLOAD="${PAYLOAD_DIR}/vte_color.txt"
ALTSCREEN_PAYLOAD="${PAYLOAD_DIR}/vte_altscreen.txt"

CARGO_BIN="cargo"
VTEBENCH_BIN="vtebench"

# ------------------------------------------------------------------------------
# 2. Prerequisite Check: Cargo
# ------------------------------------------------------------------------------
echo "=== Step 1: Checking Cargo Prerequisite ==="
if ! command -v "${CARGO_BIN}" &>/dev/null; then
    echo "ERROR: '${CARGO_BIN}' not found in PATH." >&2
    echo "Cargo is required to install and run ${VTEBENCH_BIN}." >&2
    echo "Please install Rust toolchain via: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" >&2
    exit 1
fi
echo "✓ Cargo is available: $(command -v ${CARGO_BIN})"

# ------------------------------------------------------------------------------
# 3. Prerequisite Check / Installation: vtebench
# ------------------------------------------------------------------------------
echo ""
echo "=== Step 2: Checking vtebench Installation ==="
if ! command -v "${VTEBENCH_BIN}" &>/dev/null; then
    echo "'${VTEBENCH_BIN}' not found in PATH. Installing via 'cargo install vtebench'..."
    "${CARGO_BIN}" install vtebench
    if ! command -v "${VTEBENCH_BIN}" &>/dev/null; then
        echo "ERROR: Installation completed but '${VTEBENCH_BIN}' still not in PATH." >&2
        echo "Ensure '${HOME}/.cargo/bin' is included in your PATH." >&2
        exit 1
    fi
fi
echo "✓ vtebench is available: $(command -v ${VTEBENCH_BIN})"

# ------------------------------------------------------------------------------
# 4. Standard Payload Generation
# ------------------------------------------------------------------------------
echo ""
echo "=== Step 3: Generating Standardized Payloads into ${PAYLOAD_DIR} ==="

# 4a. Scrolling Payload (~8.8 MB, 100,000 lines of ASCII text)
generate_scroll_payload() {
    local target="$1"
    echo "Generating scrolling payload -> ${target}..."
    if "${VTEBENCH_BIN}" scrolling </dev/null > "${target}.tmp" 2>/dev/null && [ -s "${target}.tmp" ]; then
        mv "${target}.tmp" "${target}"
    else
        rm -f "${target}.tmp"
        awk 'BEGIN {
            line = "The quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            for (i = 1; i <= 100000; i++) {
                printf("[%06d] %s\n", i, line);
            }
        }' > "${target}"
    fi
    local size
    size=$(wc -c < "${target}" | tr -d ' ')
    local mb
    mb=$(awk -v s="${size}" 'BEGIN { printf "%.2f", s / (1024 * 1024) }')
    echo "✓ Created: ${target} (${mb} MB / ${size} bytes)"
}

# 4b. Dense Color / TrueColor Payload (~8.5 MB, dense 24-bit SGR sequences)
generate_color_payload() {
    local target="$1"
    echo "Generating dense color payload -> ${target}..."
    if "${VTEBENCH_BIN}" dense_color </dev/null > "${target}.tmp" 2>/dev/null && [ -s "${target}.tmp" ]; then
        mv "${target}.tmp" "${target}"
    elif "${VTEBENCH_BIN}" color </dev/null > "${target}.tmp" 2>/dev/null && [ -s "${target}.tmp" ]; then
        mv "${target}.tmp" "${target}"
    else
        rm -f "${target}.tmp"
        awk 'BEGIN {
            for (i = 1; i <= 2000; i++) {
                for (j = 0; j < 64; j++) {
                    r = (i * 7 + j * 3) % 256;
                    g = (i * 11 + j * 5) % 256;
                    b = (i * 13 + j * 7) % 256;
                    printf("\033[38;2;%d;%d;%dm\033[48;2;%d;%d;%dm#\033[0m", r, g, b, 255 - r, 255 - g, 255 - b);
                }
                printf("\n");
            }
        }' > "${target}"
    fi
    local size
    size=$(wc -c < "${target}" | tr -d ' ')
    local mb
    mb=$(awk -v s="${size}" 'BEGIN { printf "%.2f", s / (1024 * 1024) }')
    echo "✓ Created: ${target} (${mb} MB / ${size} bytes)"
}

# 4c. Alternate Screen Payload (~2.5 MB, 1000 alt-screen switches with content)
generate_altscreen_payload() {
    local target="$1"
    echo "Generating alternate screen payload -> ${target}..."
    if "${VTEBENCH_BIN}" alt-screen </dev/null > "${target}.tmp" 2>/dev/null && [ -s "${target}.tmp" ]; then
        mv "${target}.tmp" "${target}"
    elif "${VTEBENCH_BIN}" altscreen </dev/null > "${target}.tmp" 2>/dev/null && [ -s "${target}.tmp" ]; then
        mv "${target}.tmp" "${target}"
    else
        rm -f "${target}.tmp"
        awk 'BEGIN {
            for (i = 1; i <= 1000; i++) {
                printf("\033[?1049h\033[H\033[2J");
                printf("=== ALTERNATE SCREEN BUFFER TEST (Iteration %04d) ===\n", i);
                for (row = 1; row <= 20; row++) {
                    printf("Grid Row %02d: Performance stream testing screen swap and cell clear.\n", row);
                }
                printf("\033[?1049l");
            }
        }' > "${target}"
    fi
    local size
    size=$(wc -c < "${target}" | tr -d ' ')
    local mb
    mb=$(awk -v s="${size}" 'BEGIN { printf "%.2f", s / (1024 * 1024) }')
    echo "✓ Created: ${target} (${mb} MB / ${size} bytes)"
}

generate_scroll_payload "${SCROLL_PAYLOAD}"
generate_color_payload "${COLOR_PAYLOAD}"
generate_altscreen_payload "${ALTSCREEN_PAYLOAD}"

# ------------------------------------------------------------------------------
# 5. Instructions Output
# ------------------------------------------------------------------------------
SCROLL_SIZE=$(wc -c < "${SCROLL_PAYLOAD}" | tr -d ' ')
SCROLL_MB=$(awk -v s="${SCROLL_SIZE}" 'BEGIN { printf "%.2f", s / (1024 * 1024) }')

COLOR_SIZE=$(wc -c < "${COLOR_PAYLOAD}" | tr -d ' ')
COLOR_MB=$(awk -v s="${COLOR_SIZE}" 'BEGIN { printf "%.2f", s / (1024 * 1024) }')

ALTSCREEN_SIZE=$(wc -c < "${ALTSCREEN_PAYLOAD}" | tr -d ' ')
ALTSCREEN_MB=$(awk -v s="${ALTSCREEN_SIZE}" 'BEGIN { printf "%.2f", s / (1024 * 1024) }')

cat <<EOF

================================================================================
           COMPARATIVE BENCHMARK EXECUTION GUIDE
================================================================================

Standardized benchmark payloads are ready in '${PAYLOAD_DIR}':
  1. Scrolling (${SCROLL_MB} MB):        ${SCROLL_PAYLOAD}
  2. Dense TrueColor (${COLOR_MB} MB):   ${COLOR_PAYLOAD}
  3. Alternate Screen (${ALTSCREEN_MB} MB): ${ALTSCREEN_PAYLOAD}

--------------------------------------------------------------------------------
A. Wall-Clock Throughput Benchmark (Term vs. Alacritty vs. Ghostty)
--------------------------------------------------------------------------------
Execute each command inside the target terminal window (80x24 cells baseline):

1. Scrolling Throughput:
   $ time cat ${SCROLL_PAYLOAD}

2. Dense TrueColor Throughput:
   $ time cat ${COLOR_PAYLOAD}

3. Alternate Screen Throughput:
   $ time cat ${ALTSCREEN_PAYLOAD}

Throughput Formula:
   Throughput (MB/s) = Payload Size (MB) / Real Elapsed Time (seconds)
   e.g. For Scrolling: ${SCROLL_MB} MB / <elapsed_seconds> = <throughput> MB/s

--------------------------------------------------------------------------------
B. Anti-Bias Measurement Controls
--------------------------------------------------------------------------------
1. Set window dimensions identically across all terminals (default: 80x24).
2. Set identical font family and size (e.g. Menlo Regular 14pt).
3. Disable window transparency and ligatures.
4. Keep macOS display refresh rate constant (e.g. 120Hz ProMotion or 60Hz).
5. Ensure laptop is plugged into AC power and Low Power Mode is disabled.
6. Run 5 consecutive iterations and record the median (p50) result.

--------------------------------------------------------------------------------
C. Apple Instruments (GPU Frame Pacing & Metal Validation)
--------------------------------------------------------------------------------
To ensure a terminal is not dropping frames to inflate throughput:
1. Launch Instruments:
   $ open -a Instruments
2. Select the "Metal System Trace" template.
3. Choose the target process (Term, Alacritty, or Ghostty).
4. Click Record, execute the benchmark command, then click Stop.
5. Inspect GPU Frame Time (target < 8.33ms for 120Hz, < 16.66ms for 60Hz)
   and verify zero dropped display frames during the replay.

Full documentation and template tables are in: COMPARATIVE_BENCHMARKS.md
================================================================================
EOF
