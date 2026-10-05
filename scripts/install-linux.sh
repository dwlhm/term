#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
UNINSTALL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;
        --prefix)
            if [ $# -lt 2 ]; then
                echo "Error: --prefix requires an argument" >&2
                exit 1
            fi
            PREFIX="$2"
            shift 2
            ;;
        --destdir=*)
            DESTDIR="${1#*=}"
            shift
            ;;
        --destdir)
            if [ $# -lt 2 ]; then
                echo "Error: --destdir requires an argument" >&2
                exit 1
            fi
            DESTDIR="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --prefix <dir>   Installation prefix (default: /usr/local)"
            echo "  --destdir <dir>  Staging directory prepend (default: empty)"
            echo "  --uninstall      Uninstall Term from prefix"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--prefix <dir>] [--destdir <dir>] [--uninstall]" >&2
            exit 1
            ;;
    esac
done

if [ "$UNINSTALL" = true ]; then
    echo "Uninstalling Term from ${DESTDIR}${PREFIX}..."
    rm -f "${DESTDIR}${PREFIX}/bin/term"
    rm -f "${DESTDIR}${PREFIX}/share/applications/term.desktop"
    rm -f "${DESTDIR}${PREFIX}/share/icons/hicolor/512x512/apps/term.png"
    rm -f "${DESTDIR}${PREFIX}/share/icons/hicolor/scalable/apps/term.svg"
    rm -rf "${DESTDIR}${PREFIX}/share/term"
    if [ -z "$DESTDIR" ]; then
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "${DESTDIR}${PREFIX}/share/applications" 2>/dev/null || true
        fi
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -q -t -f "${DESTDIR}${PREFIX}/share/icons/hicolor" 2>/dev/null || true
        fi
    fi
    echo "Term uninstalled."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Locate source directory
if [ -d "$SCRIPT_DIR/assets" ]; then
    SRC_DIR="$SCRIPT_DIR"
elif [ -d "$SCRIPT_DIR/../assets" ]; then
    SRC_DIR="$SCRIPT_DIR/.."
else
    echo "Error: cannot locate assets directory relative to $SCRIPT_DIR" >&2
    exit 1
fi

# Locate binary
BIN_SRC=""
if [ -f "$SRC_DIR/bin/term" ]; then
    BIN_SRC="$SRC_DIR/bin/term"
elif [ -f "$SRC_DIR/term" ]; then
    BIN_SRC="$SRC_DIR/term"
else
    echo "Error: term binary not found in $SRC_DIR/bin or $SRC_DIR" >&2
    exit 1
fi

DESKTOP_SRC="$SRC_DIR/assets/term.desktop"
PNG_SRC="$SRC_DIR/assets/term.png"
FONTS_DIR="$SRC_DIR/assets/fonts"

SVG_SRC=""
if [ -f "$SRC_DIR/assets/term.svg" ]; then
    SVG_SRC="$SRC_DIR/assets/term.svg"
elif [ -f "$SRC_DIR/logo.svg" ]; then
    SVG_SRC="$SRC_DIR/logo.svg"
elif [ -f "$SRC_DIR/term.svg" ]; then
    SVG_SRC="$SRC_DIR/term.svg"
elif [ -f "$SRC_DIR/assets/logo.svg" ]; then
    SVG_SRC="$SRC_DIR/assets/logo.svg"
fi

if [ ! -f "$DESKTOP_SRC" ]; then
    echo "Error: desktop file not found at $DESKTOP_SRC" >&2
    exit 1
fi

if [ ! -f "$PNG_SRC" ]; then
    echo "Error: icon not found at $PNG_SRC" >&2
    exit 1
fi

if [ ! -d "$FONTS_DIR" ]; then
    echo "Error: fonts directory not found at $FONTS_DIR" >&2
    exit 1
fi

echo "Installing Term to ${DESTDIR}${PREFIX}..."

# 1. Binary
install -d "${DESTDIR}${PREFIX}/bin"
install -m 755 "$BIN_SRC" "${DESTDIR}${PREFIX}/bin/term"

# 2. Desktop entry
install -d "${DESTDIR}${PREFIX}/share/applications"
install -m 644 "$DESKTOP_SRC" "${DESTDIR}${PREFIX}/share/applications/term.desktop"

# 3. Icons
install -d "${DESTDIR}${PREFIX}/share/icons/hicolor/512x512/apps"
install -m 644 "$PNG_SRC" "${DESTDIR}${PREFIX}/share/icons/hicolor/512x512/apps/term.png"

if [ -n "$SVG_SRC" ]; then
    install -d "${DESTDIR}${PREFIX}/share/icons/hicolor/scalable/apps"
    install -m 644 "$SVG_SRC" "${DESTDIR}${PREFIX}/share/icons/hicolor/scalable/apps/term.svg"
fi

# 4. Bundled fonts
install -d "${DESTDIR}${PREFIX}/share/term/assets/fonts"
cp -R "$FONTS_DIR"/* "${DESTDIR}${PREFIX}/share/term/assets/fonts/"
chmod 644 "${DESTDIR}${PREFIX}/share/term/assets/fonts/"*

# 5. Caches (only if DESTDIR is empty)
if [ -z "$DESTDIR" ]; then
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "${DESTDIR}${PREFIX}/share/applications" 2>/dev/null || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t -f "${DESTDIR}${PREFIX}/share/icons/hicolor" 2>/dev/null || true
    fi
fi

echo "Term installed successfully to ${PREFIX}/bin/term"
