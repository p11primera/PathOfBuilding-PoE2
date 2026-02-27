# macOS Native Port Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a native macOS arm64 `.app` bundle for Path of Building (PoE2) that runs without Wine or emulation.

**Architecture:** Fork `PathOfBuilding-SimpleGraphic` and add a 5-file `engine/system/mac/` layer (entry point, OS interface, window, OpenGL, console). GLFW handles windowing cross-platform; ANGLE provides OpenGL ES on the Metal backend. In this repo, add a packaging script, GitHub Actions workflow, and manifest changes. The Lua game logic needs no changes for v1.

**Tech Stack:** C++17, Objective-C++ (Cocoa APIs), CMake, vcpkg, ANGLE (Metal backend), GLFW, LuaJIT (arm64), GitHub Actions, `codesign`/`xcrun notarytool`

**Design doc:** `docs/plans/2026-02-27-macos-port-design.md`

---

## Repo Setup

> This plan requires work in two repositories. Complete all SimpleGraphic tasks (Tasks 1–9) before the PoB2 repo tasks (Tasks 10–14).

---

## SimpleGraphic Fork Tasks

> **Working directory for all SimpleGraphic tasks:** your local clone of your fork of `PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic`, on a branch named `feature/macos-port`.

---

### Task 1: Fork and branch SimpleGraphic

**Files:** No code changes; repo setup only.

**Step 1: Fork on GitHub**

Go to https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic and click Fork.

**Step 2: Clone your fork and create the feature branch**

```bash
git clone https://github.com/YOUR_USERNAME/PathOfBuilding-SimpleGraphic.git
cd PathOfBuilding-SimpleGraphic
git checkout -b feature/macos-port
```

**Step 3: Verify the existing structure**

```
ls engine/system/win/
```

Expected output includes: `entry.cpp  sys_main.cpp  sys_video.cpp  sys_opengl.cpp  sys_console.cpp`

These are your implementation reference. Read each file before writing its macOS counterpart.

**Step 4: Create the mac directory**

```bash
mkdir -p engine/system/mac
```

**Step 5: Commit**

```bash
git add engine/system/mac/.gitkeep
git commit -m "chore: scaffold engine/system/mac directory"
```

---

### Task 2: `mac/sys_console.cpp` — debug console

This is the simplest file. Write it first to get comfortable with the pattern.

**Files:**
- Create: `engine/system/mac/sys_console.cpp`

**Step 1: Read the Windows reference**

```bash
cat engine/system/win/sys_console.cpp
```

Note the functions it exports (e.g. `SysConsole_Init`, `SysConsole_Print`, `SysConsole_Clear`). Your macOS version must export the same function signatures.

**Step 2: Write `mac/sys_console.cpp`**

```cpp
// engine/system/mac/sys_console.cpp
// Debug console — writes to stderr (visible in Terminal and Console.app)

#include "ui_local.h"
#include <cstdio>

void SysConsole_Init() {
    // No window needed on macOS; stderr is always available
}

void SysConsole_Print(const char* msg) {
    fprintf(stderr, "%s", msg);
    fflush(stderr);
}

void SysConsole_Clear() {
    // No-op on macOS
}

void SysConsole_Destroy() {
    // No-op on macOS
}
```

Adjust the function signatures to match exactly what `win/sys_console.cpp` exports. If the Windows version exports different names or takes different parameters, mirror them.

**Step 3: Confirm it compiles (will link later)**

```bash
clang++ -std=c++17 -c engine/system/mac/sys_console.cpp -I. -o /tmp/sys_console.o
```

Expected: no errors. (Linker errors are fine at this stage.)

**Step 4: Commit**

```bash
git add engine/system/mac/sys_console.cpp
git commit -m "feat(mac): add sys_console.cpp (stderr debug console)"
```

---

### Task 3: `mac/sys_main.cpp` — OS interface

This is the largest file. It provides path handling, clipboard, and the run loop.

**Files:**
- Create: `engine/system/mac/sys_main.cpp`

**Step 1: Read the Windows reference**

```bash
cat engine/system/win/sys_main.cpp
```

List every exported function. You must implement each one with matching signatures. Pay special attention to `GetUserPath`, `SetClipboard`, `GetClipboard`, and the main run loop entry point.

**Step 2: Write `mac/sys_main.mm`**

