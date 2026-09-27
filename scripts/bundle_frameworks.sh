#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_BUNDLE="${1:-$REPO_ROOT/bin/Term.app}"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle '$APP_BUNDLE' does not exist."
    exit 1
fi

EXEC="$APP_BUNDLE/Contents/MacOS/term"
if [ ! -f "$EXEC" ]; then
    echo "Error: Executable not found at $EXEC"
    exit 1
fi

FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

DYLIBS=(
    "libfreetype.6.dylib"
    "libharfbuzz.0.dylib"
    "libSDL3.0.dylib"
    "libpng16.16.dylib"
    "libgraphite2.3.dylib"
    "libglib-2.0.0.dylib"
    "libintl.8.dylib"
    "libpcre2-8.0.dylib"
)

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo "/opt/homebrew")"
SEARCH_DIRS=(
    "$BREW_PREFIX/lib"
    "$BREW_PREFIX/opt/freetype/lib"
    "$BREW_PREFIX/opt/harfbuzz/lib"
    "$BREW_PREFIX/opt/sdl3/lib"
    "$BREW_PREFIX/opt/libpng/lib"
    "$BREW_PREFIX/opt/graphite2/lib"
    "$BREW_PREFIX/opt/glib/lib"
    "$BREW_PREFIX/opt/gettext/lib"
    "$BREW_PREFIX/opt/pcre2/lib"
    "/opt/homebrew/lib"
    "/usr/local/lib"
)

echo "==> Bundling frameworks into $FRAMEWORKS_DIR..."

for dylib in "${DYLIBS[@]}"; do
    FOUND=""
    for dir in "${SEARCH_DIRS[@]}"; do
        if [ -f "$dir/$dylib" ]; then
            FOUND="$dir/$dylib"
            break
        fi
    done

    if [ -z "$FOUND" ]; then
        FOUND="$(find "$BREW_PREFIX" -name "$dylib" 2>/dev/null | head -n 1 || true)"
    fi

    if [ -z "$FOUND" ] || [ ! -f "$FOUND" ]; then
        echo "Error: Could not locate $dylib"
        exit 1
    fi

    echo "  Copying $dylib from $FOUND"
    cp -L "$FOUND" "$FRAMEWORKS_DIR/$dylib"
    chmod 755 "$FRAMEWORKS_DIR/$dylib"
done

relocate_deps() {
    local target="$1"
    local deps
    deps=$(otool -L "$target" | sed '1d' | awk '{print $1}')
    for dep in $deps; do
        local dep_base
        dep_base=$(basename "$dep")
        for bundled in "${DYLIBS[@]}"; do
            if [ "$dep_base" = "$bundled" ]; then
                install_name_tool -change "$dep" "@rpath/$bundled" "$target"
            fi
        done
    done
}

echo "==> Relocating framework install names and dependencies..."
for dylib in "${DYLIBS[@]}"; do
    target_dylib="$FRAMEWORKS_DIR/$dylib"
    install_name_tool -id "@rpath/$dylib" "$target_dylib"
    relocate_deps "$target_dylib"
done

echo "==> Updating main executable RPATH and dependencies..."
if ! otool -l "$EXEC" | grep -A 2 LC_RPATH 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
    echo "  Adding @executable_path/../Frameworks to $EXEC"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXEC"
fi
relocate_deps "$EXEC"

echo "==> Performing inside-out ad-hoc codesigning..."
for dylib in "${DYLIBS[@]}"; do
    codesign --force --sign - "$FRAMEWORKS_DIR/$dylib"
done

ENTITLEMENTS="${REPO_ROOT}/assets/Term.entitlements"
if [ -f "$ENTITLEMENTS" ]; then
    echo "  Signing binary with entitlements: $ENTITLEMENTS"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$EXEC"
else
    echo "  Signing binary without entitlements"
    codesign --force --sign - "$EXEC"
fi

echo "  Signing application bundle: $APP_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"

echo "==> Standalone bundle successfully packaged and signed: $APP_BUNDLE"
