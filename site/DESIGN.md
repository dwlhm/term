# Term Landing Page — Design Spec

Design contract for `site/`. Follow it for every change.

Local preview: `python3 -m http.server -d site 8000` → http://localhost:8000 (the game uses ES modules, so `file://` will not work).

## 1. Hard rules

1. `styles/tokens.css` is the single source of truth for visual values; `styles/base.css` holds shared components.
2. Plain HTML + CSS + vanilla JS. No frameworks, no CDNs, no build step, no external fonts/images, no tracking.
3. Colors, spacing, radii, fonts, durations: use ONLY the CSS custom properties in `styles/tokens.css`. No raw hex/px colors in section CSS (layout px for widths/borders is fine).
4. Copy: English. Every factual claim must come from `../README.md`. Do NOT invent numbers, benchmarks, testimonials, download counts, or features. NO benchmark numbers anywhere on the page.
5. Each section is one top-level element (`<header>`, `<section>`, or `<footer>`) in `index.html`, styled by its own `styles/<name>.css`.
6. Prefix every class with its section prefix (`hero-`, `feat-`, `game-`, `start-`, `foot-`) to avoid collisions. No element/global selectors except inside the section root (e.g. `.feat-root h3`).
7. Accessibility: semantic headings (only the hero has `<h1>`; sections use `<h2>`), visible `:focus-visible` using `--focus-ring`, alt text, contrast ≥ 4.5:1 for body text, every animation disabled or reduced under `@media (prefers-reduced-motion: reduce)`.
8. Responsive: must work from 360px to 1440px wide with zero horizontal scroll. Mobile-first CSS; breakpoints at `48rem` and `64rem` only.
9. Comments only where logic is non-obvious. No dead code, no TODOs.

## 2. Visual direction

Calm, precise, technical. Think "engineering notebook", not "neon hacker".
- Dark by default (slate canvas, cream text); light theme via `prefers-color-scheme: light` is handled by tokens — you get it for free if you only use tokens.
- One accent (amber, `--accent`) used sparingly: primary CTA, active states, the game's dirty cells. Never for large surfaces.
- Grid motif: the logo is a 3×3 grid. Use thin `--line` borders and cell-like cards; it echoes terminal cells.
- Type: headings in `--font-sans` (tight, `--weight-strong`), anything code/terminal-ish in `--font-mono`.
- Radii: cards `--radius-2`, buttons `--radius-1`, pills `--radius-pill` — subject to the concentric rule in 2.1.
- Depth: `--surface-1/2` steps + `--line` borders, plus `box-shadow: var(--elev-1)` on cards and `var(--elev-2)` on hero objects (mock terminal, game board). The tokens already resolve to an inset edge highlight in dark mode and a dual-layer key+ambient shadow in light mode — never write your own shadows.

## 2.1 Polish rules (better-ui)

1. **Concentric radii.** A child that sits in a parent's corner with gap `g` (padding or inset) uses `calc(<parent radius> - <g> - var(--border-w))`, never the same radius as the parent. If that would be < 2px, raise the parent radius instead. When `g ≥ 24px` (`--space-5`) the corners are decoupled and token radii are fine. Full-bleed children (title bars, canvases) clip via `overflow: hidden` on the parent.
2. **Hit targets ≥ `--hit-min` (44px).** Interactive elements whose visual box is smaller carry the shared `.hit-area` class (already in `index.html`); never pad the visual box just to grow the target.
3. **Press feedback.** `button` and `.pressable` scale to `--press-scale` on `:active` (shared in `base.css`). If your section sets its own `transition`, include `transform var(--dur-press) var(--ease)` in the list or the press animation is lost.
4. **Exit faster than entrance.** Appearing: `--dur-fast`; disappearing: `--dur-exit`.
5. **Affordance honesty.** Only interactive things look interactive: non-interactive labels/badges get no border and no hover state.
6. **Reduced motion.** Every transition/animation you add is disabled under `prefers-reduced-motion: reduce`.

