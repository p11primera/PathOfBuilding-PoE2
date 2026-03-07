#!/usr/bin/env bash
# package-macos.sh — assembles Path of Building-PoE2.app from a cmake --install output.
#
# Usage:
#   ./package-macos.sh <install-dir> [output-dir]
#
# Arguments:
#   install-dir   Path produced by: cmake --install build-mac --prefix <install-dir>
#                 Expected layout:
#                   <install-dir>/MacOS/Path of Building-PoE2   (launcher binary)
#                   <install-dir>/Frameworks/lib*.dylib          (all shared libs)
#   output-dir    Where to place the .app bundle (default: ./dist)
#
# Dependencies:
#   codesign, install_name_tool (Xcode Command Line Tools)

set -euo pipefail

INSTALL_DIR="${1:?Usage: $0 <install-dir> [output-dir]}"
OUT_DIR="${2:-./dist}"

APP_NAME="Path of Building-PoE2"
APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
RESOURCES_DIR="$CONTENTS/Resources"

# ── Clean and scaffold ────────────────────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

# ── Copy binaries from cmake install output ───────────────────────────────────
cp "$INSTALL_DIR/MacOS/$APP_NAME" "$MACOS_DIR/"
# Use nullglob so an absent *.so (or *.dylib) doesn't pass a literal pattern
# string to cp and cause a hard failure on a clean install with only dylibs.
shopt -s nullglob
DYLIBS=( "$INSTALL_DIR/Frameworks/"*.dylib )
SOLIBS=( "$INSTALL_DIR/Frameworks/"*.so )
shopt -u nullglob
[[ ${#DYLIBS[@]} -gt 0 ]] && cp "${DYLIBS[@]}" "$FRAMEWORKS_DIR/"
[[ ${#SOLIBS[@]}  -gt 0 ]] && cp "${SOLIBS[@]}"  "$FRAMEWORKS_DIR/"

# GitHub Actions artifact downloads strip execute permissions; restore them.
chmod +x "$MACOS_DIR/$APP_NAME"
find "$FRAMEWORKS_DIR" \( -name '*.dylib' -o -name '*.so' \) \
    -exec chmod +x {} \;

# ── Create ANGLE symlinks for GLFW dlopen ─────────────────────────────────────
# GLFW calls dlopen("libEGL.dylib") at runtime, but the vcpkg angle port ships
# "liblibEGL_angle.dylib".  Create symlinks with the names GLFW expects.
if [[ -f "$FRAMEWORKS_DIR/liblibEGL_angle.dylib" ]]; then
    ln -sf liblibEGL_angle.dylib   "$FRAMEWORKS_DIR/libEGL.dylib"
fi
if [[ -f "$FRAMEWORKS_DIR/liblibGLESv2_angle.dylib" ]]; then
    ln -sf liblibGLESv2_angle.dylib "$FRAMEWORKS_DIR/libGLESv2.dylib"
fi

# ── Fix rpath so the binary finds its dylibs at @executable_path/../Frameworks ─
BINARY="$MACOS_DIR/$APP_NAME"
# Add the Frameworks rpath (may already exist from build dir — add idempotently)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true

# ── Copy Lua sources and runtime assets from this repo ───────────────────────
# Runtime Lua libraries (base64, dkjson, etc.)
mkdir -p "$RESOURCES_DIR/runtime"
cp -R runtime/lua          "$RESOURCES_DIR/runtime/"
cp -R runtime/SimpleGraphic "$RESOURCES_DIR/runtime/"

# ── PoB2 Lua source tree ─────────────────────────────────────────────────────
# Mirrors the exclusions in manifest.cfg so the macOS bundle matches the
# content policy of the Windows installer / update system.
# rsync is used so we can pass per-pattern exclusions cleanly.
rsync -a \
    --exclude='Settings.xml' \
    --exclude='poe_api_response.json' \
    --exclude='luacov.stats.out' \
    --exclude='Export/' \
    --exclude='Builds/' \
    --exclude='TreeData/' \
    --exclude='HeadlessWrapper.lua' \
    --exclude='LaunchInstall.lua' \
    --exclude='Data/TimelessJewelData/*.bin' \
    src/ "$RESOURCES_DIR/src/"

# ── TreeData: selective image inclusion ──────────────────────────────────────
# All tree versions carry their .lua and .json data files (needed so that
# builds created on older tree versions load and calculate correctly).
# Image assets (*.dds.zst, *.png) are only bundled for the latest version —
# older versions' ~170 MB of textures are omitted, matching the Windows
# approach where TreeData is fetched lazily by the update system.
LATEST_TREE=$(grep -m1 'latestTreeVersion\s*=' src/GameVersions.lua \
    | grep -oE '"[^"]+"' | tail -1 | tr -d '"')
LATEST_TREE="${LATEST_TREE:-0_4}"   # fallback if parse fails

for VER_DIR in src/TreeData/*/; do
    VER=$(basename "$VER_DIR")
    DEST="$RESOURCES_DIR/src/TreeData/$VER"
    mkdir -p "$DEST"
    # Data files — always included
    find "$VER_DIR" -maxdepth 1 \( -name '*.lua' -o -name '*.json' \) \
        -exec cp {} "$DEST/" \;
    # Image assets — latest version only
    if [[ "$VER" == "$LATEST_TREE" ]]; then
        find "$VER_DIR" -maxdepth 1 ! \( -name '*.lua' -o -name '*.json' \) \
            -not -type d -exec cp {} "$DEST/" \;
    fi
done

# Miscellaneous top-level assets
cp changelog.txt LICENSE.md help.txt "$RESOURCES_DIR/"

# App icon for Dock / Finder
if [[ -f src/AppIcon.icns ]]; then
    cp src/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
fi

# The engine loads fonts and config from <basePath>/SimpleGraphic/ where
# basePath = Contents/MacOS/.  Symlink into Resources to avoid duplicating
# the ~119 font atlas files.
ln -s ../Resources/runtime/SimpleGraphic "$MACOS_DIR/SimpleGraphic"

# ── Info.plist ────────────────────────────────────────────────────────────────
# Read version from CHANGELOG.md (first line matching "## [x.y.z]")
VERSION=$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md 2>/dev/null || echo "1.0.0")

cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Path of Building-PoE2</string>
  <key>CFBundleDisplayName</key>
  <string>Path of Building (PoE2)</string>
  <key>CFBundleIdentifier</key>
  <string>com.pathofbuildingcommunity.pob2</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleExecutable</key>
  <string>Path of Building-PoE2</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

# ── Ad-hoc code sign (no Apple Developer account needed for local builds) ─────
# Clear any extended attributes that would block codesign.
# xattr -rc may miss the bundle root itself, so also target it explicitly.
xattr -rc "$APP"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
# --deep signs all nested binaries (dylibs inside Frameworks/) as well
codesign --deep --force --sign - "$APP"

echo ""
echo "Built: $APP"
echo ""
echo "To test locally:"
echo "  open \"$APP\""
echo ""
echo "To distribute (Developer ID required):"
echo "  codesign --deep --force --sign \"Developer ID Application: <TEAM>\" \"$APP\""
echo "  ditto -c -k --keepParent \"$APP\" dist/Path-of-Building-PoE2-macos.zip"
echo "  xcrun notarytool submit dist/Path-of-Building-PoE2-macos.zip --wait ..."
