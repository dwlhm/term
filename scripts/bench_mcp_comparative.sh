#!/usr/bin/env bash
set -euo pipefail

# bench_mcp_comparative.sh
# Empirical benchmark evaluating term-mcp against Python and Node.js terminal agent baselines.
# Delegates to the comprehensive, output-aware, and multi-command benchmark suite.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${ROOT_DIR}/bin/term-mcp"

cd "${ROOT_DIR}"

if [[ ! -x "${BIN}" ]]; then
    echo "[bench] Building release binary bin/term-mcp..."
    make release-mcp
fi

exec python3 "${SCRIPT_DIR}/bench_mcp_comprehensive.py" "$@"