Use the `.mm` extension (Objective-C++) for Cocoa API access.

```objc
// engine/system/mac/sys_main.mm

#include "ui_local.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// ── Path handling ────────────────────────────────────────────────────────────

const char* SysGetUserPath() {
    static char path[PATH_MAX];
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* appSupport = dirs.firstObject;
    NSString* full = [appSupport stringByAppendingPathComponent:
                      @"Path of Building (PoE2)"];

    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* err = nil;
    [fm createDirectoryAtPath:full
  withIntermediateDirectories:YES
                   attributes:nil
                        error:&err];
    if (err) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Cannot create user data directory";
        alert.informativeText = [NSString stringWithFormat:
            @"%@\n\n%@", full, err.localizedDescription];
        [alert runModal];
        exit(1);
    }

    strncpy(path, full.UTF8String, PATH_MAX - 1);
    return path;
}

// ── Clipboard ────────────────────────────────────────────────────────────────

void SysSetClipboard(const char* text) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[NSString stringWithUTF8String:text]
          forType:NSPasteboardTypeString];
}

const char* SysGetClipboard() {
    static char buf[65536];
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* str = [pb stringForType:NSPasteboardTypeString];
    if (!str) return "";
    strncpy(buf, str.UTF8String, sizeof(buf) - 1);
    return buf;
}

// ── Run loop (delegate to GLFW via existing engine code) ─────────────────────
// See mac/sys_video.cpp for the GLFW run loop.
```

> **Note:** The exact function names (`SysGetUserPath`, `SysSetClipboard`, etc.) must match what `ui_api.cpp` calls. Search for clipboard/path calls in `ui_api.cpp` and `ui_main.cpp` and adjust names accordingly.

**Step 3: Verify it compiles**

```bash
clang++ -std=c++17 -ObjC++ -c engine/system/mac/sys_main.mm \
  -I. -framework Foundation -framework AppKit -o /tmp/sys_main.o
```

Expected: no errors.

**Step 4: Commit**

```bash
git add engine/system/mac/sys_main.mm
git commit -m "feat(mac): add sys_main.mm (paths, clipboard)"
```

---

### Task 4: `mac/sys_video.cpp` — window management

GLFW handles most of this. The file is short.

**Files:**
- Create: `engine/system/mac/sys_video.cpp`

**Step 1: Read the Windows reference**

```bash
cat engine/system/win/sys_video.cpp
```

Note the GLFW calls already present. On macOS, the main addition is the Retina hint.

**Step 2: Write `mac/sys_video.cpp`**

```cpp
// engine/system/mac/sys_video.cpp

#include "ui_local.h"
#include <GLFW/glfw3.h>

void SysVideo_Init() {
    // Enable Retina/HiDPI framebuffer
    glfwWindowHint(GLFW_COCOA_RETINA_FRAMEBUFFER, GLFW_TRUE);
    // Remaining window creation is handled by the shared engine/vid.cpp code
}
```

The shared `SysVideo_Init` may already exist in a common file — check for a `sys_video_common.cpp` or similar. If the Windows version calls GLFW directly, your macOS version adds only the Retina hint before those calls.

**Step 3: Verify it compiles**

```bash
clang++ -std=c++17 -c engine/system/mac/sys_video.cpp -I. -o /tmp/sys_video.o
```

Expected: no errors (missing GLFW headers at this stage is acceptable; resolve in Task 6).

**Step 4: Commit**

```bash
git add engine/system/mac/sys_video.cpp
git commit -m "feat(mac): add sys_video.cpp (GLFW Retina window)"
```

---

### Task 5: `mac/sys_opengl.cpp` — ANGLE Metal backend

**Files:**
- Create: `engine/system/mac/sys_opengl.cpp`

**Step 1: Read the Windows reference**

```bash
cat engine/system/win/sys_opengl.cpp
```

Note how it loads EGL/GLES. ANGLE on macOS uses the same EGL API; the difference is that on macOS you do not need `LoadLibrary` — link directly.

**Step 2: Write `mac/sys_opengl.cpp`**

```cpp
// engine/system/mac/sys_opengl.cpp
// Initialises ANGLE with the Metal backend via EGL.

#include "ui_local.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>

// ANGLE automatically selects the Metal backend on macOS when
// EGL_ANGLE_platform_angle_metal is present; no explicit selection needed.

void SysOpenGL_Init(EGLNativeWindowType window) {
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    // Remaining EGL initialisation is identical to the Windows path.
    // Delegate to shared sys_opengl_common.cpp if one exists,
    // otherwise mirror win/sys_opengl.cpp line-for-line from here.
}
```

