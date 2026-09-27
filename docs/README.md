# Term Documentation Index

This directory and root documentation provide comprehensive architectural specifications, empirical benchmarks, and historical records for the **Term** terminal emulator project.

---

## Core Project Docs

Essential high-level architectural overviews, engineering reports, release notes, and comparative benchmark suites:

- **[README.md](../README.md)**: Main project overview, architecture philosophy, core invariants, getting started guide, build instructions, and repository structure.
- **[LAPORAN.md](../LAPORAN.md)**: Comprehensive 21-phase engineering report containing architectural decision logs, empirical latency/throughput measurements, and GPU pipeline rationale.
- **[RELEASE_NOTES.md](../RELEASE_NOTES.md)**: Detailed version history and highlights for releases (including v0.3.0 unified hexagonal core, headless MCP server, Metal integration, and DMG packaging).
- **[COMPARATIVE_BENCHMARKS.md](../COMPARATIVE_BENCHMARKS.md)**: Empirical comparative evaluation measuring throughput, latency, memory usage, and GPU metrics across Term, Alacritty, and Ghostty.
- **[MCP_BENCHMARKS.md](../MCP_BENCHMARKS.md)**: Performance benchmark report validating `term-mcp` against Node.js and Python agent terminal backends across 11 verification suites.

---

## Architecture: Hexagonal Core (`src/session_core`)

Term decouples terminal lifecycle logic and state handling into a shared hexagonal core package ([`src/session_core`](file:///Users/dwlhm/project/term/src/session_core/)) using Ports and Adapters architecture:

- **Ports (`ports.odin`)**:
  - **`Terminal_Control_Port`**: High-level interface for creating sessions, dispatching input, executing commands, resizing grids, and terminating subprocesses cleanly.
  - **`Terminal_Observer_Port`**: Callback contract dispatching state mutations (`on_damage`, `on_title_change`, `on_bell`, `on_exit`) from the background drain thread to frontends.
- **Execution Profiles (`Session_Mode`)**:
  - **`Fast_Headless`**: Optimized for automated agent interaction via MCP. Strips interactive prompt decoration, unsets ZLE/precmd latency, preserves user `$PATH`, and achieves 0.27 ms execution latency and >80 MB/s stream throughput.
  - **`Interactive_GUI`**: Configured for the native desktop Metal frontend (`src/app/`), supporting full dotfiles (`.zshrc`), interactive line-editing, and continuous visual presentation.
- **Adapters**:
  - **Headless MCP Adapter (`src/cmd/term_mcp/`)**: Exposes JSON-RPC 2.0 tools over stdio for AI agent workflows.
  - **Native Metal GUI Adapter (`src/app/`)**: Handles window events, keyboard/mouse input, and `CAMetalLayer` rendering.

---

## Research Records

Deep-dive technical investigation notes and exploratory research artifacts:

- **[phase20_analytic_glyph_note.md](phase20_analytic_glyph_note.md)**: Research notes and analysis on glyph rasterization, font atlas management, and text rendering techniques.

---

## Historical Archives

Early phase planning, task breakdowns, implementation summaries, and completion reports preserved for project provenance:

- **[docs/archive/](archive/)**: Archive directory containing historical Phase 0–2 records:
  - **[phase0_implementation_summary.md](archive/phase0_implementation_summary.md)**: Phase 0 initial foundation summary.
  - **[phase1_implementation_plan.md](archive/phase1_implementation_plan.md)**: Phase 1 core terminal engine & rendering plan.
  - **[phase1_completion_report.md](archive/phase1_completion_report.md)**: Phase 1 verification and milestone completion report.
  - **[phase2_implementation_plan.md](archive/phase2_implementation_plan.md)**: Phase 2 multi-tab, selection, and UI chrome plan.
  - **[phase2_completion_report.md](archive/phase2_completion_report.md)**: Phase 2 milestone completion report.
  - **[phase1_2_integration_todo.md](archive/phase1_2_integration_todo.md)**: Integration checklist and backlog tracking.
  - **[app_phase0_harness_main.odin](archive/app_phase0_harness_main.odin)**: Early standalone harness entry point.