## 2.2 Shared components (base.css — use, never restyle)

Every `<section>` except the hero uses this exact head markup and the shared classes (no per-section title/eyebrow/lede/padding styles):

```html
<section id="…" class="section xxx-root" aria-labelledby="xxx-title">
  <div class="container">
    <header class="section-head">
      <p class="eyebrow">Label</p>
      <h2 id="xxx-title" class="section-title">Title</h2>
      <p class="section-lede">One or two sentences.</p>
    </header>
    …section content…
  </div>
</section>
```

`.container` provides max width + gutter; `.section` provides vertical rhythm and the top divider. Eyebrows: Features → "Features", game → "Play", get started → "Install".

## 3. Page structure (order in index.html)

| # | Anchor | Element | Content |
|---|---|---|---|
| 1 | `#hero` | `<header>` | Static (non-sticky) nav (logo + "Term", links: Features, Play, Get started, GitHub) + hero |
| 2 | `#features` | `<section>` | Feature grid + PTY→pixels pipeline diagram |
| 3 | `#play` | `<section>` | "Dirty Cells" game |
| 4 | `#get-started` | `<section>` | Getting started |
| 5 | — | `<footer>` | License, links |

Section anchors used by nav: `#features`, `#play`, `#get-started`. Each section root carries that id.

## 4. Section briefs

### 4.1 Hero
- Nav: `assets/logo.svg` (24px) + wordmark "Term"; links right; collapses to a simple wrapped row on mobile (no JS hamburger).
- H1: "A terminal that only draws what changed." Sub: one sentence from README overview (GPU-accelerated, Odin, Native Apple Metal, macOS & Linux).
- CTAs: primary "Download" → `https://github.com/dwlhm/term/releases`; secondary "Play Dirty Cells" → `#play`.
- Visual: a CSS-only mock terminal window (title bar with 3 dots, mono text) showing a short shell session, e.g. `make term`, `./bin/term`. A caret blinks (disabled under reduced motion). No images of real apps.
- Badge row (pills, mono, small): "Odin", "Metal / wgpu", "macOS · Linux", "MIT".

### 4.2 Features
- H2 "Built from first principles". 6 cards in a grid (1 col → 2 col @48rem → 3 col @64rem). Each: small mono label, title, 1–2 sentence body. Source topics from README "Key Highlights" and "Core Invariants":
  1. Zero steady-state allocations
  2. Adaptive GPU rendering (instance / compute tile / fullscreen strategies — no numbers)
  3. Only changed cells are uploaded (damage tracking)
  4. Modern protocols (Kitty graphics & keyboard, Sixel, OSC 8, synchronized output)
  5. Unicode & typography (grapheme clusters, ligatures, font fallback, Arabic shaping)
  6. Native feel (tabs, splits, search, session persistence, JSON5 config)
- Pipeline diagram below cards: horizontal flow on ≥64rem, vertical on mobile: `PTY bytes → Input ring → VT state machine → Ring grid → Render compiler → GPU strategy → Pixels`. Pure HTML/CSS (ordered list styled as steps with connector lines). No SVG libraries.

### 4.3 Dirty Cells game — see section 5.

### 4.4 Getting started
- H2 "Get started". Two columns (stack on mobile): "Install" (macOS: download `Term.dmg` from Releases; Linux: tarball + `sudo ./install.sh`) and "Build from source" (`brew install sdl3 freetype harfbuzz`, then `make term`, then `./bin/term`). Code blocks in `<pre><code>` using mono tokens. Each code block has a "Copy" button (uses `navigator.clipboard.writeText`, shows "Copied" for 1.5s, fails silently to showing "Copy failed"). Script file: `scripts/start.js`.

### 4.5 Footer
- Logo + "Term — MIT License", links: GitHub, Releases, License (`https://github.com/dwlhm/term/blob/main/LICENSE`). Small, `--text-2`.

## 5. Dirty Cells — game spec

Concept: a terminal grid where cells turn "dirty" (show a character, highlighted in `--accent`). The player types that character to "render" (clean) the cell before its deadline. Teaches Term's core idea: only changed cells get redrawn.

