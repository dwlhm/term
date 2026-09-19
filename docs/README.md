# Term Documentation Index

This directory and root documentation provide comprehensive architectural specifications, empirical benchmarks, and historical records for the **Term** terminal emulator project.

---

## Core Project Docs

Essential high-level architectural overviews, engineering reports, release notes, and comparative benchmark suites:

- **[README.md](../README.md)**: Main project overview, architecture philosophy, core invariants, getting started guide, build instructions, and repository structure.
- **[LAPORAN.md](../LAPORAN.md)**: Comprehensive 21-phase engineering report containing architectural decision logs, empirical latency/throughput measurements, and GPU pipeline rationale.
- **[RELEASE_NOTES.md](../RELEASE_NOTES.md)**: Detailed version history and highlights for releases (including v0.2.0 multi-tab sessions, UI chrome, selection, CoreText FFI, and DMG packaging).
- **[COMPARATIVE_BENCHMARKS.md](../COMPARATIVE_BENCHMARKS.md)**: Empirical comparative evaluation measuring throughput, latency, memory usage, and GPU metrics across Term, Alacritty, and Ghostty.

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
