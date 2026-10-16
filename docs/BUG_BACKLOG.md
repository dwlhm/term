# Bug & Feature Backlog — Term (src/)

> Dokumen handoff untuk AI agent berikutnya.
> Referensi kebenaran: `legacy/` (implementasi lama yang berfungsi sebagai acuan).
> Target build: `make check` (type-check semua), `make test` (unit + harness + e2e), `make term` (release binary).

## Baseline (sudah dikerjakan, jangan diulang)

- Font fallback optical calibration (cap-height + baseline) — `src/app/term/font.odin`
- Emoji warna: atlas RGBA8 + pipeline emoji — `src/app/term/emoji_atlas.odin`, `src/core/render/shaders/emoji.wgsl`
- Grapheme clustering UAX #29 (combining marks, ZWJ emoji, VS16, keycap, RI) — `src/core/terminal/{cell/grapheme.odin, parser/parser.odin, egc/egc.odin}`
- Clipboard copy UTF-8 + resolusi EGC — `src/app/term/clipboard.odin`

---

## A. Bug fungsional (benar-benar salah / tidak tampil)

### A1. Teks UI (chrome) tidak pernah dirender — KRITIS
- File: `src/core/render/chrome/chrome_renderer.odin`
- Kasus `case .Text_Run, .Icon:` di `chrome_renderer_render` hanya komentar no-op.
- Tidak ada atlas glyph / SDF text / font di chrome renderer (hanya `sdf` untuk bentuk geometri).
- Akibat: judul tab, isi command center, dan teks tombol TIDAK tampil.
- Perbaikan arah: tambah atlas glyph + pipeline teks ke `Chrome_Renderer`, atau render teks via atlas yang sudah ada (`src/core/render/atlas`) + `Glyph_Atlas_Manager`.
- Verifikasi: jalankan `make term`, buka app, pastikan judul tab & command center (Cmd+K) menampilkan teks.

### A2. TrueColor 24-bit (SGR `38;2` / `48;2`) tidak dirender
- File: `src/core/terminal/parser/parser.odin` (case `'m'`, sekitar baris 430–460).
- Parser set `.Has_Direct_Color` tapi membuang nilai r,g,b (tidak menyimpannya).
- `grid.colors_pool` / `Row.direct_colors` tidak pernah diisi oleh siapapun.
- Renderer `src/app/term/terminal_view.odin` hanya pakai `color_from_palette_256(cell_val.fg)`.
- Perbaikan: simpan RGB ke `direct_colors` (perlu API di grid), dan baca di terminal_view saat `.Has_Direct_Color`.
- Verifikasi: `printf '\e[38;2;255;0;0mTEST\e[0m'` harus merah murni.

### A3. Resize kehilangan scrollback & tidak reflow wide char
- File: `src/core/terminal/grid/grid.odin` (`grid_resize`).
- `grid_resize` membuat grid baru (`history_count=0`), hanya copy sel visible, tidak reflow karakter lebar.
- Referensi: `legacy/src/terminal/resize.odin` (reflow + preserve history).
- Verifikasi: buka app, scroll ke atas (history), resize window → history harus tetap ada.

### A4. OSC 52 (set clipboard remote) tidak terpasang di session
- File: `src/features/session/session.odin` (`session_create`) — hanya register OSC 0/2/7/133.
- Handler 52 hanya ada di `src/cmd/bench_session/main.odin` dan test mock.
- Perbaikan: tambah handler OSC 52 di session yang menulis ke clipboard (pakai `vendor:sdl3` SetClipboardText atau bridge).
- Verifikasi: `printf '\e]52;c;dGVzdA==\a'` → clipboard berisi "test".

### A5. Mouse reporting tidak ada
- File: `src/core/terminal/parser/parser.odin` (`case 'h'`/`'l'`).
- Tidak ada mode 1000/1002/1003/1004/1006/1015. TUI mouse-driven (vim/htop/tmux) tidak menerima event mouse.
- Perbaikan: implement DECSET/DECRST mouse mode + encode SGR mouse event di `src/app/term/mouse.odin` + kirim ke PTY.
- Verifikasi: jalankan `vim`, coba klik/drag — harus menghasilkan event mouse.

### A6. Alt-screen (47/1047/1049) hanya flag, bukan buffer nyata
- File: `src/core/terminal/parser/parser.odin` (`in_alt_screen: bool` di `Parser`).
- Tidak ada buffer alt-screen untuk save/restore layar utama.
- Akibat: vim/less/mc fullscreen tidak berfungsi benar.
- Perbaikan: tambah buffer alt-screen di `Terminal` + save/restore pada `1049`.
- Verifikasi: `vim` lalu keluar → layar shell harus kembali seperti semula.

