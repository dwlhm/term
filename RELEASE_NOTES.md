# Release Notes - Term v0.4.1

Term v0.4.1 introduces automated multi-platform CI/CD for Linux and macOS, attaches standalone Linux distribution tarballs with an FHS-compliant installer to GitHub Releases, and documents installation and source builds across major Linux distributions.

---

## 🌟 Highlights & Major Features

### 1. Automated Linux CI & Release Matrix in GitHub Actions (`.github/workflows/`)
- **Continuous Integration Matrix (`ci.yml`)**: Added the `build-linux` workflow alongside `build-macos` on `ubuntu-latest`. Automated pipeline executes Odin type checks (`make check`), headless test suites under virtual framebuffer (`xvfb-run --auto-servernum make test`), optimized release compilation (`make release`), MCP server builds (`make release-mcp`), and packaging verification (`make dist-linux`).
- **Concurrent Multi-Platform Release Builds (`release.yml`)**: Split release workflows into concurrent `build-macos` and `build-linux` runner jobs that compile, package, and upload platform-specific distribution archives.
- **Unified Release Publishing**: Added `publish-release` coordination job that aggregates macOS and Linux artifacts into a unified staging area, generates `SHA256SUMS.txt`, and publishes all release assets in a single GitHub release.

### 2. Standalone Linux Distribution Tarballs with FHS Installer
- **Prebuilt Linux Distribution Archive**: Releases now provide `term-v0.4.1-linux-x86_64.tar.gz` containing the optimized `term` executable, bundled Nerd Fonts, FreeDesktop desktop entry (`term.desktop`), high-resolution application icons, and an FHS-compliant `install.sh`.
- **Flexible Installation Script**: Standalone `install.sh` enables zero-effort global installation (`sudo ./install.sh` to `/usr/local`) or unprivileged user installations (`./install.sh --prefix ~/.local`).
- **Linux Headless MCP Server**: Releases publish standalone `term-mcp-linux-x86_64.tar.gz` for headless terminal automation with AI coding agents on Linux systems.

### 3. Expanded Setup & Distribution Documentation (`README.md`)
- **Prebuilt Installation Instructions**: Documented installation workflows for macOS (DMG / tarball) and Linux (standalone release archive).
- **Comprehensive Linux Prerequisites**: Added exact dependency installation commands for Ubuntu/Debian (`apt`), Arch Linux (`pacman`), and Fedora (`dnf`), as well as build and install commands (`make build`, `make release`, `make run`, `sudo make install`, `make dist-linux`).

---

# Release Notes - Term v0.4.0

Term v0.4.0 is a major milestone release introducing Split Panes, Session Registry mobility, Cross-Platform Linux POSIX & WGPU support, native macOS Finder Services, and dynamic Git-derived build versioning.

---

## 🌟 Highlights & Major Features

### 1. Split Panes & Pane Management (`src/app`, `src/session_core`)
- **Arbitrary Pane Splitting**: Split any active terminal horizontally or vertically with isolated PTY execution, dynamic split ratio adjustment, and focused pane navigation.
- **CWD Inheritance**: Child split panes automatically discover and inherit the working directory of the currently focused sibling pane.
- **Context-Aware Pane Lifecycle**: Clean pane closure with tree collapsing and automatic focus handover to adjacent panes.

### 2. Session Registry & Workspace Mobility (`src/app/session.odin`)
- **Detached Session Migration**: Seamlessly detach long-running terminal sessions to the background registry and restore them into new or existing tabs.
- **Enhanced Switcher Affordances**: Interactive session switcher with pane hierarchy indicators, per-row close actions, and context menu controls.

### 3. Cross-Platform Linux & WGPU Rendering Architecture (`src/platform`, `src/render`)
- **POSIX Platform Decoupling**: Abstracted platform event loops, timers, and PTY lifecycles into clean platform adapters, separating Darwin-specific Cocoa logic from POSIX/Linux subsystems.
- **Multi-Backend Shader Dispatch**: Introduced shader language abstraction supporting both native Metal Shading Language (MSL) and WebGPU Shading Language (WGSL).
- **Linux Packaging**: Added standard Linux FHS installation targets (`make install`, `assets/term.desktop`) and standalone tarball packaging (`scripts/package_linux.sh`).

