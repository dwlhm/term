# TODO Integrasi Terminal (PTY + Resize + Input + Cursor + app_term)

Sumber: approved integration plan §5 (16 langkah).
Status awal: semua `pending`. Bahasa: Indonesia.
Legenda: `[ ]` pending, `[x]` selesai. Kriteria = syarat lolos.

## Langkah 1 — PTY spawn (fork + exec shell)
- [x] `pty_spawn(argv) @ src/platform/pty/pty.odin` — Scope: plan §5.1, simbol `pty_spawn`.
  Kriteria: `/bin/sh` + `ls` spawn, fd master valid, child pid > 0. Status: done.

## Langkah 2 — PTY drain/read + pump ke parser
- [x] `pty_drain(master, buf) @ src/platform/pty/pty.odin` — Scope: §5.2, `pty_drain`.
  Kriteria: output `ls` terbaca penuh tanpa block, lalu `parse_chunk` mutasi grid. Status: done.

## Langkah 3 — PTY write (stdin child)
- [x] `pty_write(master, data) @ src/platform/pty/pty.odin` — Scope: §5.3, `pty_write`.
  Kriteria: `echo hi` tertulis, child merespons, partial-write di-loop hingga habis. Status: done.

## Langkah 4 — PTY winsize (TIOCSWINSZ)
- [x] `pty_set_winsize(master, rows, cols) @ src/platform/pty/pty.odin` — Scope: §5.4.
  Kriteria: `stty size` di child lapor ukuran baru setelah resize window. Status: done.

## Langkah 5 — PTY exit/wait + close (anti-zombie, anti-fd-leak)
- [x] `pty_wait(pid) + pty_close(master) @ src/platform/pty/pty.odin` — Scope: §5.5.
  Kriteria: child exit terkumpul (no zombie), fd tertutup, double-close aman. Status: done.

## Langkah 6 — terminal_resize (reflow grid, preservasi isi)
- [x] `terminal_resize(t, rows, cols) @ src/terminal/resize.odin` — Scope: §5.6.
  Kriteria: 80x24 -> 100x30 pertahankan baris, kursor di-clamp, damage full. Status: done.

## Langkah 7 — Scrollback push/evict (ring buffer)
- [x] `scrollback_push/evict @ src/terminal/scrollback.odin` — Scope: §5.7.
  Kriteria: overflow 1000 baris evict tertua, push/pop FIFO, mem bounded. Status: done.

## Langkah 8 — input_encode (key/mouse -> bytes VT)
- [x] `input_encode(event) @ src/platform/input/input.odin` — Scope: §5.8.
  Kriteria: Enter=`\r`, Backspace=`\x7f`, Up=`ESC[A`, UTF-8 lolos utuh. Status: done.

## Langkah 9 — Input pump (SDL event -> PTY write + resize)
- [ ] `input_pump(win, master, t) @ src/platform/input/input.odin` — Scope: §5.9.
  Kriteria: ketik muncul di shell, resize window panggil Langkah 4+6. Status: pending.

## Langkah 10 — DECTCEM (cursor show/hide CSI ?25h/l)
- [ ] `dectcem_set(t, visible) @ src/terminal/cursor.odin` + dispatch CSI — Scope: §5.10.
  Kriteria: `ESC[?25l` sembunyikan, `ESC[?25h` tampilkan, state bertahan. Status: pending.

## Langkah 11 — Cursor overlay tick (blink state)
- [ ] `cursor_tick(state, dt) @ src/render/cursor_overlay.odin` — Scope: §5.11.
  Kriteria: 530ms toggle saat visible+focused, steady saat hidden. Status: pending.

## Langkah 12 — Cursor overlay draw (instance/bg pass)
- [ ] `cursor_draw(compiled, cursor) @ src/render/cursor_overlay.odin` — Scope: §5.12.
  Kriteria: cell kursor ter-invert/overlay tanpa merusak glyph, ikut DECTCEM. Status: pending.

## Langkah 13 — renderer_resize_grid (surface + grid + atlas)
- [ ] `renderer_resize_grid(r, t, pw, ph) @ src/render/resize_grid.odin` — Scope: §5.13.
  Kriteria: resize pixel panggil Langkah 6, re-attach surface, frame berikutnya present ok. Status: pending.

## Langkah 14 — app_term loop (poll -> drain -> parse -> compile -> render)
- [ ] `main() @ src/app/main.odin` (app_term) — Scope: §5.14.
  Kriteria: `ls`, `vim`, `htop` jalan interaktif, frame present tiap ada damage. Status: pending.

## Langkah 15 — app_term resize + exit + relaunch
- [ ] `app_on_resize/exit/relaunch @ src/app/main.odin` — Scope: §5.15.
  Kriteria: tutup window exit bersih; child exit tampilkan kode + tombol relaunch. Status: pending.

## Langkah 16 — Verifikasi: pty harness + bench input-to-photon
- [ ] `pty_harness @ src/platform/pty/tests/` + `cmd_pty`, `cmd_input_photon @ src/bench/` — Scope: §5.16.
  Kriteria: harness spawn `printf hello` -> grid berisi `hello`; bench ukur ns input-to-photon. Status: pending.
