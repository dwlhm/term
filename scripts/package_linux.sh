#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="bin/term"
VERSION=""
ARCH=""
OUT_DIR="bin"

while [ $# -gt 0 ]; do
    case "$1" in
        --target=*)
            TARGET="${1#*=}"
            shift
            ;;
        --target)
            if [ $# -lt 2 ]; then
                echo "Error: --target requires an argument" >&2
                exit 1
            fi
            TARGET="$2"
            shift 2
            ;;
        --version=*)
            VERSION="${1#*=}"
            shift
            ;;
        --version)
            if [ $# -lt 2 ]; then
                echo "Error: --version requires an argument" >&2
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        --arch=*)
            ARCH="${1#*=}"
            shift
            ;;
        --arch)
            if [ $# -lt 2 ]; then
                echo "Error: --arch requires an argument" >&2
                exit 1
            fi
            ARCH="$2"
            shift 2
            ;;
        --out-dir=*)
            OUT_DIR="${1#*=}"
            shift
            ;;
        --out-dir)
            if [ $# -lt 2 ]; then
                echo "Error: --out-dir requires an argument" >&2
                exit 1
            fi
            OUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --target <path>   Path to term binary (default: bin/term)"
            echo "  --version <ver>   Package version (default: auto-detected)"
            echo "  --arch <arch>     Target architecture (default: uname -m)"
            echo "  --out-dir <dir>   Output directory (default: bin)"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--target <path>] [--version <ver>] [--arch <arch>] [--out-dir <dir>]" >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$TARGET" ]; then
    echo "Error: target binary '$TARGET' not found" >&2
    exit 1
fi

# Determine version
if [ -z "$VERSION" ]; then
    if [ -f "src/build_info/version.odin" ]; then
        VERSION=$(grep -E 'NUMERIC_VERSION ::' src/build_info/version.odin 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$VERSION" ]; then
            VERSION=$(grep -E 'VERSION ::' src/build_info/version.odin 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
        fi
    fi
fi
if [ -z "$VERSION" ]; then
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        DESCRIBE=$(git describe --tags --match "v*" 2>/dev/null || true)
        if [ -n "$DESCRIBE" ]; then
            VERSION="${DESCRIBE#v}"
        fi
    fi
fi
if [ -z "$VERSION" ]; then
    VERSION="0.3.2"
fi

# Determine architecture
if [ -z "$ARCH" ]; then
    ARCH="$(uname -m)"
fi

PACKAGE_NAME="term-${VERSION}-linux-${ARCH}"
STAGING_PARENT="${OUT_DIR}/staging"
STAGING_DIR="${STAGING_PARENT}/${PACKAGE_NAME}"

echo "Packaging Term ${VERSION} for Linux (${ARCH})..."

# Prepare staging
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/bin"
mkdir -p "$STAGING_DIR/assets"
mkdir -p "$OUT_DIR"

# Copy binary
cp "$TARGET" "$STAGING_DIR/bin/term"
chmod 755 "$STAGING_DIR/bin/term"

# Copy assets
if [ -d "assets/fonts" ]; then
    cp -R assets/fonts "$STAGING_DIR/assets/"
fi
if [ -f "assets/term.desktop" ]; then
    cp assets/term.desktop "$STAGING_DIR/assets/term.desktop"
fi
if [ -f "assets/term.png" ]; then
    cp assets/term.png "$STAGING_DIR/assets/term.png"
fi
if [ -f "logo.svg" ]; then
    cp logo.svg "$STAGING_DIR/assets/term.svg"
elif [ -f "assets/term.svg" ]; then
    cp assets/term.svg "$STAGING_DIR/assets/term.svg"
fi

# Copy installer
if [ -f "scripts/install-linux.sh" ]; then
    cp scripts/install-linux.sh "$STAGING_DIR/install.sh"
    chmod +x "$STAGING_DIR/install.sh"
else
    echo "Error: scripts/install-linux.sh not found" >&2
    exit 1
fi

# Copy docs
if [ -f "README.md" ]; then
    cp README.md "$STAGING_DIR/README.md"
fi
if [ -f "LICENSE" ]; then
    cp LICENSE "$STAGING_DIR/LICENSE"
fi

# Create tarball
TARBALL="${OUT_DIR}/${PACKAGE_NAME}.tar.gz"
tar -czf "$TARBALL" -C "$STAGING_PARENT" "$PACKAGE_NAME"

# Clean staging
rm -rf "$STAGING_PARENT"

echo "$TARBALL"
