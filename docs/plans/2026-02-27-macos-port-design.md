# macOS Native Port — Design

**Date:** 2026-02-27  
**Branch:** `feature/mac-os-port`  
**Status:** Approved, pending implementation plan  

---

## Goal

Produce a native macOS arm64 `.app` bundle for Path of Building (PoE2) that runs entirely without Wine or emulation. The work spans two repositories: the C++ runtime (`PathOfBuilding-SimpleGraphic`) and this Lua repository. Design it cleanly enough to upstream to both `PathOfBuildingCommunity` repos, but ship from personal forks first.

---

## Architecture Overview

The application has two layers:

1. **C++ runtime (`SimpleGraphic`)** — hosts LuaJIT, renders via OpenGL ES, manages the window, handles input, and provides platform APIs to Lua.
2. **Lua game logic (this repo)** — entirely platform-agnostic; requires no changes for basic functionality.

The macOS port replaces the Windows-only `runtime/` binaries with macOS equivalents and adds a new OS system layer to SimpleGraphic. GLFW (windowing) and ANGLE (OpenGL ES on Metal) already support macOS and need no code changes — only CMake wiring.

---

## Part 1: SimpleGraphic C++ System Layer

Fork `PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic`. Add `engine/system/mac/` mirroring the existing `engine/system/win/` structure.

### Files

**`mac/entry.cpp`**  
The macOS entry point. Compiles directly into the launcher binary (no DLL load step). Creates the system main module and calls `RunLuaFile`.

**`mac/sys_main.cpp`**  
OS interface: file paths, clipboard, process spawning, and the main run loop.

- `GetUserPath()` returns `~/Library/Application Support/Path of Building (PoE2)/`
- Clipboard uses `NSPasteboard` via a thin Objective-C++ shim (`NSPasteboardTypeString`)
- Creates the user data directory on first launch via `NSFileManager`; failure is fatal with an `NSAlert` dialog

**`mac/sys_video.cpp`**  
Window creation and management. GLFW abstracts nearly all of this. The one macOS-specific call is:

```cpp
glfwWindowHint(GLFW_COCOA_RETINA_FRAMEBUFFER, GLFW_TRUE);
```

**`mac/sys_opengl.cpp`**  
Initialises ANGLE with the Metal backend. ANGLE's `libEGL` + `libGLESv2` use the same API surface as on Windows; the engine's OpenGL initialisation code is unchanged. ANGLE's Metal backend has been production-stable since 2022.

**`mac/sys_console.cpp`**  
Writes the debug console to `stderr`. Visible in Terminal and Console.app. No separate window needed — a significant simplification over the Windows version.

### CMake Changes

- Add `if(APPLE)` blocks to select `mac/` source files in place of `win/`
- Add ANGLE as a vcpkg dependency targeting the Metal backend
- Add a code-signing step for the launcher binary (required for Gatekeeper on macOS 10.15+)
- GLFW already has macOS support in vcpkg; no changes needed

### Build Output

| File | Purpose |
|---|---|
| `Path of Building-PoE2` | Native Mach-O launcher binary |
| `SimpleGraphic.dylib` | Lua host and renderer |
| `lua51.dylib` | LuaJIT runtime |
| `libEGL.dylib`, `libGLESv2.dylib` | ANGLE Metal backend |
| `lcurl.dylib`, `lzip.dylib`, `lua-utf8.dylib`, `socket.dylib` | Lua extensions |

---

## Part 2: PoB2 Repo Integration

### `.app` Bundle Structure

```
Path of Building-PoE2.app/
  Contents/
    Info.plist
    MacOS/
      Path of Building-PoE2          ← launcher binary
    Frameworks/
      SimpleGraphic.dylib
      lua51.dylib
      libEGL.dylib  libGLESv2.dylib
      lcurl.dylib   lzip.dylib
      lua-utf8.dylib  socket.dylib
    Resources/
      runtime/lua/                   ← Lua stdlib (from current runtime/lua/)
      runtime/SimpleGraphic/Fonts/
      src/                           ← all Lua game source
      changelog.txt
      LICENSE.md  help.txt
```

