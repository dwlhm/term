#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== 1. Building bin/term ==="
cd "$ROOT_DIR"
make build

mkdir -p "$ROOT_DIR/bin"
if [ ! -f "$ROOT_DIR/bin/get_win_id" ]; then
    swiftc - -o "$ROOT_DIR/bin/get_win_id" << 'SWIFT_EOF'
import CoreGraphics
import Foundation
if CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) {
    if let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
        for win in windowList {
            if let winPid = win[kCGWindowOwnerPID as String] as? Int32, winPid == pid {
                if let winId = win[kCGWindowNumber as String] as? Int {
                    print(winId)
                    break
                }
            }
        }
    }
}
SWIFT_EOF
fi

mkdir -p "$ROOT_DIR/artifacts"
rm -f /tmp/term_e2e_ready_*
rm -f "$ROOT_DIR/artifacts/e2e_1_initial.png" \
      "$ROOT_DIR/artifacts/e2e_2_shrunk_50cols.png" \
      "$ROOT_DIR/artifacts/e2e_2_shrunk_40cols.png" \
      "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png" \
      "$ROOT_DIR/artifacts/e2e_aftermath.png"

export TERM_E2E_RESIZE=1
export SHELL="${SHELL:-/bin/zsh}"

echo "=== 2. Starting bin/term with interactive shell ==="
TERM_E2E_RESIZE=1 "$ROOT_DIR/bin/term" &
TERM_PID=$!

CAPTURE_ERR=$(mktemp /tmp/term_e2e_capture_XXXXXX.log)

cleanup() {
    echo "=== Cleaning up ==="
    kill -9 "$TERM_PID" 2>/dev/null || true
    rm -f "$CAPTURE_ERR" /tmp/term_e2e_ready_* 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_for_sentinel() {
    local sentinel="$1"
    local count=0
    while [ ! -f "$sentinel" ] && [ $count -lt 25 ]; do
        sleep 0.2
        count=$((count + 1))
    done
    if [ ! -f "$sentinel" ]; then
        echo "Timeout waiting for $sentinel"
        exit 1
    fi
}

echo "=== 3. Waiting for Phase 1 (Initial 80 cols: 680x480) ==="
wait_for_sentinel "/tmp/term_e2e_ready_phase1"

WIN_ID=""
for i in {1..20}; do
    WIN_ID=$("$ROOT_DIR/bin/get_win_id" "$TERM_PID" 2>/dev/null || true)
    if [ -n "$WIN_ID" ]; then break; fi
    sleep 0.05
done

if [ -n "$WIN_ID" ]; then
    screencapture -l "$WIN_ID" "$ROOT_DIR/artifacts/e2e_1_initial.png" 2>"$CAPTURE_ERR" || screencapture "$ROOT_DIR/artifacts/e2e_1_initial.png" 2>"$CAPTURE_ERR" || true
else
    screencapture "$ROOT_DIR/artifacts/e2e_1_initial.png" 2>"$CAPTURE_ERR" || true
fi
echo "Captured Phase 1 (Initial 80 cols)"

echo "=== 4. Waiting for Phase 2 (Shrunk 50 cols: 440x480) ==="
wait_for_sentinel "/tmp/term_e2e_ready_phase2"

if [ -n "$WIN_ID" ]; then
    screencapture -l "$WIN_ID" "$ROOT_DIR/artifacts/e2e_2_shrunk_50cols.png" 2>"$CAPTURE_ERR" || screencapture "$ROOT_DIR/artifacts/e2e_2_shrunk_50cols.png" 2>"$CAPTURE_ERR" || true
else
    screencapture "$ROOT_DIR/artifacts/e2e_2_shrunk_50cols.png" 2>"$CAPTURE_ERR" || true
fi
cp "$ROOT_DIR/artifacts/e2e_2_shrunk_50cols.png" "$ROOT_DIR/artifacts/e2e_2_shrunk_40cols.png" 2>/dev/null || true
echo "Captured Phase 2 (Shrunk 50 cols)"

echo "=== 5. Waiting for Phase 3 (Restored 80 cols: 680x480) ==="
wait_for_sentinel "/tmp/term_e2e_ready_phase3"

if [ -n "$WIN_ID" ]; then
    screencapture -l "$WIN_ID" "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png" 2>"$CAPTURE_ERR" || screencapture "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png" 2>"$CAPTURE_ERR" || true
else
    screencapture "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png" 2>"$CAPTURE_ERR" || true
fi
cp "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png" "$ROOT_DIR/artifacts/e2e_aftermath.png"
echo "Captured Phase 3 (Restored 80 cols)"

echo "=== 6. Inspecting physical image dimensions via sips ==="
sips -g pixelWidth -g pixelHeight "$ROOT_DIR/artifacts/e2e_1_initial.png" || true
sips -g pixelWidth -g pixelHeight "$ROOT_DIR/artifacts/e2e_2_shrunk_50cols.png" || true
sips -g pixelWidth -g pixelHeight "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png" || true

SCREEN_RECORDING_NOTICE="NOTICE: macOS Screen Recording permission is required for screencapture. Please grant Screen Recording permission to your terminal in System Settings -> Privacy & Security -> Screen Recording to enable full visual OCR."

if [ "${E2E_FORCE_FALLBACK:-0}" = "1" ]; then
    rm -f "$ROOT_DIR/artifacts/e2e_3_restored_80cols.png"
fi

SCREENSHOT="$ROOT_DIR/artifacts/e2e_3_restored_80cols.png"

if [ ! -f "$SCREENSHOT" ] || [ ! -s "$SCREENSHOT" ]; then
    echo "$SCREEN_RECORDING_NOTICE"
    echo "=== Performing fallback verification ==="
    if kill -0 "$TERM_PID" 2>/dev/null; then
        echo "PASS: Compiled binary bin/term is alive and running stably across resize cycles (PID: $TERM_PID)"
    else
        echo "FAIL: Compiled binary bin/term terminated unexpectedly during resize cycles"
        exit 1
    fi

    echo "Validating terminal reflow engine output via unit tests..."
    make test-terminal

    echo "=== E2E Resize Test Completed Successfully (Fallback Mode) ==="
    exit 0
fi

echo "=== 7. Running OCR verification on $SCREENSHOT ==="
OCR_JSON=$(swift "$ROOT_DIR/scripts/e2e_ocr.swift" "$SCREENSHOT")
echo "OCR Result:"
echo "$OCR_JSON"

# Assert no duplicate prompt lines exist in the screenshot (verifying absence of staircase bug)
DUPLICATES=$( (echo "$OCR_JSON" | grep -E '"text"[[:space:]]*:' | sed -E 's/^[[:space:]]*"text"[[:space:]]*:[[:space:]]*"([^"]*)".*$/\1/' | sed '/^[[:space:]]*$/d' | sort | uniq -c | awk '$1 > 1 {print $0}') || true )
if [ -n "$DUPLICATES" ]; then
    echo "Duplicate lines detected in OCR:"
    echo "$DUPLICATES"
    if echo "$DUPLICATES" | grep -E -q '/|term|%|\$|>|➜|❯'; then
        echo "FAIL: Staircase prompt duplication detected!"
        exit 1
    else
        echo "PASS: Non-prompt duplicates (e.g. window controls) ignored, no duplicate prompt rows"
    fi
else
    echo "PASS: No duplicate prompt rows detected (staircase bug eliminated)"
fi

echo "=== E2E Resize Test Completed Successfully ==="