> **Key difference from Windows:** On Windows the code may dynamically load `libEGL.dll`. On macOS, link `libEGL.dylib` directly via the CMake target — remove any `dlopen`/`GetProcAddress` calls.

**Step 3: Confirm it compiles**

```bash
clang++ -std=c++17 -c engine/system/mac/sys_opengl.cpp \
  -I. -Idep/angle/include -o /tmp/sys_opengl.o
```

Expected: no errors (missing ANGLE headers at this stage is acceptable; resolve in Task 6).

**Step 4: Commit**

```bash
git add engine/system/mac/sys_opengl.cpp
git commit -m "feat(mac): add sys_opengl.cpp (ANGLE Metal EGL init)"
```

---

### Task 6: `mac/entry.cpp` — launcher entry point

**Files:**
- Create: `engine/system/mac/entry.cpp`

**Step 1: Read the Windows reference**

```bash
cat engine/system/win/entry.cpp
```

On Windows this is a DLL export. On macOS it is `main()` in the launcher binary.

**Step 2: Write `mac/entry.cpp`**

```cpp
// engine/system/mac/entry.cpp
// macOS entry point. Linked into the launcher binary (not a dylib export).

#include "ui_local.h"
#include <cstdlib>

// Forward declarations from sys_main.mm
void SysMain_Init(int argc, char** argv);
void SysMain_Run();

int main(int argc, char** argv) {
    SysMain_Init(argc, argv);
    SysMain_Run();
    return 0;
}
```

`SysMain_Run()` contains the GLFW run loop that already exists in the Windows code — move or call it from `sys_main.mm`.

**Step 3: Verify it compiles**

```bash
clang++ -std=c++17 -c engine/system/mac/entry.cpp -I. -o /tmp/entry.o
```

**Step 4: Commit**

```bash
git add engine/system/mac/entry.cpp
git commit -m "feat(mac): add entry.cpp (macOS main entry point)"
```

---

### Task 7: CMake — wire macOS sources and ANGLE dependency

**Files:**
- Modify: `CMakeLists.txt`
- Possibly modify: `vcpkg.json` or `vcpkg-configuration.json`

**Step 1: Locate the Windows-specific source block in `CMakeLists.txt`**

```bash
grep -n "win/" CMakeLists.txt | head -20
```

You will see something like:

```cmake
set(PLATFORM_SOURCES
    engine/system/win/entry.cpp
    engine/system/win/sys_main.cpp
    ...
)
```

**Step 2: Add macOS platform block**

Replace the platform sources section with:

```cmake
if(WIN32)
    set(PLATFORM_SOURCES
        engine/system/win/entry.cpp
        engine/system/win/sys_main.cpp
        engine/system/win/sys_video.cpp
        engine/system/win/sys_opengl.cpp
        engine/system/win/sys_console.cpp
    )
elseif(APPLE)
    set(PLATFORM_SOURCES
        engine/system/mac/entry.cpp
        engine/system/mac/sys_main.mm
        engine/system/mac/sys_video.cpp
        engine/system/mac/sys_opengl.cpp
        engine/system/mac/sys_console.cpp
    )
    # Enable Objective-C++ for .mm files
    set_source_files_properties(
        engine/system/mac/sys_main.mm
        PROPERTIES COMPILE_FLAGS "-ObjC++"
    )
endif()
```

**Step 3: Add ANGLE and Cocoa link targets for macOS**

Find the `target_link_libraries` call for the main target and add:

```cmake
if(APPLE)
    target_link_libraries(SimpleGraphic PRIVATE
        "-framework Foundation"
        "-framework AppKit"
        "-framework Metal"
        "-framework QuartzCore"
        EGL          # from ANGLE vcpkg
        GLESv2       # from ANGLE vcpkg
    )
endif()
```

**Step 4: Add code-signing step**

```cmake
if(APPLE)
    add_custom_command(TARGET PathOfBuilding POST_BUILD
        COMMAND codesign --force --sign - $<TARGET_FILE:PathOfBuilding>
        COMMENT "Ad-hoc code signing launcher"
    )
endif()
```