### 5.1 Layout
- `<section id="play" class="game-root">`: H2 "Dirty Cells", one-line explainer, HUD row (Score, Streak, Level, Best — mono), the board, a primary button "Play" / "Play again", and a `<p class="game-help">` with controls.
- Board: `<canvas>` sized to its container width, aspect ≈ 32 cols × 12 rows of cells. Use `devicePixelRatio` for crisp text. Re-measure on `ResizeObserver` (keep game state; just redraw).
- Under 48rem: 16 cols × 10 rows.

### 5.2 Rules
- Character set: `a-z0-9` plus `; : / - _ { } [ ]`.
- Spawning: every tick, spawn `k` dirty cells at random empty positions; each has a deadline (ms).
- Typing a key cleans the OLDEST dirty cell showing that character (+10 × level, streak +1). Key matching no dirty cell: streak resets, brief board shake (no shake under reduced motion).
- A cell whose deadline passes becomes a "dropped frame": lose 1 of 3 lives (show lives as 3 small squares in HUD).
- Levels (every 15 cleans): `sparse` (k=1, deadline 3000ms) → `dense` (k=2, 2400ms) → `fullscreen` (k=3, 1800ms) → then deadline −150ms per level, floor 900ms. Show level name in HUD.
- 0 lives → game over: overlay text "Frame dropped. Score N", button becomes "Play again". Best score saved.

### 5.3 State machine (must be explicit in code)
`idle → playing → paused → playing → over → idle(playing on restart)`.
- `idle`: board shows a static demo grid; nothing animates; no listeners for game keys.
- `playing`: single `requestAnimationFrame` loop; time based on `performance.now()` deltas (never frame counts).
- `paused`: entered automatically when the tab is hidden (`visibilitychange`) or the board scrolls out of view (`IntersectionObserver`, threshold 0.25) or `Esc`. Deadlines must NOT expire while paused (shift them by paused duration). Show "Paused — press Space or tap to resume".
- `over`: loop stopped, no rAF scheduled.
- Rapid double-click on Play must not start two loops. Resize during play must not reset state.
- Idle = zero work: no rAF/timers running in `idle`, `paused`, `over`.

### 5.4 Input
- Keyboard: `keydown` on `document` only while `playing`, ignore when modifier keys (meta/ctrl/alt) are held, `preventDefault` only for keys the game consumes (Space, game chars) so page shortcuts keep working.
- Touch/mouse: tapping a dirty cell cleans it (same scoring). Map pointer coords → cell using the canvas bounding rect and current cols/rows.
- The canvas has `role="img"` + `aria-label` updated with score; a visually-hidden `aria-live="polite"` region announces level ups and game over only (not every keystroke).

### 5.5 Persistence
- Best score in `localStorage` key `term.dirtycells.best`. Wrap every read/write in `try/catch`; game works if storage throws.

### 5.6 Drawing
- Background `--surface-1`, grid lines `--line`, clean cells faint `--text-3` dots, dirty cells: `--accent` fill at low alpha + character in `--accent` mono bold; cells near deadline (<30% left) pulse brightness (static under reduced motion). Read token values once via `getComputedStyle(document.documentElement)` and again on `prefers-color-scheme` change.
- Cleaning a cell: 150ms fade (instant under reduced motion).

## 6. File map

| Section | Files |
|---|---|
| Hero, Get started, Footer | `styles/hero.css`, `styles/start.css`, `styles/footer.css`, `scripts/start.js` |
| Features | `styles/features.css` |
| Dirty Cells | `styles/game.css`, `scripts/game/{config,model,render,main}.js` (ES modules, entry `main.js`, each ≤250 lines) |

## 7. Done criteria
- `python3 site/tests/check.py` exits 0 (lint + layout + game).
- Page renders with no console errors.
- No raw colors; only tokens. Every class carries its section prefix.
- 360px wide: no horizontal scroll. Reduced motion: no animation.
