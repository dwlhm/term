# Getting Started with Term

Welcome to **Term**, a high-performance terminal emulator engineered from first principles in [Odin](https://odin-lang.org) on top of Native Apple Metal (`CAMetalLayer`) and a Standalone Headless Model Context Protocol ([MCP](https://modelcontextprotocol.io)) Server.

This guide covers system prerequisites, compilation workflows, application packaging, macOS Gatekeeper handling, test suite execution, and common troubleshooting steps.

---

## Prerequisites

Before building Term, ensure your development environment satisfies the following requirements:

| Component | Minimum Version | Installation / Verification |
|---|---|---|
| **Operating System** | macOS 11.0 (Big Sur) or newer | Apple Silicon (M1/M2/M3/M4) or Intel x86_64 |
| **Odin Compiler** | `dev-2026-08` or newer | Verify with `odin version` |
| **SDL3** | `3.0.0` or newer | `brew install sdl3` |
| **FreeType & HarfBuzz** | Latest stable | `brew install freetype harfbuzz` |
| **Build Automation** | Standard POSIX `make` | Xcode Command Line Tools (`xcode-select --install`) |
| **Swift Compiler** *(Optional)* | Swift 5.9+ | Included with Xcode / Command Line Tools (for `make bench-video`) |

### Installing Dependencies via Homebrew

```bash
# Install required libraries
brew install sdl3 freetype harfbuzz libpng graphite2 glib gettext pcre2

# Ensure Odin compiler is installed and up to date
brew install odin
# Or build the latest Odin dev release from source:
# git clone https://github.com/odin-lang/Odin.git && cd Odin && make
```

> [!NOTE]
> On Apple Silicon Macs, Homebrew installs dylibs to `/opt/homebrew/lib`. On Intel Macs, libraries reside in `/usr/local/lib`. Term's [`Makefile`](../Makefile) automatically includes both search paths via `-extra-linker-flags`.

---

## Building Term

Term provides dedicated targets for both the native desktop GUI and the standalone headless MCP server. All compiled outputs are placed in the `bin/` directory.

### Build Targets Matrix

| Command | Output Artifact | Description |
|---|---|---|
| `make build` | `bin/term` | Debug GUI executable with Odin debug symbols |
| `make release` | `bin/term` | Highly optimized GUI binary (`-o:speed -no-bounds-check`) |
| `make bundle` | `bin/Term.app` | Standalone macOS application bundle with embedded dylibs and fonts |
| `make install` | `/Applications/Term.app` | Installs bundled application to your system Applications folder |
| `make dmg` | `bin/Term.dmg` | Drag-and-drop app bundle and Applications alias |
| `make build-mcp` | `bin/term-mcp` | Debug standalone headless MCP server |
| `make release-mcp` | `bin/term-mcp` | Optimized release standalone headless MCP server |

### 1. Building the Desktop GUI

To compile the debug binary for active development:
```bash
make build
```

To compile the fully optimized release binary for production use:
```bash
make release
```

### 2. Creating the macOS Application Bundle (`Term.app`)

To produce a self-contained, standalone macOS application bundle:
```bash
make bundle
```

This target performs the following operations automatically:
1. Compiles the optimized release binary (`bin/term`).
2. Populates `Contents/MacOS/` and `Contents/Resources/`.
3. Copies application metadata (`assets/Info.plist`), multi-resolution app icons (`assets/term.icns`), and bundled typography (`assets/fonts/`).
4. Executes [`scripts/bundle_frameworks.sh`](../scripts/bundle_frameworks.sh), which copies all dynamic libraries (`SDL3`, `freetype`, `harfbuzz`, `libpng`, `graphite2`, `glib`, `intl`, `pcre2`) into `Contents/Frameworks/`, adjusts `@rpath` dependencies using `install_name_tool`, and applies ad-hoc codesigning.

To install directly to your user system:
```bash
make install
```

To generate a distributable compressed disk image (`Term.dmg`):
```bash
make dmg
```

The DMG contains `Term.app` and an **Applications** alias. Copy the app to **Applications** to install it. The Finder actions are native macOS Services declared in the app bundle; no separate installer or Automator workflow is required.

#### Using Finder Services

In Finder, select exactly one folder and choose **Open Term Here (Default Workspace)**, or select exactly one workspace file and choose **Restore Term Workspace**. The folder action searches supported folder-local defaults (`.default.term.odin`, `.term/default.odin`, `default.term.odin`, and their `.json` equivalents), then falls back to configured global defaults. If no valid default exists, Term logs a diagnostic and keeps running normally.

The workspace action accepts supported `.term.odin` and `.term.json` named layouts and `.term/<name>.odin` or `.term/<name>.json` layouts. Term validates the selected file contents. A missing or invalid workspace logs a diagnostic without disturbing existing tabs. When Term is already running, a valid selection opens in a new tab. On a cold launch, Term starts its ordinary initial session and also opens the requested workspace tab.

Relative layout and pane working directories resolve from the selected folder, or from the selected workspace file's containing folder. Explicitly stored absolute working directories remain authoritative. Finder passes paths as file URLs, so spaces and non-ASCII paths are supported. The legacy `--restore [name]`, `--restore-default-for <folder-path>`, and `--restore-file <workspace-file-path>` command-line options remain available.

If you previously installed the old `Open Term Here.workflow` or `Restore Term Workspace.workflow` manually, you may remove those old copies from `~/Library/Services`; Term does not modify that directory. If the bundled services do not appear in Finder after installing or updating Term, relaunch Finder (for example, Option-click Finder in the Dock and choose **Relaunch**) or log out and back in. Finder/Services GUI registration and refresh behavior should be verified on the target macOS version.

### 3. Building the Standalone Headless MCP Server (`term-mcp`)

Term includes a dedicated headless binary designed for autonomous AI coding agents (such as Claude Desktop, Cursor, or Codex) without Cocoa, SDL, or GPU dependencies:

```bash
# Debug build
make build-mcp

# Optimized release build
make release-mcp
```
The resulting executable is located at `bin/term-mcp`.

---

## Running Term

### Running from the Terminal

Launch the debug or release executable directly from your shell:
```bash
# Launch via Makefile (builds if necessary)
make run

# Or execute directly:
./bin/term
```

### Launching the macOS Application Bundle

```bash
open bin/Term.app
```

Or open `/Applications/Term.app` directly from Spotlight (`Cmd + Space`), Launchpad, or Finder.

### Launching the Standalone MCP Server

```bash
./bin/term-mcp
```
`term-mcp` listens on standard input (`stdin`) and writes responses to standard output (`stdout`) using the standard JSON-RPC 2.0 protocol. For AI agent configuration details, see [MCP Server Specification](mcp-server.md).

---

## macOS Gatekeeper & Ad-Hoc Code Signing

When distributing or running open-source macOS software without an Apple Developer Program identity certificate, macOS Gatekeeper may present security dialogs:

> [!WARNING]
> **"Term.app is damaged and can't be opened" or "Unidentified Developer" Prompt**:
> macOS places downloaded applications and unnotarized binaries into quarantine. Because Term uses ad-hoc codesigning (`codesign --force --deep --sign -`), Gatekeeper may block direct launch.

### Bypassing Gatekeeper Prompts

#### Method 1: Finder Right-Click (Recommended)
1. Locate `Term.app` in Finder (`bin/Term.app` or `/Applications/Term.app`).
2. Right-click (or `Control`-click) on `Term.app` and choose **Open**.
3. In the warning dialog that appears, click **Open**. macOS will remember this exception.

#### Method 2: Strip Quarantine Attributes via Terminal
If you built or copied the application manually, remove the quarantine attribute:
```bash
# For installed app:
xattr -d com.apple.quarantine /Applications/Term.app 2>/dev/null || true

# For local build artifact:
xattr -d com.apple.quarantine bin/Term.app 2>/dev/null || true

# Or recursively clear all attributes:
xattr -cr /Applications/Term.app
```

---

## Running Tests & Type Checks

Term maintains a comprehensive test suite covering terminal emulation correctness, parser state transitions, PTY semantics, input translation, UI components, rendering, and MCP protocols.

### 1. Semantic Analysis & Typechecking (`make check`)

Run Odin compiler checks across all source packages without emitting binary code:
```bash
make check
```
This validates all 12 modules: `src/app`, `src/session_core`, `src/cmd/term_mcp`, `src/terminal`, `src/parser`, `src/render`, `src/platform`, `src/config`, `src/ui`, `src/interaction`, `src/diag`, and `src/bench/probe`.

### 2. Comprehensive Unit Test Suite (`make test`)

Execute all 13 test suites sequentially:
```bash
make test
```
The master test command runs:
- `test-config`: Configuration parser, theme loader, option clamping.
- `test-terminal`: Ring grid, damage tracking, cursor navigation, grapheme cluster storage.
- `test-parser`: Scalar VT state machine, CSI sequences, SGR color decoding, BCE conformance.
- `test-pty`: POSIX PTY allocation, non-blocking drain loops, process signals.
- `test-input`: Keycode mapping, modifier translation, Kitty keyboard protocol.
- `test-tabs`: Multi-tab management, tab reordering, title mutation.
- `test-ui`: UI layout, search overlay, status bars, session switcher filtering.
- `test-interaction`: Mouse click hit-testing, block/linear selection, URL extraction.
- `test-render`: Render compilation, atlas packing, dirty tracking, cell uniform layout.
- `test-app`: Main application coordinator, event loop dispatch.
- `test-bench`: Benchmark harness consistency and telemetry math.
- `test-mcp`: Headless JSON-RPC 2.0 tool endpoints and session lifecycle.
- `test-diag`: Internal diagnostics, latency ring, memory telemetry.
- `test-probe`: High-resolution timing probes and percentile counters.
- `test-session-core`: Hexagonal session core, ports, and detached session registry.

### 3. Headless MCP Server Tests (`make test-mcp`)

Run the dedicated test suite for the Model Context Protocol implementation:
```bash
make test-mcp
```

### 4. Microbenchmarks (`make bench-run`)

Compile and execute low-level microbenchmarks measuring parser throughput, grid scrolling latency, PTY transfer rate, and photon input response:
```bash
make bench-run
```

---

## Running the Video Telemetry Benchmark (`make bench-video`)

To stress-test Term's parser, grid damage tracking, TrueColor ARGB pipeline, and Metal GPU triple-buffering under sustained heavy load, run the high-framerate video benchmark:

```bash
make bench-video
```

### How It Works

1. The target compiles [`scripts/term_video_player.swift`](../scripts/term_video_player.swift) using `swiftc -O` into `bin/term_video_player`.
2. The player generates 60 FPS full-screen TrueColor procedural graphics (DOOM fire simulation or AVFoundation video decode) rendered via ANSI 24-bit background sequences:
   $$\text{ESC } [ 48 ; 2 ; R ; G ; B \text{ m }$$
3. Measures real-time frame rates, raw PTY stream throughput ($\text{MB/s}$), frame pacing jitter, and dropped frames directly on the terminal grid.

### Customizing Video Benchmark Flags

You can run the compiled player directly with custom parameters:

```bash
# Run procedural plasma animation for 10 seconds at 60 FPS
./bin/term_video_player --plasma --fps 60 --duration 10

# Play an actual video file (.mp4, .mov) via AVFoundation
./bin/term_video_player path/to/sample.mp4 --fps 60

# Stress test with full-height character blocks (doubles bandwidth throughput)
./bin/term_video_player --fire --full --duration 5
```

> [!TIP]
> Use this benchmark to visually verify that Term sustains **60 FPS** continuous TrueColor streaming with smooth Metal triple-buffering and zero screen tearing.

---

## Troubleshooting Guide

### 1. Missing SDL3 or HarfBuzz Libraries
**Symptom**: Linker error during compilation:
```
ld: library 'SDL3' not found
# or
ld: library 'harfbuzz' not found
```
**Cause**: Homebrew libraries are not installed or are not in the default linker path.
**Solution**:
1. Install the missing dependencies:
   ```bash
   brew install sdl3 freetype harfbuzz libpng
   ```
2. Check your architecture:
   - On Apple Silicon, verify libraries exist in `/opt/homebrew/lib`.
   - On Intel, verify libraries exist in `/usr/local/lib`.
3. If installed in a custom prefix, pass additional linker paths to Make:
   ```bash
   make COMMON_FLAGS='-extra-linker-flags:"-L/path/to/lib -framework Metal -framework MetalKit -framework Cocoa"'
   ```

### 2. Odin Compiler Version Mismatch
**Symptom**: Syntax or compiler errors in `src/`:
```
Syntax error: undefined directive or unrecognized intrinsic
```
**Cause**: Term uses modern Odin language features introduced in release `dev-2026-08+`.
**Solution**:
Verify your compiler version:
```bash
odin version
```
If your compiler is older than `dev-2026-08`, update Odin via Homebrew (`brew upgrade odin`) or build the latest release from the official [Odin repository](https://github.com/odin-lang/Odin).

### 3. PTY Fork Permission Denied / Operation Not Permitted
**Symptom**: Terminal crashes on launch with `posix_openpt failed` or shell subprocess fails to spawn.
**Cause**: macOS privacy controls (SIP/TCC) restricting pseudo-terminal allocation from sandboxed environments.
**Solution**:
- Ensure the parent terminal or IDE (Terminal.app, iTerm2, VS Code, Cursor) has permission to manage child processes.
- Navigate to **macOS System Settings** $\to$ **Privacy & Security** $\to$ **Developer Tools** and verify your shell is allowed.

### 4. Missing Font Glyphs or Fallback Box Characters
**Symptom**: Unicode symbols or Nerd Font icons display as missing glyph boxes (``).
**Cause**: System monospace font lacks specialized glyphs.
**Solution**:
Term automatically embeds and falls back to:
- `assets/fonts/MapleMono-NF-Regular.ttf`
- `assets/fonts/SymbolsNerdFontMono-Regular.ttf`

When running the standalone app bundle (`Term.app`), these fonts are read directly from `Contents/Resources/fonts/`. When running `./bin/term` from source, ensure the process is executed from the repository root so relative paths to `assets/fonts/` resolve properly.

---

## Next Steps

Now that you have compiled and launched Term, explore the rest of the documentation:

- **[User Guide](user-guide.md)**: Master keyboard navigation, multi-tab workflows, and the session switcher palette (`Cmd+O`).
- **[Configuration Guide](configuration.md)**: Customize fonts, window translucency, vibrancy blur, and custom keybindings.
- **[Architecture Specification](architecture.md)**: Dive into the hexagonal core, scalar VT parser, and adaptive Metal GPU pipeline.
- **[MCP Server Specification](mcp-server.md)**: Connect `term-mcp` to autonomous AI coding workflows.