**Step 5: Check if ANGLE is available in vcpkg for macOS**

```bash
cat vcpkg.json | grep -i angle
```

If ANGLE is not listed, add it. Then run:

```bash
vcpkg install --triplet arm64-osx
```

If the ANGLE port does not exist for `arm64-osx`, you need a vcpkg overlay port. Check `vcpkg-ports/` — if there is a custom ANGLE port there already, enable it for macOS by adding `arm64-osx` to its supported triplets list.

**Step 6: Attempt a CMake configure**

```bash
cmake -B build-mac -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DCMAKE_TOOLCHAIN_FILE=./vcpkg/scripts/buildsystems/vcpkg.cmake .
```

Expected: CMake configuration succeeds. Fix any missing `find_package` calls before proceeding.

**Step 7: Commit**

```bash
git add CMakeLists.txt vcpkg.json vcpkg-configuration.json
git commit -m "build(mac): add macOS platform sources and ANGLE/Cocoa link targets"
```

---

### Task 8: Full macOS build and smoke test

**Files:** No new files; iterative fixes to existing code.

**Step 1: Attempt a full build**

```bash
cmake --build build-mac --target PathOfBuilding -- -j$(sysctl -n hw.logicalcpu)
```

This will fail. Work through each compiler error systematically:
- Missing includes: add `#ifdef __APPLE__` guards or macOS-specific headers
- `HWND`/Win32 types used in shared headers: add forward declarations or `#ifdef _WIN32` guards
- `__declspec(dllexport)` on shared interfaces: guard with `#ifdef _WIN32`

**Step 2: Run the binary bare (no Lua yet)**

```bash
./build-mac/PathOfBuilding
```

Expected: window opens, then crashes when it cannot find Lua files. That is acceptable — it confirms the C++ layer works.

**Step 3: Point the binary at the PoB2 repo Lua files**

```bash
./build-mac/PathOfBuilding /path/to/PathOfBuilding-PoE2/src/Launch.lua
```

Expected: Path of Building loads and the UI appears.

**Step 4: Run the headless smoke test**

```bash
./build-mac/PathOfBuilding /path/to/PathOfBuilding-PoE2/src/HeadlessWrapper.lua \
  -- "https://pobb.in/SOME_SHARE_CODE"
```

Expected: DPS output printed to stdout without errors.

**Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix(mac): resolve build errors for arm64 macOS"
```

---

### Task 9: CMake INSTALL target and dylib packaging

**Files:**
- Modify: `CMakeLists.txt`

**Step 1: Add macOS INSTALL rules**

Find the existing `install()` commands (used for Windows DLL deployment) and add macOS equivalents:

```cmake
if(APPLE)
    install(TARGETS PathOfBuilding
        RUNTIME DESTINATION MacOS)
    install(FILES
        $<TARGET_FILE:SimpleGraphic>
        $<TARGET_FILE:lua51>
        ${ANGLE_EGL_LIB}
        ${ANGLE_GLES_LIB}
        ${LCURL_LIB}
        ${LZIP_LIB}
        ${LUAUTF8_LIB}
        ${SOCKET_LIB}
        DESTINATION Frameworks)
endif()
```

**Step 2: Run the install target**

```bash
cmake --install build-mac --prefix /tmp/pob-mac-install
ls /tmp/pob-mac-install/
```

Expected: `MacOS/` and `Frameworks/` directories with the correct files.

**Step 3: Commit**

```bash
git add CMakeLists.txt
git commit -m "build(mac): add macOS INSTALL target rules"
```

---

## PoB2 Repo Tasks

> **Working directory for Tasks 10–14:** `/Users/dustinbone/Documents/GitHub/PathOfBuilding-PoE2`, branch `feature/mac-os-port`.

---

### Task 10: `package-macos.sh` — `.app` bundle assembly

**Files:**
- Create: `package-macos.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# package-macos.sh — assembles Path of Building-PoE2.app from:
#   $1 = path to the CMake INSTALL output (contains MacOS/ and Frameworks/)
#   $2 = output directory (default: ./dist)

set -euo pipefail

INSTALL_DIR="${1:?Usage: $0 <install-dir> [output-dir]}"
OUT_DIR="${2:-./dist}"
APP="$OUT_DIR/Path of Building-PoE2.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"

