# Phase 20 — Analytic Glyph Candidates: Rejection Note

Docs-only record. No `.odin` file was added, modified, or deleted to produce
this note. No GPU, shader, atlas, fallback, or async code was touched.

## 1. Verdict

All three analytic-glyph candidates evaluated for Phase 20 are **rejected**.
The current bitmap atlas path stands unchanged. Phase 19's DISCARD verdict
stands (see §7). Re-evaluation happens only through the mechanical reopen
triggers in §6 — no trigger currently fires (see §8, non-fire clause).

## 2. Candidate (a) — GPU curve fill: REJECTED

Rejected on atlas arithmetic and outline-model mismatch.

Atlas constants (`src/render/atlas.odin`):

| Symbol | Value | Line |
|---|---|---|
| `ATLAS_SLOT_COUNT` | 512 | atlas.odin:18 |
| `ATLAS_GLYPH_SIZE` | 16 | atlas.odin:21 |
| `ATLAS_COLS` | 16 | atlas.odin:24 |
| `ATLAS_ROWS` | 32 | atlas.odin:27 |
| `atlas_init` | proc | atlas.odin:75 |
| pixel buffer alloc (`make([]u8, pixel_count)`) | R8, single channel | atlas.odin:88-89 |

Derived arithmetic (from the constants above):

- Texture width = `ATLAS_COLS * ATLAS_GLYPH_SIZE` = 16 * 16 = **256 px**
  (atlas.odin:80).
- Texture height = `ATLAS_ROWS * ATLAS_GLYPH_SIZE` = 32 * 16 = **512 px**
  (atlas.odin:81).
- Pixel buffer = 256 * 512 = **131,072 bytes = 128 KiB**, R8
  (`pixel_count := tex_width * tex_height`, atlas.odin:88).

A GPU curve-fill path would have to rasterize analytic outlines into this
fixed 128 KiB budget while also closing the cubic gap (§5). Neither
requirement is satisfiable without changing the atlas geometry or adding a
cubic-capable fill stage — both out of scope. Rejected with numbers
recorded above.

## 3. Candidate (b) — Zoom: REJECTED

Rejected: there is **no zoom feature** in the codebase and **no acceptance
criterion** (no target scale, no error metric, no threshold) against which a
zoom-dependent glyph path could be evaluated. No citation exists because
there is nothing to cite — the absence is the finding. Re-evaluation is
owned by reopen trigger **T1** (§6).

## 4. Candidate (c) — Outline effects: REJECTED

Rejected: there is **no outline-effects requirement** (no stroke, glow, or
variable-weight rendering path) in the codebase. No citation exists because
there is nothing to cite — the absence is the finding. Re-evaluation is
owned by reopen trigger **T3** (§6).

## 5. Cubic gap (known spike risk, recorded — not solved)

The stb_truetype outline model exposes cubic segments, but the GPU fill
path under consideration is quadratic-only:

- `vmove` enum with `vcubic` member — vendor stb_truetype.odin:356-362
  (`vcubic` at :361).
- `vertex` struct carrying both quadratic (`cx, cy`) and cubic
  (`cx1, cy1`) control points — vendor stb_truetype.odin:365-368.

Any future analytic-fill spike must account for `vcubic` contours
(subdivision, approximation, or native cubic fill). This gap is recorded
here as a known risk; this note does not close it.

## 6. API grounding (verified at write time)

Vendor file: `<odin-libexec>/vendor/stb/truetype/stb_truetype.odin`
(resolved via `odin root` → `/opt/homebrew/Cellar/odin/2026-08/libexec/`).
All names and lines below were re-verified while writing this note; the two
line-range corrections versus the draft plan are noted inline.

| Symbol | Line (verified) |
|---|---|
| `vmove` enum (`none, vmove=1, vline, vcurve, vcubic`) | :356-362 (draft said :358-364 — corrected) |
| `vertex` struct (`x, y, cx, cy, cx1, cy1, type, padding`) | :365-368 (draft said :365-369 — corrected) |
| `GetCodepointShape` | :384 |
| `GetGlyphShape` | :385 |
| `FreeShape` | :388 |
| `GetGlyphSDF` | :532 |
| `GetCodepointSDF` | :533 |

## 7. Reopen triggers T1–T4 (mechanical re-evaluation)

Each trigger names a metric, a method, and a firing condition. Evaluation is
mechanical: if the condition holds, re-run the stated method; otherwise the
rejection stands. No judgment calls.

- **T1 — Zoom requirement lands.**
  Metric: presence of a zoom feature plus a numeric quality criterion
  (target scale + error metric + threshold).
  Method: re-open candidate (b) against the stated criterion.
  Fires when: a zoom scale requirement with an acceptance threshold is
  specified. Currently absent → does not fire.

- **T2 — Atlas geometry or fill-path capability changes.**
  Metric: `ATLAS_*` constants (§2) and the quadratic-only fill assumption.
  Method: redo the §2 byte arithmetic and the §5 cubic-gap accounting
  against the new constants/path.
  Fires when: any `ATLAS_SLOT_COUNT / ATLAS_GLYPH_SIZE / ATLAS_COLS /
  ATLAS_ROWS` value changes, or a cubic-capable fill stage is introduced.
  Currently unchanged → does not fire.

- **T3 — Outline-effects requirement lands.**
  Metric: presence of an outline-effects requirement (stroke, glow,
  variable weight, or equivalent) with an acceptance criterion.
  Method: re-open candidate (c) against the stated requirement.
  Fires when: such a requirement with a criterion is specified.
  Currently absent → does not fire.

- **T4 — SDF cost/quality gates change.**
  Metric: the `sdf_decide` pre-registered gates
  (`src/render/experiments/sdf_experiment.odin:657`) and the harness
  `sdf_experiment_run` (`sdf_experiment.odin:715`).
  Method: re-run the Phase 19 harness; RETAIN requires every gate to hold
  simultaneously.
  Fires when: any `sdf_decide` threshold changes, or a harness run returns
  a non-DISCARD verdict. Currently DISCARD holds → does not fire.

## 8. Non-fire clause

As of this note: T1 (no zoom feature/criterion), T2 (atlas constants and
fill path unchanged), T3 (no outline-effects requirement), and T4 (Phase 19
DISCARD stands) — **none fire**. All Phase 20 analytic-glyph rejections
therefore stand, and no implementation work is authorized beyond this note.

## 9. Phase 19 verdict reference (stands)

- `sdf_decide` — gate proc,
  `src/render/experiments/sdf_experiment.odin:657`.
- `sdf_experiment_run` — full harness,
  `src/render/experiments/sdf_experiment.odin:715`.
- Verdict: **DISCARD** (close, keep bitmaps; RETAIN requires every
  pre-registered `sdf_decide` threshold to hold simultaneously —
  `sdf_experiment.odin:5-6`).
