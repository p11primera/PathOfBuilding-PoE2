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
cp "$INSTALL_DIR/Frameworks/"*.dylib "$FRAMEWORKS_DIR/"

# ── Fix rpath so the binary finds its dylibs at @executable_path/../Frameworks ─
BINARY="$MACOS_DIR/$APP_NAME"
# Add the Frameworks rpath (may already exist from build dir — add idempotently)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true

# ── Copy Lua sources and runtime assets from this repo ───────────────────────
# Runtime Lua libraries (base64, dkjson, etc.)
mkdir -p "$RESOURCES_DIR/runtime"
cp -R runtime/lua          "$RESOURCES_DIR/runtime/"
cp -R runtime/SimpleGraphic "$RESOURCES_DIR/runtime/"

# PoB2 Lua source tree
cp -R src "$RESOURCES_DIR/"

# Miscellaneous top-level assets
cp changelog.txt LICENSE.md help.txt "$RESOURCES_DIR/"

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
# Clear any resource-fork / quarantine xattrs that would block codesign
xattr -rc "$APP"
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