# Binaries from CMake install
cp -R "$INSTALL_DIR/MacOS/"*       "$CONTENTS/MacOS/"
cp -R "$INSTALL_DIR/Frameworks/"*  "$CONTENTS/Frameworks/"

# Lua sources and runtime assets from this repo
cp -R runtime/lua                  "$CONTENTS/Resources/runtime/"
cp -R runtime/SimpleGraphic        "$CONTENTS/Resources/runtime/"
cp -R src                          "$CONTENTS/Resources/"
cp changelog.txt LICENSE.md help.txt "$CONTENTS/Resources/"

# Info.plist
cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Path of Building-PoE2</string>
  <key>CFBundleIdentifier</key>
  <string>com.pathofbuildingcommunity.pob2</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleExecutable</key>
  <string>Path of Building-PoE2</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

# Ad-hoc code sign (no Apple Developer account needed for local builds)
codesign --deep --force --sign - "$APP"

echo "Built: $APP"
```

**Step 2: Make it executable**

```bash
chmod +x package-macos.sh
```

**Step 3: Run it against the Task 9 install output**

```bash
./package-macos.sh /tmp/pob-mac-install ./dist
open ./dist/
```

Expected: `Path of Building-PoE2.app` appears in Finder. Double-clicking it should launch PoB.

**Step 4: Commit**

```bash
git add package-macos.sh
git commit -m "build(mac): add package-macos.sh app bundle assembly script"
```

---

### Task 11: `src/Launch.lua` — macOS platform detection

**Files:**
- Modify: `src/Launch.lua`

**Step 1: Find the existing platform detection**

```bash
grep -n "versionPlatform\|platform" src/Launch.lua | head -20
```

**Step 2: Verify `GetUserPath()` is called correctly**

The C++ `SysGetUserPath()` already returns `~/Library/Application Support/Path of Building (PoE2)/`. Check whether `Launch.lua` calls `GetUserPath()` or constructs the path itself:

```bash
grep -n "GetUserPath\|userPath\|AppData" src/Launch.lua
```

If the Lua code hard-codes a Windows path (e.g. `%APPDATA%`), add a `platform == "mac"` guard. If it calls `GetUserPath()` unconditionally, no change is needed.

**Step 3: Add guard only if needed**

If a change is required, it will look like:

```lua
-- In launch:OnInit(), near path setup:
if launch.versionPlatform == "mac" then
    -- GetUserPath() already returns the correct macOS path from sys_main.mm
    -- No additional path manipulation needed
end
```

**Step 4: Confirm the headless smoke test still passes**

```bash
./dist/"Path of Building-PoE2.app"/Contents/MacOS/"Path of Building-PoE2" \
  src/HeadlessWrapper.lua -- "https://pobb.in/SOME_SHARE_CODE"
```

Expected: DPS output without errors.

**Step 5: Commit (only if changes were made)**

```bash
git add src/Launch.lua
git commit -m "fix(mac): handle macOS platform in Launch.lua path detection"
```

---

### Task 12: `manifest.cfg` and `update_manifest.py` — macOS manifest support

**Files:**
- Modify: `manifest.cfg`
- Modify: `update_manifest.py`

**Step 1: Add `[runtime-mac]` section to `manifest.cfg`**

Open `manifest.cfg` and append:

```ini
[runtime-mac]
path = runtime-mac
exclude-files =
exclude-directories =
```

**Step 2: Inspect `update_manifest.py`**

```bash
cat update_manifest.py
```

Find where it reads `manifest.cfg` sections and generates the XML. Understand the pattern before modifying.

**Step 3: Add `--platform` flag to `update_manifest.py`**

```python
# Near the top of the argparse setup, add:
parser.add_argument('--platform', choices=['windows', 'mac'], default='windows',
                    help='Target platform for the generated manifest')
```

In the section-processing loop, skip `[runtime]` when `--platform mac` and skip `[runtime-mac]` when `--platform windows`:

```python
for section in config.sections():
    if args.platform == 'mac' and section == 'runtime':
        continue
    if args.platform == 'windows' and section == 'runtime-mac':
        continue
    # existing processing ...
