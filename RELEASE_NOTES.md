# Release Notes - Term v0.3.1

Term v0.3.1 is a targeted bugfix release resolving an issue where Nerd Font icons and prompt symbols were missing when Term was installed and run from the macOS `.dmg` package or application bundle.

---

## 🐛 Bug Fixes & Bundle Hardening

### 1. Application Bundle Font & Fallback Resolution
- **Executable-Relative Bundle Font Discovery**: `src/app/frontend.odin` now dynamically resolves the running binary's path (`/Applications/Term.app/Contents/MacOS/term`) to locate bundled fonts under `Term.app/Contents/Resources/fonts/`.
- **Persistent Fallback Font Chain**: Candidate fallback paths (`FALLBACK_FONT_PATHS`) are now properly expanded through `frontend_font_paths` during both startup and runtime zoom re-initialization (`frontend_apply_zoom`), ensuring `SymbolsNerdFontMono-Regular.ttf` is always active in the fallback rasterization chain.
- **Apple ATS Registration**: Added `<key>ATSApplicationFontsPath</key><string>fonts</string>` in `assets/Info.plist` to register bundled fonts with Apple Type Services.

### 2. Build Pipeline & CI/CD Verification
- **Bundle Idempotency**: `Makefile` now cleans existing bundled font directories before copying assets to prevent nested duplication.
- **CI & Release Pipeline Assertions**: Added explicit file assertions in `.github/workflows/ci.yml` and `.github/workflows/release.yml` to guarantee `MapleMono-NF-Regular.ttf` and `SymbolsNerdFontMono-Regular.ttf` exist in `bin/Term.app/Contents/Resources/fonts/` before creating DMG images and release archives.

---

# Release Notes - Term v0.3.0

Term v0.3.0 is a major milestone introducing a unified Hexagonal Core (`src/session_core`), a standalone headless Model Context Protocol (MCP) server (`bin/term-mcp`), direct Apple Metal native rendering integration (`CAMetalLayer`), and a comprehensive 11-suite output-aware benchmark test suite.

---

## 🌟 Highlights & Major Features

### 1. Standalone Headless MCP Server (`bin/term-mcp`)
- **Zero-Dependency Mach-O Binary**: Standalone ~900 KB binary without dynamic runtime dependencies (no Node.js, Python, Electron, Cocoa, or GPU/X11 requirements).
- **7 MECE Core Automation Tools**: Implements `terminal_create_session`, `terminal_close_session`, `terminal_run_command`, `terminal_send_input`, `terminal_send_key`, `terminal_get_screen`, and `terminal_resize` over JSON-RPC 2.0 stdio.
- **Deterministic Dual-Completion Detection**: Uses OSC 133 prompt notifications and canary fallback to eliminate polling delays and guarantee accurate command status and exit codes without terminal escape pollution.