### A7. EGC pool append-only, tidak pernah di-release/reset
- File: `src/core/terminal/egc/egc.odin`, `src/core/terminal/terminal.odin`.
- Setelah 256 cluster unik, `egc_pool_alloc` gagal → combining mark di-drop. Tidak di-reset saat resize/clear.
- Catatan: ini trade-off kesengajaan (aman, tanpa dangling). Perbaikan opsional: release saat cell overwrite + reset saat resize/clear.

---

## B. Fitur diiklankan README tetapi belum diimplementasikan

| # | Fitur (klaim README) | Status | Lokasi relevan |
|---|---|---|---|
| B1 | Kitty Keyboard Protocol | belum | `src/app/term/input.odin`, `src/app/term/keymap.odin` |
| B2 | Synchronized Output `CSI ? 2026` | belum | `src/core/terminal/parser/parser.odin` |
| B3 | Bracketed Paste `CSI ? 2004` | belum | parser + `src/app/term/clipboard.odin` |
| B4 | OSC 8 hyperlink + Cmd+Click buka URL | belum | flag `Has_Hyperlink` ada di `cell.odin` tapi tak terpakai |
| B5 | Pencarian in-terminal (Cmd+F) | belum | legacy: `terminal/search.odin`, `platform/chrome/search_bar.odin` |
| B6 | Seleksi word/line/rectangular + double-click word | hanya linear drag | `src/app/term/mouse.odin` |
| B7 | Font zoom `⌘+ / ⌘- / ⌘0` | no-op | katalog/keymap ada, `app_execute_action` tak handle |
| B8 | Toggle fullscreen `^⌘F` | no-op | `src/cmd/harness_helper/window.odin` tak punya set_fullscreen |
| B9 | Reload config `⇧⌘R` + loading config file | belum | `src/app/term/config.odin` hanya konstanta |
| B10 | Select All `⌘A` | no-op | `app_execute_action` |
| B11 | Close pane `⇧⌘W` | no-op | `multiplexer_close_pane` ada, tak dipanggil |
| B12 | Focus pane sebelumnya `⌘[` | no-op | `multiplexer_cycle_focus(forward=false)` ada, tak di-wire |
| B13 | Arabic fallback + shaping/joining | belum | `src/app/term/font.odin`; legacy: `render/arabic_join.odin` |
| B14 | Async glyph rasterization | sinkron | legacy: `render/raster_async.odin` |
| B15 | Ligature cache/shaping | belum | legacy: `render/ligature_cache.odin` |
| B16 | Kitty graphics protocol | belum | legacy: `graphics/*` |
| B17 | i18n (strings id/en) | belum | legacy: `i18n/*` |
| B18 | Session persistence/restore | belum | legacy: `app/persistence.odin` |
| B19 | Diag/counters/metrics | belum | legacy: `diag/*` |
| B20 | Konfigurasi tema/font dari file | belum | legacy: `config/*` |
| B21 | Scrollbar overlay penuh + pencarian scrollback | thumb dasar saja | `src/app/term/chrome_view.odin`; legacy: `render/scrollbar_overlay.odin` |

---

## C. Bug kecil / technical debt

1. Command center menampilkan aksi no-op (B7–B12) — UX menyesatkan. `src/app/term/command_center.odin` + `keymap.odin`.
2. `app.cursor` (`Cursor_State`) state mati — tidak disinkronkan dengan `parser.cursor.shape`. `src/app/term/cursor.odin` + `main.odin`.
3. Param `is_focused` di `terminal_view_render_pane` tidak dipakai. `src/app/term/terminal_view.odin`.
4. DECSET/DECRST tidak lengkap: BCE (45), origin mode, autowrap toggle. `parser.odin`.
5. `make test` rebuild semua harness tiap run (lambat) — bisa di-split menjadi target incremental.

---

## Prioritas yang disarankan

1. **A1** (teks UI) — seluruh chrome/command center buta teks.
2. **A2** (TrueColor) — banyak prompt/theme modern pakai 24-bit.
3. **A3** (resize/history) — UX dasar terminal.
4. **A5 + A6** (mouse reporting + alt-screen) — agar vim/htop/less berfungsi.
5. **B1–B3** (protokol modern: kitty, 2026, 2004).

## Cara verifikasi standar (Definition of Done)

```sh
make check          # type-check semua paket
make test           # unit + harness + e2e (lama; bisa per-target)
odin test src/core/terminal/tests -define:ODIN_TEST_THREADS=1   # terminal core
make term           # build release
```

Setiap perbaikan wajib: `make check` bersih + test terkait lolos + tidak ada regresi di `make test` (atau subset yang relevan).
