#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${1:-${TERM_RELEASE_TAG:-$(git describe --tags --always 2>/dev/null || echo "v2.1.0")}}"
CHECKSUM_FILE="${2:-SHA256SUMS.txt}"
OUTPUT_FILE="${3:-$REPO_ROOT/bin/RELEASE_BODY.md}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

# 1. Determine previous tag for commit range
PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || echo "")"
if [ -z "$PREV_TAG" ]; then
    PREV_TAG="$(git tag -l "v*" | grep -v "^${TAG}$" | sort -V | tail -n 1 || echo "")"
fi

# 2. Extract tag notes from RELEASE_NOTES.md if present
SECTION_NOTES=""
if [ -f "$REPO_ROOT/RELEASE_NOTES.md" ]; then
    # Look for matching header e.g. '# Release Notes - Term <TAG>'
    MATCH_HEADER="$(grep -E "^# Release Notes - Term ${TAG}" "$REPO_ROOT/RELEASE_NOTES.md" || true)"
    if [ -n "$MATCH_HEADER" ]; then
        SECTION_NOTES="$(awk -v header="$MATCH_HEADER" '
            $0 == header { flag=1; next }
            flag && /^# Release Notes - Term/ { flag=0 }
            flag { print }
        ' "$REPO_ROOT/RELEASE_NOTES.md" | sed -e '1{/^$/d;}' -e '${/^$/d;}')"
    fi
fi

# 3. Format SHA256 Checksums Table
CHECKSUMS_TABLE=""
if [ -f "$CHECKSUM_FILE" ]; then
    CHECKSUMS_TABLE="| File | SHA-256 Checksum |"$'\n'"|:---|:---|"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        HASH="$(echo "$line" | awk '{print $1}')"
        FILE="$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')"
        FILE_NAME="$(basename "$FILE")"
        CHECKSUMS_TABLE="${CHECKSUMS_TABLE}"$'\n'"| \`${FILE_NAME}\` | \`${HASH}\` |"
    done < "$CHECKSUM_FILE"
else
    CHECKSUMS_TABLE="*Checksum file not generated.*"
fi

# 4. Generate Commit Log
CHANGELOG=""
if [ -n "$PREV_TAG" ]; then
    CHANGELOG="$(git log "${PREV_TAG}..${TAG}" --oneline --no-merges 2>/dev/null || git log "${PREV_TAG}..HEAD" --oneline --no-merges 2>/dev/null || true)"
fi

if [ -z "$CHANGELOG" ]; then
    CHANGELOG="$(git log -n 25 --oneline --no-merges 2>/dev/null || echo "No commit history found.")"
fi

FORMATTED_COMMITS=""
while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    FORMATTED_COMMITS="${FORMATTED_COMMITS}- ${line}"$'\n'
done <<< "$CHANGELOG"

# 5. Assemble final Release Body
cat <<EOF > "$OUTPUT_FILE"
# ⚡ Term ${TAG}

<div align="center">
  <p><strong>A blazingly fast, GPU-accelerated terminal emulator built with Odin and Native Apple Metal.</strong></p>

  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
  [![Platform: macOS](https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-brightgreen.svg)]()
  [![Renderer: Metal](https://img.shields.io/badge/Renderer-Native%20Apple%20Metal-blue.svg)]()
  [![Odin: dev-2026-08+](https://img.shields.io/badge/Odin-dev--2026--08%2B-purple.svg)](https://odin-lang.org)
</div>

---

EOF

if [ -n "$SECTION_NOTES" ]; then
    cat <<EOF >> "$OUTPUT_FILE"
## 🌟 Release Summary

${SECTION_NOTES}

---

EOF
fi

cat <<EOF >> "$OUTPUT_FILE"
## 🚀 Key Highlights & Architectural Marvels

- **⚡ Steady-State Zero Allocations**: After initialization, normal frame cycles perform zero heap allocations. Input rings, EGC grapheme clusters ($256 \times 4$), shape cache, and GPU atlas slots are pre-allocated.
- **🎨 Full Kitty Graphics Protocol**: Authoritative lifecycle implementation supporting direct inline (\`t=d\`), temp file (\`t=f\`), and POSIX Shared Memory (\`t=s\`) with high-fidelity HiDPI coordinate scaling, sub-rectangle clipping, and leak-free cache eviction.
- **🎮 Adaptive 3-Strategy GPU Rendering**: Dynamically evaluates work complexity in ~36 ns per frame to route passes across **Instance Strategy** (sparse typing/cursor), **Compute Tile Strategy** (dense full-row output), and **Fullscreen Strategy** (mass refresh).
- **🪟 Interactive Split Panes & Dragging**: Dynamic split divider dragging, live viewport resizing, and automatic working directory (CWD) inheritance.
- **🪐 3D Canvas Viewport Component**: Integrated real-time 3D camera controls (orbit, pan, zoom, wireframe toggle) alongside active terminal panes.
- **📑 Multi-Tab Workspace & OSC Tracking**: Native tab lifecycle management with dynamic OSC 0/2 window title capture and shortcut switching (\`Cmd+1\`..\`Cmd+9\`).
- **🔤 Extended Typography & Emoji Atlas**: Unicode 15.1, multi-tier fallback (Maple Mono NF + Symbols Nerd Font Mono), Apple Color Emoji, and async glyph rasterization.

---

## 📦 Downloads & Installation

### Option 1: macOS Disk Image (\`.dmg\`) — *Recommended*
1. Download **\`Term.dmg\`** from the assets below.
2. Double-click to open, then drag **\`Term.app\`** into your **\`/Applications\`** shortcut.

### Option 2: Portable Archive (\`.zip\` / \`.tar.gz\`)
1. Download **\`Term-portable.zip\`** or **\`term-macos-arm64.tar.gz\`**.
2. Uncompress and move \`Term.app\` directly to \`/Applications\` or your user applications folder.

> [!TIP]
> **macOS Gatekeeper Note (Ad-Hoc Signing)**:
> As a standalone open-source binary, Term uses ad-hoc codesigning. If macOS displays an *"unidentified developer"* prompt upon first launch, right-click \`Term.app\` and choose **Open**, or run:
> \`\`\`bash
> xattr -d com.apple.quarantine /Applications/Term.app
> \`\`\`

---

## 🔐 Checksums & Package Integrity

${CHECKSUMS_TABLE}

---

## 📋 Full Changelog

<details>
<summary>Click to view commits in this release</summary>

${FORMATTED_COMMITS}
</details>
EOF

chmod +x "$OUTPUT_FILE" 2>/dev/null || true
echo "==> Generated release body successfully at: $OUTPUT_FILE"