### 2. Hexagonal Core Architecture (`src/session_core`)
- **Decoupled Ports and Adapters**: Establishes clean architectural boundaries with [`Terminal_Control_Port`](file:///Users/dwlhm/project/term/src/session_core/ports.odin) and [`Terminal_Observer_Port`](file:///Users/dwlhm/project/term/src/session_core/ports.odin#L11-L17), separating POSIX PTY management and VT grid manipulation from user interfaces.
- **Dual Execution Profiles**:
  * **`Fast_Headless` Mode (Default)**: Purpose-built for AI coding agents. Strips shell prompt baggage, unsets ZLE and precmd latency, and achieves 0.27 ms command latency and >80 MB/s stream throughput while preserving the user's complete shell environment and `$PATH`.
  * **`Interactive_GUI` Mode**: Dedicated profile for the desktop emulator, handling shell dotfiles (`.zshrc`), interactive line-editing, and continuous visual presentation.

### 3. Direct Apple Metal Native Rendering Integration (`CAMetalLayer`)
- **Native Metal Presentation**: Re-architected `src/app` and `src/platform/window` directly on top of native Apple Metal and `CAMetalLayer`, eliminating legacy WGPU abstractions and intermediate translation overhead.
- **Aspect Ratio & Reflow Stability**: Native display backing scale factor and top-left layer gravity (`kCAGravityTopLeft`) eliminate resize pillarboxing and bilinear stretching artifacts.

### 4. Comprehensive 11-Suite Output-Aware Benchmark Suite (`make bench-mcp`)
- **Automated Verification Harness**: 11 dedicated benchmark suites validating handshake latency, multi-session scaling, RSS memory footprint, 2D screen snapshots, dynamic resizing, and multi-command chaining.
- **100% Assertion Verification**: 103/103 assertions verified with 0.0% error rate across all suites.
- **Empirical Win Margins**: 105× lower latency than Node.js (0.27 ms vs 28.5 ms) and 44× lower physical RSS memory (1.92 MB vs 84.5 MB).

---

# Release Notes - Term v0.2.2

Term v0.2.2 is a maintenance and stability patch release focused on build pipeline optimization, phantom dependency eradication, and CI/CD timing resilience.

---

## 🚀 Improvements & Pipeline Polish

### 1. Complete WGPU Dependency Eradication
- Eliminated legacy top-level `vendor:wgpu` imports from `src/app/frontend.odin` and removed obsolete `wgpu` package.
- Removed `setup-wgpu` prebuilt binary downloads from `Makefile` and GitHub Actions workflows, streamlining CI duration.
- Confirmed 100% native Apple Metal backend execution on macOS.

### 2. CI/CD Test Suite Timing Stabilization
- Added CPU instruction and branch predictor cache warmup to `test_raster_ascii_gate` in `src/render/tests/raster_async_test.odin`.
- Enhanced timing tolerance on virtualized GitHub Actions runners (`macos-14`) to eliminate non-deterministic CI test failures caused by VM scheduling noise.

---

# Release Notes - Term v0.2.1

Term v0.2.1 is a patch release focused on rendering polish, window resize resilience, and terminal reflow stability on macOS.

---

## 🐛 Bug Fixes & Improvements

### 1. macOS Live Window Resize Font Stability
- Fixed an issue where glyphs momentarily stretched horizontally and snapped back during live window resize.
- Explicitly configured `CAMetalLayer` with `kCAGravityTopLeft` and native display `backingScaleFactor` so stale frames remain pinned 1:1 at the top-left rather than being bilinearly distorted by CoreAnimation before the next GPU frame completes.

### 2. Elimination of Window Resize Pillarboxing
- Fixed a bug where resizing the window wider resulted in a solid black column on the right side of the window (pillarboxing).
- Removed AppKit `NSViewLayerContentsPlacement` and `layerContentsRedrawPolicy` interference that previously locked view aspect ratios.
- Streamlined `_app_event_watch` to immediately redraw intermediate frames across the entire window viewport during interactive resize.

### 3. Powerlevel10k & Multi-Line Prompt Resize Preservation
- Resolved a defect where resizing the window repeatedly added ghost newlines between the last command output and the zsh p10k prompt.
- Added prompt frame detection (`╭`, `╰`, `┌`, `└`) to preserve active prompt row heights without wrapping, allowing zsh ZLE redraw sequences (`\x1b[1A`) to cleanly clear and repaint the prompt without stranding ghost lines.
- Maintained 100% lossless VT reflow for all command outputs (`ls -l`, compiler logs, etc.).

---

# Release Notes - Term v0.2.0

Term v0.2.0 marks a major milestone in the evolution of Term as a next-generation, high-performance GPU-accelerated terminal emulator for macOS. Built from first principles in [Odin](https://odin-lang.org) with a Metal/wgpu rendering pipeline, this release introduces multi-tab session management, interactive UI chrome, full mouse text selection and hyperlink handling, native CoreText font fallback and advanced shaping (including ligatures and Arabic script), an optimized circular ring buffer with dynamic scrollback reflow, comparative benchmarking tooling, and native `.dmg` distribution packaging.

---

## 🌟 Highlights & Major Features

### 1. Multi-Tab Session Architecture & Decoupled Frontend Contract
- **Independent Sessions**: Run multiple isolated terminal sessions concurrently, each maintaining its own PTY lifecycle, VT state machine, scrollback history, and damage tracking.
- **Decoupled Frontend Interface**: Abstracted frontend interface contracts (`contract.odin` and `session.odin`) separating UI state, window events, and terminal engines for seamless multi-tab switching and lifecycle management.
- **Tab Lifecycle Management**: Full support for spawning, switching (`Cmd+1`..`Cmd+9`, `Cmd+Shift+[` / `]`), closing tabs (`Cmd+W`), and automatic session cleanup without memory leaks or zombie subprocesses.

### 2. Native UI Chrome: Tab Bar, Search Bar, Dialogs & Themes
- **Native Tab Bar**: GPU-rendered interactive tab bar with active tab indicators, hover states, tab close buttons, and title truncation.
- **In-Terminal Search Bar**: Fast, non-blocking search overlay (`Cmd+F`) supporting case-sensitive and regex matching, match count, and forward/backward navigation (`Enter` / `Shift+Enter`) with highlighted matches.
- **Confirmation Dialogs**: Built-in modal alerts for operations like closing tabs with running child processes.
- **Theme Subsystem**: Declarative color theme support with configurable palettes for standard ANSI colors, UI chrome elements, cursor highlights, and background opacity.

### 3. Interactive Text Selection, Mouse Support & Hyperlinks
- **Mouse Selection Modes**: Support for linear character selection, word selection (double-click), line selection (triple-click), and rectangular block selection.
- **Interactive Overlay**: High-efficiency Metal overlay pipeline rendering selections with zero grid mutation.
- **Hyperlink Detection & Opening**: Automatic URL detection with hover underline indicators and `Cmd+Click` to open links in default macOS browser (OSC 8 protocol and regex matching).
- **Clipboard Integration**: Seamless `Cmd+C` copy to macOS system pasteboard and bracketed paste handling (`Cmd+V`).

### 4. Advanced Typography: CoreText FFI, Ligature Caching & Arabic Shaping
- **CoreText FFI Integration**: Direct integration with macOS CoreText APIs for native system font discovery, query, and fallback resolution.
- **Ligature Shaping**: Multi-glyph ligature detection and rasterization caching with LRU shape cache for coding fonts (Fira Code, JetBrains Mono, Maple Mono).
- **Arabic Script Shaping**: Contextual bidirectional and Arabic character joining (isolated, initial, medial, final presentation forms) with correct visual rendering.
- **Color Emoji & Symbol Fallback**: Seamless multi-tier font fallback spanning symbols, Nerd Fonts, and Apple Color Emoji.

### 5. Ring Buffer Scrollback & Dynamic Reflow Resilience
- **$\mathcal{O}(1)$ Circular Ring Buffer**: Zero-copy circular row indexing for terminal grid and history scrollback, eliminating expensive `memmove` bottlenecks.
- **Dynamic Scrollback Reflow**: Line-wrapping reflow preserves continuous command output across terminal resize events (`SIGWINCH` / `TIOCSWINSZ`).
- **Alternate Screen Buffer Resilience**: Robust state restoration when toggling between primary and alternate screen buffers (e.g. `vim`, `less`, `tmux`) with damage boundary tracking.

### 6. Comparative Benchmarking Suite & DMG Installer
- **Comparative Benchmarking Tooling**: Automated test runner (`scripts/bench_comparative.sh`) benchmarking throughput, latency, and memory against Alacritty and Ghostty using standardized `vtebench` payloads.
- **Metal System Trace Integration**: Measurement methodology for GPU frame times, present deadlines, and VSync pacing.
- **macOS Disk Image (`.dmg`) Installer**: Complete `make dmg` build target generating distributable UDZO-compressed `.dmg` disk image with application drag-and-drop staging.

---

## 🛠 Detailed Changelog

### Terminal Subsystem (`src/terminal/`)
- Optimized ring buffer index calculation and flat row storage.
- Implemented reflow algorithm for history scrollback upon resize.
- Added comprehensive unit tests for alt-screen resize, grapheme clusters, and history counters.

### Parser & Protocols (`src/parser/`)
- Enhanced CSI sequence parser for modern CLI protocols (Kitty keyboard protocol, OSC 133 shell integration, OSC 8 hyperlinks).
- Extended Fish shell compatibility and synchronized output (`CSI ? 2026`).

### Platform & OS Integration (`src/platform/`)
- Improved Cocoa window handling, keyboard pump latency, and modifier reporting.
- Hardened POSIX PTY spawn, non-blocking drain loops, and child exit handling.

### Render Pipeline (`src/render/`)
- Integrated CoreText FFI for system font fallback.
- Added ligature cache, contextual Arabic shaping, and interaction selection overlay.
- Added tests for ligature caching, fallback shaping, and atlas pressure.

### Configuration (`src/config/`)
- Added configuration loader and parser supporting custom keybindings, font sizing, and visual themes.

### UI & Interaction Subsystems (`src/ui/`, `src/interaction/`)
- Implemented mouse event dispatcher, selection state machine (FSM), and query engine.
- Implemented tab bar, search bar, and confirmation dialog UI render passes.

### App Subsystem (`src/app/`)
- Architected multi-tab session manager and decoupled frontend event contract.
- Added layout regression and history lifecycle unit tests.

### Build & Packaging
- Added `Makefile` targets: `bundle`, `install`, `dmg`.
- Updated `Info.plist` with version `0.2.0` (build `2`).
- Added comparative benchmarks documentation and test scripts.