### 4. Native macOS Finder Services (`src/app/macos_services.m`)
- **System Services Integration**: Added native macOS Finder Services (`Open in Term`, `New Workspace Here`) accessible via system menus and context clicks in macOS Finder.
- **Service Request Queueing**: Thread-safe Cocoa service event queue dispatching folder paths directly to the terminal workspace manager.

### 5. Git-Derived Dynamic Versioning (`scripts/resolve_version.py`)
- **Compile-Time Git Metadata**: Automated version calculation resolving semantic version tags, commit distance, commit hashes, and dirty worktree flags into `src/build_info/version.odin` and `bin/Info.plist`.
- **Deterministic Release Stamping**: Strict tag validation ensuring release tags match repository HEAD.

---

## 🐛 Bug Fixes & Refinements

### 1. Tab Bar Layout & Backfilling (`src/platform/tabs`)
- **Overflow Strip Backfilling**: Closing tabs or resizing viewports now automatically backfills previously scrolled tabs into the visible strip instead of leaving blank tab slots.
- **Deterministic Rect Cleanup**: Full tab rect slices are passed during layout passes to ensure closed tab slots are zeroed out and do not intercept click hit tests.

### 2. Bell Notification Lifecycle (`src/app/session.odin`)
- **Active Tab Suppression**: Bell notification indicators are suppressed on the currently active tab where output is immediately visible.
- **Pane Focus Clearance**: Switching tabs or focusing pane trees immediately resets bell notification badges across all split pane leaves.

### 3. Protocol & Emulation Compatibility
- **Ghostty & Modern Protocol Alignment**: Support for `XTVERSION`, `DECRQM`, and Kitty graphics query sequences.
- **Cursor State Preservation**: Implemented CSI s / CSI u cursor save and restore sequences and cursor movement commands (CSI E / CSI F).
- **Text Selection & Clipboard**: Fixed multi-line selection preservation and clipboard copying behavior.

---

# Release Notes - Term v0.3.2

Term v0.3.2 introduces true standalone macOS application bundling with dynamic library relocation and comprehensive third-party open-source license compliance.

---

## 📦 Standalone Packaging & Portability

### 1. Dynamic Library Relocation & Framework Bundling
- **Zero-Dependency macOS App Bundle**: `scripts/bundle_frameworks.sh` automatically resolves, copies, and relocates all 8 non-system dynamic libraries (`libfreetype.6.dylib`, `libharfbuzz.0.dylib`, `libSDL3.0.dylib`, `libpng16.16.dylib`, `libgraphite2.3.dylib`, `libglib-2.0.0.dylib`, `libintl.8.dylib`, `libpcre2-8.0.dylib`) into `Term.app/Contents/Frameworks/`.
- **RPATH Integration**: The main binary and frameworks are rewritten using `install_name_tool` to reference `@rpath/<dylib>` with `@executable_path/../Frameworks`, allowing `Term.app` and `Term.dmg` to run seamlessly on any macOS system without Homebrew.
- **Inside-Out Ad-Hoc Codesigning**: Bundled frameworks and the main executable are signed with `assets/Term.entitlements` (Hardened Runtime permissions for library loading and JIT).

## 📜 License Compliance & Third-Party Notices

### 1. SIL Open Font License 1.1 Compliance
- Added official license files [`assets/fonts/OFL-MapleMono.txt`](assets/fonts/OFL-MapleMono.txt) and [`assets/fonts/OFL-SymbolsNerdFont.txt`](assets/fonts/OFL-SymbolsNerdFont.txt), fulfilling Condition 2 of the SIL Open Font License 1.1 for bundled font distribution.
- Preserved font license text in `Term.app/Contents/Resources/fonts/`.

### 2. Comprehensive Third-Party Attribution
- Added [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) documenting copyrights, licenses, and acknowledgments for FreeType (FTL), HarfBuzz (MIT), SDL3 (zlib), libpng, Graphite2, GLib, gettext, PCRE2, and embedded fonts.
- Updated `README.md` license section and added Gatekeeper guidance for macOS open-source DMG releases.

---

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
