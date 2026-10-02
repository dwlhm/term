# Term Documentation Index

Term is a high-performance terminal emulator engineered from first principles in [Odin](https://odin-lang.org) on top of Native Apple Metal (`CAMetalLayer`) and a Standalone Headless Model Context Protocol ([MCP](https://modelcontextprotocol.io)) Server.

This directory serves as the master documentation index and navigation hub for the Term project, detailing architectural specifications, configuration references, deployment guides, protocol implementations, and empirical benchmark results.

---

## High-Level Overview

Term is designed with a strict **measure-first engineering philosophy**: every optimization, data structure, and GPU pipeline stage is gated by empirical percentiles ($p_{50}, p_{95}, p_{99}, p_{99.9}$) rather than intuition. The architecture follows the shortest path from PTY bytes to displayed pixels:

```
PTY Bytes ──► Input Ring ──► VT State Machine ──► Ring Grid ──► Render Compiler ──► Adaptive GPU Strategy ──► Apple Metal Presentation
```

Unlike traditional terminal emulators that rely on heavy web engines or generic rendering abstractions, Term couples low-level systems programming in Odin with native Apple Silicon hardware acceleration. The result is instant startup, sub-millisecond input response, flat $\mathcal{O}(1)$ scrolling latency, and steady-state zero memory allocations.

---

## Core Invariants

Term enforces four architectural invariants across all subsystems:

### 1. Steady-State Zero Allocations
After initial workspace configuration and buffer initialization, normal frame cycles perform **zero heap allocations**:
- **Preallocated Input Ring Buffers**: High-watermark ring buffers handle non-blocking asynchronous PTY drains.
- **Extended Grapheme Cluster (EGC) Pool**: Fixed-size $256 \times 4$ slot storage for complex multi-codepoint grapheme clusters.
- **Shape Cache**: 1,024-entry hash cache stores pre-shaped glyph metrics and HarfBuzz output.
- **GPU Texture Atlas**: Fixed 512-slot Least Recently Used (LRU) glyph cache with deterministic eviction.

### 2. Zero-Overhead ASCII Fast Path
Pure ASCII characters ($0\text{x}00 \text{ to } 0\text{x}7F$) bypass UTF-8 multi-byte decoding, multi-font cascading fallback, and HarfBuzz complex shaping entirely:
- Direct ASCII index into precomputed glyph metric tables.
- Emits raw vertex geometry directly into the render compilation buffer.
- Achieves $\sim 39\text{ MB/s}$ scalar ASCII throughput and $3.4\text{M}$ CSI escape sequences per second without SIMD overhead.

### 3. $\mathcal{O}(\text{changes})$ Work Complexity
Work performed per frame is strictly proportional to mutated state, never total screen dimensions:
- **Hierarchical Damage Tracking**: Three-tier damage tree (`cell` $\to$ `span` $\to$ `row`) isolates updated regions.
- **Circular Ring Grid**: Terminal scrollback updates adjust circular ring head/tail offsets without memory copying (`memmove`), yielding flat $251\text{--}275\text{ ns}$ scroll latency across $24 \to 192$ rows.
- **Minimal Dirty Uploads**: A single-cell modification transmits only $288\text{ B}$ over the PCIe/Unified Memory bus (versus $184,320\text{ B}$ for a full-screen upload — a $640\times$ bandwidth saving).

### 4. Idle Zero Work
When no PTY events arrive, no animations are active, and no damaged spans exist:
- Zero CPU thread wakeups.
- Zero frame recompilations or layout passes.
- Zero GPU command buffer allocations, encoding passes, or swapchain commits.

---

## Key Features & Verified Capabilities

### 🪟 Native macOS Vibrancy Blur & Translucency
- **NSVisualEffectView Integration**: Attaches a native Cocoa visual effect view behind the `CAMetalLayer` content view to render smooth system vibrancy blur.
- **Configurable Material & Opacity**: Managed declaratively via `window_opacity` ($0.1 \le \alpha \le 1.0$) and `window_blur` (`true`/`false`).
- **Zero-Overhead Opaque Path**: When opacity is $1.0$ and blur is disabled, no `NSVisualEffectView` is allocated, preserving maximum rendering performance.

### 🔄 Session Persistence, Detachment & Attachment
- **Persistent Core Sessions**: Detach active tabs into background-running sessions (`Option+Cmd+B` / `⌥⌘B`) without killing child processes or sending `SIGHUP`.
- **Background Drain Loop**: Detached sessions maintain an autonomous background PTY drain thread, processing output and tracking damage while disconnected.
- **Seamless Attachment**: Re-attach any detached session into a new GUI tab instantly (`Cmd+O` or via the session manager) with state, cursor, and scrollback completely intact.

### 🧭 Session Switcher & Quick Palette Modal (`Cmd+O`)
- **Fuzzy Subsequence Matching**: Case-insensitive search across active tabs and detached background sessions with word-boundary bonus scoring.
- **Live Process Telemetry**: Queries resident set size (`RSS MB`) and CPU percentage in real time using macOS `darwin.proc_pidinfo` and Darwin task info APIs.
- **Direct Session Control**:
  - `Enter`: Switch to active tab or re-attach detached session.
  - `Option+Cmd+B` (`⌥⌘B`): Detach selected session.
  - `Cmd+X` / `Ctrl+X`: Terminate selected session and child process tree cleanly.
  - `Escape`: Close switcher.

### 🎨 Direct 32-Bit ARGB TrueColor & Background Color Erase (BCE)
- **Direct 32-Bit ARGB Pipeline**: High-precision 24-bit TrueColor channels with 8-bit alpha stored natively in cell extended attributes (`Cell_Flags.Direct_Color`).
- **Strict BCE Conformance**: Erase sequences (ED `\x1b[J`, EL `\x1b[K`, ECH `\x1b[X`) erase cells to the current active background color, correctly preserving wide glyph boundaries and style flags.

### ⚡ Adaptive 3-Strategy GPU Renderer
Term dynamically selects the optimal Metal rendering pipeline per frame in **$35.9\text{ ns}$**:
1. **Instance Strategy (2 Draws)**: Emits instanced quad vertices; optimal for sparse text, interactive typing, and cursor blinks ($8\times$ faster than compute shaders during scrolling).
2. **Compute Tile Strategy**: Divides the viewport into compute workgroups; optimal for dense, full-screen terminal output ($3\times$ faster on dense text lines).
3. **Fullscreen Strategy (`draw(3, 1)`)**: Single full-screen triangle pass executing a fragment shader over the cell grid texture; triggered on massive frame refreshes ($\ge 25\%$ dirty coverage vs. instance).
- **Metal Triple Buffering**: Employs an in-flight dispatch semaphore with double/triple buffered uniform rings to prevent CPU-GPU pipeline stalls.

### 🔤 Comprehensive Unicode & Multi-Tier Font Fallback
- **Cascading Fallback Chain**: Up to 4 fallback tiers including **Maple Mono NF**, **Symbols Nerd Font Mono**, Arabic presentation forms, and Apple Color Emoji.
- **Extended Grapheme Clusters (EGC)**: Robust handling of combining diacritics, skin-tone modifiers, Zero-Width Joiners (ZWJ), and double-width CJK ideographs.
- **Asynchronous Glyph Rasterizer**: Offloads rasterization misses to a background worker, slashing cold-miss frame drops from $37.16\text{ ms}$ to $0.692\text{ ms}$ ($53.7\times$ speedup).

### 🤖 Standalone Headless MCP Server (`term-mcp`)
A dedicated, headless binary implementing the Model Context Protocol over stdio for autonomous AI coding agents:
- **7 MECE Automation Tools**: `terminal_create_session`, `terminal_close_session`, `terminal_run_command`, `terminal_send_input`, `terminal_send_key`, `terminal_get_screen`, `terminal_resize`.
- **Command Latency**: **$0.27\text{ ms}$** ($p_{50}$) — **$105\times$ faster** than Node.js (`node-pty` at $28.5\text{ ms}$).
- **Physical RSS**: **$1.92\text{ MB}$** — **$44\times$ lower** than Node.js ($84.5\text{ MB}$).
- **Verification**: **100% assertion pass rate** (103/103 assertions across 11 suites).

---

## Technology Stack

| Layer | Technology | Key Components | Purpose in Term |
|---|---|---|---|
| **Core Systems Language** | [Odin](https://odin-lang.org) | Compiler `dev-2026-08+`, custom allocators | Memory safety, deterministic layout, zero runtime overhead |
| **Graphics API** | [Apple Metal](https://developer.apple.com/metal/) | `CAMetalLayer`, Metal Shading Language (MSL) | Native macOS GPU acceleration, compute kernels, triple buffering |
| **Windowing & Events** | [SDL3](https://github.com/libsdl-org/SDL) | `libSDL3.dylib`, Cocoa backend | Low-latency window management, display synchronization, event pump |
| **Typography & Shaping** | FreeType & HarfBuzz | `libfreetype`, `libharfbuzz` | Monospace grid layout, OpenType feature shaping, multi-font fallback |
| **Subprocess & PTY** | POSIX / Darwin | `posix_openpt`, `proc_pidinfo`, `TIOCSWINSZ` | Pseudo-terminal allocation, non-blocking asynchronous I/O, telemetry |
| **Agent Automation** | Model Context Protocol | JSON-RPC 2.0 over stdio | Zero-GUI autonomous terminal execution for AI agents |

---

## Documentation Map

Explore the complete Term documentation suite:

| Document | Description | Target Audience |
|---|---|---|
| **[Getting Started](getting-started.md)** | Prerequisites, building debug/release targets, macOS app bundling, DMG creation, test suites, and troubleshooting. | New users & builders |
| **[User Guide](user-guide.md)** | Daily workflows, keyboard shortcuts, multi-tab lifecycle, session switcher modal, selection models, and search overlay. | End users |
| **[Configuration Guide](configuration.md)** | Declarative Odin AST configuration format, full options reference, color palettes, and custom keybindings. | Power users & customizers |
| **[Architecture Specification](architecture.md)** | Hexagonal core, Ports and Adapters, PTY lifecycle, scalar VT parser, 32-bit ARGB TrueColor, and adaptive Metal renderer. | Systems engineers |
| **[MCP Server Specification](mcp-server.md)** | Detailed JSON-RPC 2.0 stdio protocol, 7 MECE automation tools, agent integration (Claude Desktop, Cursor, Codex), and headless modes. | AI tool builders & integrators |
| **[Benchmark Report](benchmarks.md)** | Empirical microbenchmarks, comparative evaluations (Term vs. Alacritty vs. Ghostty), video telemetry benchmarks, and MCP latency tests. | Performance evaluators |
| **[Developer Guide](developer-guide.md)** | Architectural invariants, test suite workflow, diagnostic probes, profiling with Instruments, and contributing guidelines. | Contributors & developers |

---

## Related Project Documents

- **[Main Project README](../README.md)**: Repository overview, quick-start guide, and badges.
- **[Comprehensive Engineering Report (LAPORAN.md)](../LAPORAN.md)**: 21-phase engineering history, architectural decision records, and empirical measurement logs.
- **[Comparative Benchmark Report (COMPARATIVE_BENCHMARKS.md)](../COMPARATIVE_BENCHMARKS.md)**: Head-to-head empirical metrics measuring throughput, latency, and memory across Term, Alacritty, and Ghostty.
- **[MCP Server Benchmark Report (MCP_BENCHMARKS.md)](../MCP_BENCHMARKS.md)**: Validation of `term-mcp` efficiency and correctness against Node.js and Python backends.
- **[Release Notes (RELEASE_NOTES.md)](../RELEASE_NOTES.md)**: Detailed version changelog and milestone highlights.
- **[Third-Party Software Notices (THIRD_PARTY_NOTICES.md)](../THIRD_PARTY_NOTICES.md)**: Copyright and license details for bundled libraries, fonts, and dependencies.
