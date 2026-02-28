#!/usr/bin/env bash
# build-macos.sh — build the SimpleGraphic engine, install it, and package
# the Path of Building-PoE2.app bundle in one step.
#
# Usage:
#   ./build-macos.sh [options]
#
# Options:
#   -e, --engine-dir DIR   Path to PathOfBuilding-SimpleGraphic repo
#                          (default: ../PathOfBuilding-SimpleGraphic)
#   -o, --output-dir DIR   Where to place the .app bundle (default: ./dist)
#   -j, --jobs N           Parallel build jobs (default: system CPU count)
#   -s, --skip-build       Skip engine build; repackage only
#   -l, --launch           Open the app after packaging
#   -h, --help             Show this help

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$SCRIPT_DIR/../PathOfBuilding-SimpleGraphic"
OUTPUT_DIR="./dist"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
SKIP_BUILD=false
LAUNCH=false

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--engine-dir) ENGINE_DIR="$2"; shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -j|--jobs)       JOBS="$2";       shift 2 ;;
        -s|--skip-build) SKIP_BUILD=true; shift ;;
        -l|--launch)     LAUNCH=true;     shift ;;
        -h|--help)
            sed -n '2,/^[^#]/{ /^#/{ s/^# //; s/^#$//; p; }; }' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

BUILD_DIR="$ENGINE_DIR/build-mac"
INSTALL_DIR="$BUILD_DIR/install"

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ ! -d "$ENGINE_DIR" ]]; then
    echo "Error: engine directory not found: $ENGINE_DIR" >&2
    echo "Set it with --engine-dir or clone PathOfBuilding-SimpleGraphic alongside this repo." >&2
    exit 1
fi

if [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
    echo "Error: no build.ninja in $BUILD_DIR" >&2
    echo "Run cmake to configure the build first:" >&2
    echo "  cd $ENGINE_DIR && cmake -B build-mac -G Ninja -DCMAKE_BUILD_TYPE=Release" >&2
    exit 1
fi

# ── Step 1: Build engine ─────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
    echo "==> Building SimpleGraphic engine ($JOBS jobs)..."
    ninja -C "$BUILD_DIR" -j"$JOBS"

    echo "==> Installing to $INSTALL_DIR..."
    cmake --install "$BUILD_DIR" --prefix "$INSTALL_DIR"
else
    echo "==> Skipping engine build (--skip-build)"
fi

# ── Step 2: Package app bundle ───────────────────────────────────────────────
echo "==> Packaging app bundle..."
cd "$SCRIPT_DIR"
bash package-macos.sh "$INSTALL_DIR" "$OUTPUT_DIR"

# ── Step 3: Launch (optional) ────────────────────────────────────────────────
if [[ "$LAUNCH" == true ]]; then
    echo "==> Launching app..."
    open "$OUTPUT_DIR/Path of Building-PoE2.app"
fi