```

**Step 4: Generate and inspect a test macOS manifest**

```bash
python3 update_manifest.py --platform mac > /tmp/manifest-mac.xml
cat /tmp/manifest-mac.xml
```

Expected: contains `[runtime-mac]` file entries; does not contain Windows DLL entries.

**Step 5: Commit**

```bash
git add manifest.cfg update_manifest.py
git commit -m "feat(mac): add runtime-mac manifest section and --platform flag"
```

---

### Task 13: GitHub Actions CI workflow for macOS

**Files:**
- Create: `.github/workflows/build-macos.yml`

**Step 1: Write the workflow**

```yaml
# .github/workflows/build-macos.yml
name: Build macOS (arm64)

on:
  push:
    branches: [feature/mac-os-port, dev, master]
  pull_request:
    branches: [dev]
  release:
    types: [published]

jobs:
  build-macos:
    runs-on: macos-latest  # arm64 on GitHub-hosted runners as of 2024

    steps:
      - name: Checkout PoB2 repo
        uses: actions/checkout@v4

      - name: Checkout SimpleGraphic fork
        uses: actions/checkout@v4
        with:
          repository: YOUR_USERNAME/PathOfBuilding-SimpleGraphic
          ref: feature/macos-port
          path: SimpleGraphic

      - name: Install CMake and Ninja
        run: brew install cmake ninja

      - name: Configure SimpleGraphic
        working-directory: SimpleGraphic
        run: |
          cmake -B build -G Ninja \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DVCPKG_TARGET_TRIPLET=arm64-osx \
            -DCMAKE_TOOLCHAIN_FILE=./vcpkg/scripts/buildsystems/vcpkg.cmake

      - name: Build SimpleGraphic
        working-directory: SimpleGraphic
        run: cmake --build build --target PathOfBuilding -j4

      - name: Install SimpleGraphic
        working-directory: SimpleGraphic
        run: cmake --install build --prefix ../sg-install

      - name: Package .app bundle
        run: ./package-macos.sh ./sg-install ./dist

      - name: Run headless smoke test
        run: |
          ./dist/Path\ of\ Building-PoE2.app/Contents/MacOS/Path\ of\ Building-PoE2 \
            src/HeadlessWrapper.lua -- "https://pobb.in/KNOWN_SHARE_CODE"

      - name: Notarize (release only)
        if: github.event_name == 'release'
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
        run: |
          # Re-sign with Developer ID before notarizing
          codesign --deep --force \
            --sign "Developer ID Application: $APPLE_TEAM_ID" \
            dist/Path\ of\ Building-PoE2.app
          # Create zip for notarization
          ditto -c -k --keepParent \
            dist/Path\ of\ Building-PoE2.app \
            dist/Path-of-Building-PoE2-macos.zip
          xcrun notarytool submit dist/Path-of-Building-PoE2-macos.zip \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --wait
          xcrun stapler staple dist/Path\ of\ Building-PoE2.app

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: pob2-macos-arm64
          path: dist/Path-of-Building-PoE2-macos.zip
```

**Step 2: Replace `YOUR_USERNAME` and `KNOWN_SHARE_CODE`**

Replace `YOUR_USERNAME` with your GitHub username. Replace `KNOWN_SHARE_CODE` with a real PoB2 share code that has a known DPS output you can assert against in the smoke test. Update the smoke test assertion accordingly.

**Step 3: Commit**

```bash
git add .github/workflows/build-macos.yml
git commit -m "ci: add GitHub Actions macOS arm64 build workflow"
```

---

### Task 14: README — document macOS installation

**Files:**
- Modify: `README.md`

**Step 1: Add macOS section to Downloads**

Find the Downloads section in `README.md` and add:

```markdown
### macOS (Apple Silicon)

Download the latest `Path-of-Building-PoE2-macos.zip` from the
[Releases](https://github.com/YOUR_FORK/PathOfBuilding-PoE2/releases) page.

Unzip and move `Path of Building-PoE2.app` to your Applications folder.

**First launch:** macOS may block the app because it is from an unidentified
developer. Right-click the app and choose **Open**, then confirm. Alternatively,
run once in Terminal:

```sh
xattr -d com.apple.quarantine "/Applications/Path of Building-PoE2.app"
```

User data (builds, settings) is stored in:
`~/Library/Application Support/Path of Building (PoE2)/`
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add macOS installation instructions to README"
```

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-02-27-macos-port.md`.

**Two execution options:**

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open a new session with executing-plans, batch execution with checkpoints

**Which approach?**
