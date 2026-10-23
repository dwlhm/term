# Bug & Feature Backlog — Term (src/)

> Dokumen handoff untuk AI agent berikutnya.
> Referensi kebenaran: `legacy/` (implementasi lama yang berfungsi sebagai acuan).
> Target build: `make check` (type-check semua), `make test` (unit + harness + e2e), `make term` (release binary).

Status terakhir diperbarui pada hardening v2.1.1. Dokumen ini **hanya berisi item yang masih terbuka**; item yang sudah selesai dipindahkan ke bagian
"Sudah selesai" supaya tidak dikerjakan ulang.

## Baseline (sudah dikerjakan, jangan diulang)

- Font fallback optical calibration (cap-height + baseline) — `src/app/term/font.odin`
- Emoji warna: atlas RGBA8 + pipeline emoji — `src/app/term/emoji_atlas.odin`, `src/core/render/shaders/emoji.wgsl`
- Grapheme clustering UAX #29 (combining marks, ZWJ emoji, VS16, keycap, RI) — `src/core/terminal/{cell/grapheme.odin, parser/parser.odin, egc/egc.odin}`
- Clipboard copy UTF-8 + resolusi EGC — `src/app/term/clipboard.odin`
- TrueColor 24-bit direct color (`38;2` / `48;2` / bentuk `:`), 256-color, SGR extended styles
- Mouse reporting (1000/1002/1003/1004/1006/1016), mouse cursor sync
- Alt-screen buffer nyata (47/1047/1049) + restore kursor
- DEC Special Graphics (ACS) + SO/SI/SS2/SS3 + `ESC ( A` (UK)
- OSC buffer dinamis (1 MiB) untuk OSC 52/8/133, APC cap + drop-whole + ENOSPC/EINVAL
- Kitty graphics: transport `d`/`f`/`s`/`t`, PNG/JPEG/RGB/RGBA, zlib bounded, animasi, placement,
  guard path (tidak boleh hapus file di luar TMPDIR), budget 128 MiB, validasi GPU
- EGC pool free-list LIFO (slot aktif tidak pernah dipakai dua kali)
- Tab stops (HTS/TBC/CHT/CBT), REP, DECSTR, DECRQM, IND/NEL
- Origin Mode (`DEC 6`), Auto-wrap Mode (`DEC 7`), dan DECRC/DECSC save-restore
- Dynamic OS Font Discovery & Cascade (CoreText on macOS / Fontconfig on Linux) — font fixed-pitch dan daftar cascade resmi OS (Geeza Pro Arab, CJK, Emoji, Symbols) dimuat secara dinamis
- B8 Arabic font fallback & contextual shaping via HarfBuzz (`0x0600..0x06FF` / Presentation Forms)
- B9 Asynchronous glyph rasterization worker thread (mitigates cold-miss frame spikes with zero heap allocations on hot path)
- B10 Programming font ligatures (`!=`, `==`, `->`, `=>`, `===`, `<=`, `>=`) via HarfBuzz & Ligature_Cache
- B7 Sixel graphics protocol (full lifecycle: DCS stream ingestion, DEC 16-color palette + custom RGB & HLS color registers, RLE decompression, 6-pixel vertical bands, CR/LF cursor positioning, bounds guards, and unified GPU texture presentation)
- B13 / B16 Configuration file loader & dynamic reload (`~/.config/term/config.json[5]`, comments, trailing commas, custom font family / path, theme background / foreground / 16-color ANSI palette, window blur / opacity, and dynamic reload via `⇧⌘R`)
- B12 Session persistence & background monitoring lifecycle (OSC 7501 Program Status Protocol, 4-tier telemetry provider, detached session registry, interactive safety dialog with collapsible killed list, and native macOS Menu Bar NSStatusItem)
- Kitty graphics per-screen tagging (`Primary` vs `Alternate`), retensi gambar lintas transisi TUI/less/vim
- Kitty keyboard protocol (flag stack, disambiguated encoding, event types, queries)
- OSC 8 hyperlinks (per-cell ids, underline, `Cmd+Click` with scheme allowlist)
- Text decorations: underline / double underline / strikethrough / conceal / synthetic italic
- In-terminal search `Cmd+F` (grid + scrollback, UTF-8, wraparound, highlight)
- Scrollback scrollbar with proportional thumb, hover and drag
- Chrome text rendering verified on screen (tab titles, command palette)
- Synchronized output `CSI ? 2026` (hold present + safety valve 150 ms)
- Command/aksi UI: zoom font, fullscreen, select-all, close pane, cycle focus
- Resize reflow + scrollback preservation; riwayat alt-screen terpisah

---

## A. Bug fungsional yang masih terbuka

_(Tidak ada bug fungsional terbuka di kategori ini — lihat daftar "sudah selesai" di atas.)_

---

## B. Fitur yang diiklankan README tetapi belum ada

README sudah dikoreksi untuk tidak mengklaim fitur ini. Jangan tambahkan klaim sebelum selesai.

| # | Fitur | Status | Lokasi relevan |
|---|---|---|---|
| B11 | i18n (strings id/en) | belum | legacy: `i18n/*` |
| B15 | Diag/counters/metrics lengkap | sebagian (`--telemetry`, grid dump) | legacy: `diag/*` |

---

## C. Technical debt

1. `app.cursor` (`Cursor_State`) belum disinkronkan penuh dengan `parser.cursor.shape`.
2. Param `is_focused` di `terminal_view_render_pane` tidak dipakai.
3. `make test` selalu rebuild semua harness (lambat); pertimbangkan target incremental.
4. `Kitty_Extension.images` masih array 32 slot; belum ada eviction LRU eksplisit
   (saat ini: slot bebas dulu, lalu slot 0 + delete placement).
5. Terminal menyimpan pointer ke dirinya sendiri (`parser.user_data`), sehingga struct
   `Terminal` **tidak boleh di-copy setelah `terminal_init`**. Saat ini aman karena
   session selalu dialokasikan di heap (`session_create`) — jangan pernah menaruh
   `Terminal` di dalam `[dynamic]` yang bisa realloc.

## Prioritas yang disarankan

1. **B7** (Sixel) — proyek tersendiri; jangan dikerjakan setengah.
2. **B8/B10** (Arabic shaping + ligatures) — butuh pipeline shaping terpisah.
3. **B9** (async rasterization) — perf, gate dengan percentile.
4. **B12** (session persistence) + **B16** (config-file theme/font) — UX harian.
5. **B11/B15** — i18n dan metrik lanjutan.

## Cara verifikasi standar (Definition of Done)

```sh
make check          # type-check semua paket
make test           # unit + harness + e2e
odin test src/core/terminal/tests -define:ODIN_TEST_THREADS=1   # terminal core
make term           # build release
./bin/term --grid-dump /tmp/grid -e '<command>'   # real-run grid snapshot (SIGUSR1)
```

Setiap perbaikan wajib: `make check` bersih + test terkait lolos + tidak ada regresi di `make test`.