`package-macos.sh` (repo root) assembles this from the CMake `INSTALL` output and repo Lua sources, then runs:

```sh
codesign --deep --force --sign - "Path of Building-PoE2.app"
```

Ad-hoc signing (`-`) works for local/developer builds. Release builds use a proper Apple Developer certificate and notarization.

### Lua Changes (`src/Launch.lua`)

The C++ layer sets `versionPlatform = "mac"`. `Launch.lua` already reads this field; add one `platform == "mac"` branch:

```lua
if launch.versionPlatform == "mac" then
    -- User data lives in ~/Library/Application Support/
    -- GetUserPath() already returns the correct path from sys_main.cpp
end
```

No other Lua changes are required for v1.

### Update System

Use whole-bundle replacement for v1:

1. Download the new release as a `.tar.gz` to a temp path
2. Verify checksum
3. Extract to a temp `.app` alongside the current one
4. Atomic swap (`mv`) — leaves the old bundle intact until the swap succeeds
5. Relaunch

This avoids macOS bundle integrity issues that arise from partial in-place updates to a signed `.app`.

### `manifest.cfg` Changes

Add a `[runtime-mac]` section:

```ini
[runtime-mac]
path = runtime-mac
exclude-files =
exclude-directories =
```

Extend `update_manifest.py` with a `--platform mac` flag to generate a macOS-specific `manifest.xml` pointing at the `.tar.gz` artifact.

### GitHub Actions CI

New workflow: `.github/workflows/build-macos.yml`

1. `macos-latest` runner (arm64)
2. Checkout this repo; pull SimpleGraphic fork as a dependency
3. Build SimpleGraphic with CMake
4. Run `package-macos.sh`
5. On release tags: notarize and staple via `xcrun notarytool` (secrets: `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`)
6. Upload `.tar.gz` as a release artifact

---

## Error Handling

| Scenario | Handling |
|---|---|
| ANGLE Metal init failure | `LuaError()` with human-readable message; clean exit |
| User data directory missing | Create on launch; fatal `NSAlert` if creation fails |
| Gatekeeper quarantine | Document `xattr -d com.apple.quarantine` in README; release builds are notarized |
| Update download interrupted | Download to temp path; atomic swap only on success |

---

## Testing Strategy

**Existing unit tests:** The Docker-based Lua suite (`spec/System/`) runs headlessly via `busted`. These pass unchanged on macOS — run them locally during development.

**Headless smoke test (CI):** Launch PoB with `HeadlessWrapper.lua` and a known build share code; assert DPS output matches expected values. Mirrors the existing Linux smoke test pattern.

**Manual acceptance checklist:**
- [ ] Window opens, title bar shows correct version
- [ ] Passive tree renders without artifacts
- [ ] Retina display: framebuffer is 2× pixel density
- [ ] Items import from clipboard
- [ ] Trade site HTTP request succeeds
- [ ] User data saves to `~/Library/Application Support/Path of Building (PoE2)/`

---

## Known Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ANGLE vcpkg port lacks macOS arm64 Metal support | Medium | ANGLE has an official Metal backend; a custom vcpkg port overlay may be needed. Fallback for v1: use deprecated system OpenGL. |
| Partial macOS work in SimpleGraphic is heavily bitrotted | Medium | Treat existing commits as reference only; implement fresh from the `win/` layer. |
| LuaJIT arm64 support gaps | Low | LuaJIT has supported arm64 since 2022 and runs well on Apple Silicon. |
| Notarization requires Apple Developer account | Low | Ad-hoc signing covers personal use; notarization applies only to public releases. |
| Font rendering differences | Low | SimpleGraphic renders fonts as textures via `stb_truetype` (CPU-side); rendering is platform-agnostic. |

---

## Out of Scope (v1)

- Intel (x86_64) or Universal binary support
- macOS-native menu bar integration
- Sparkle or other macOS-native auto-update framework
- App Store distribution
