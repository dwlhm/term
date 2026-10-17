# Refinement Arsitektur Render — Desain & Migration Plan

Status: **RANCANGAN (belum ada kode diubah).**
Keputusan yang sudah dikunci:

1. **Model komposisi tetap 2-layer compositor** (Terminal + Chrome offscreen, composite via blit). Tambah layer lain hanya bila perlu (Three_D/Modal sudah tersedia di model).
2. **Wire, jangan hapus.** Pilar yang sudah ada (`terminal/tile`, `terminal/fullscreen`, `terminal/selector`, `composer/{scheduler,transition,frame}`, `chrome/surface`, `three_d`) harus diintegrasikan ke jalur produksi, bukan dibuang.
3. Desain dulu; implementasi setelah review.

---

## 1. Ruang lingkup & non-goals

**Tujuan:** menyatukan render app ke satu siklus frame `composer/frame` yang sudah ada, sehingga (a) submit per frame minimal, (b) idle zero-work, (c) damage-driven, (d) resize/live-resize present benar, dan (e) semua pilar yang ada benar-benar berfungsi.

**Non-goals (sesi ini):** menulis kode, mengubah shader, mengubah kontrak backend kecuali yang terbukti perlu.

---

## 2. Kondisi saat ini

### 2.1 Peta kepemilikan

| Lapisan | Lokasi | Peran |
|---|---|---|
| App shell | `src/app/term/` | loop, event, layout, view terminal/chrome, composer view |
| Composer | `src/core/composer/` | pipeline, blit, layer_pool, frame, scheduler, transition |
| Render pillars | `src/core/render/` | contract, terminal/{instance,tile,fullscreen,selector}, chrome/{chrome_renderer,batch,surface,sdf}, atlas, three_d |
| Backend | `src/core/platform/gpu/wgpu/` | vtable GPU (Metal via wgpu) + surface SDL3 |
| Window | `src/cmd/harness_helper/window*.odin` | SDL3 window + tweak CAMetalLayer |

### 2.2 Alur frame produksi saat ini (`app_render_frame`, `src/app/term/render.odin:47`)

```
app_run (main.odin:151, dirty-gated)
 └─ app_render_frame
     ├─ contract.get_surface_texture
     ├─ composer_view_acquire_layers            (composer_view.odin:56)
     │    ├─ _clear_texture_view(term layer)    → encoder+submit TERSENDIRI (composer_view.odin:43)
     │    └─ _clear_texture_view(chrome layer)  → encoder+submit TERSENDIRI
     ├─ terminal_view_render_pane × N pane      (terminal_view.odin:146)
     │    └─ per pane: encoder+pass+submit TERSENDIRI (terminal_view.odin:342-366)
     ├─ chrome_view_build_and_render            (chrome_view.odin:50)
     │    └─ chrome_renderer_render: encoder+pass+submit TERSENDIRI (chrome_renderer.odin:128-201)
     └─ composer_view_composite_and_present     (composer_view.odin:86)
          └─ encoder+pass+submit TERSENDIRI, lalu present
```

Per frame ≈ `2 + N_pane + 1 + 1` command buffer. Untuk 4 pane = 8 submit. Tidak ada satu encoder pun.

### 2.3 Siklus frame yang SEHARUSNYA dipakai

`src/core/composer/frame/frame.odin` mendokumentasikan dirinya sebagai *"single frame loop reused by the app and harnesses"*, tetapi **app tidak memakainya**. `frame_tick` sudah menyediakan:

- `transition_update` → gerakkan `dest_rect`/`opacity` & mark damage (tanpa men-dirty-kan layer) (`frame.odin:70`).
- `scheduler_needs_frame` gate → idle zero-work (`frame.odin:75`, `scheduler.odin:36`).
- **satu** `create_command_encoder` untuk seluruh frame (`frame.odin:84`).
- raster **hanya layer dirty**, back-to-front (`frame.odin:91-99`).
- composite semua layer in-use → target (`frame.odin:112`).
- **satu** submit (`frame.odin:119`).
- present lewat driver (`frame.odin:125`).

Driver yang di-inject:

```odin
Frame_Acquire_Proc :: proc(user: rawptr) -> (tex: contract.Gpu_Texture, view: contract.Gpu_TextureView, ok: bool)
Frame_Raster_Proc  :: proc(user: rawptr, enc: contract.Gpu_CommandEncoder, l: ^composer.Composer_Layer) -> bool
Frame_Present_Proc :: proc(user: rawptr, tex: contract.Gpu_Texture, view: contract.Gpu_TextureView) -> bool
```

### 2.4 Bukti masalah

- **Banyak submit/pass per frame** — lihat 2.2.
- **Chrome cache mati:** `chrome_view.odin:199` `chrome_renderer_mark_dirty(true)` **tiap** frame → `chrome_renderer.odin:111` tak pernah hit; `composer_pipeline` stats/`savings_ratio` kosong.
- **Damage diabaikan app:** core punya `Damage_Tracker` + `Damage_Journal` (spans per row) dan `terminal_consume_damage` (`terminal.odin:70`), tapi `terminal_view.odin:186-329` me-render **seluruh** grid tiap frame.
- **Resize non-adaptif:** hanya `WINDOW_PIXEL_SIZE_CHANGED` (`events.odin:172`); tidak menangani `WINDOW_RESIZED`/`WINDOW_EXPOSED`, tidak flush event basi, tidak present intermediate; `contentsGravity=topLeft` diset prematur (`window_darwin.odin:83-122` dipanggil `window.odin:50`, sebelum `create_surface`).
- **Pilar tak terpakai produksi:** `terminal/tile` + `terminal/fullscreen` hanya dipakai `harness_render_terminal`; `composer/{scheduler,transition,frame}` hanya dipakai harness; `three_d` hidup di `features/interaction` + `multiplexer` (`pane.interactor`) tetapi tidak pernah dirender app.
- **`three_d` bypass abstraksi:** `three_d_draw(r, pass: wgpu.RenderPassEncoder, ...)` (`three_d.odin:497`) memakai tipe wgpu langsung, bukan `contract`.
- **Raster leaf submit sendiri:** `terminal_view_render_pane` dan `chrome_renderer_render` masing-masing membuat encoder+submit — tidak cocok dengan `Frame_Raster_Proc` yang **memberi** encoder.

---

## 3. Arsitektur target

### 3.1 Prinsip

1. **Satu encoder, satu submit, satu present per frame** — via `frame_tick`.
2. **Raster = encode-scoped.** Leaf renderer tidak boleh membuat encoder/submit; dia menerima encoder/pass dari pemanggil.
3. **Damage-driven.** Terminal meng-upload hanya baris/span yang berubah; scheduler menggerakkan frame hanya saat ada damage/animasi/deadline.
4. **Layer dirty menentukan raster; layer clean hanya di-blit.** Cache chrome menjadi nyata.
5. **Resize = force + present langsung.** Event resize/expose memicu reconfigure + `scheduler_force_next` + tick sekarang.
6. **Backend-only leaf.** Semua leaf render hanya lewat `core/render/contract`.

### 3.2 Kepemilikan loop

App berhenti memiliki loop render ad-hoc. `app_run` menjadi:

```
layout_update
dirty := app_process_events                (event → scheduler_mark_damage / force / anim)
multiplexer_drain_all → scheduler_mark_damage bila ada output
app_sync_layout_and_winsize → scheduler_mark_damage bila winsize berubah
frame.frame_tick(&app.fsched, &app.composer.pipe, &app.transitions, &app.driver, now_ns)
```

`Frame_Driver` app mengimplementasikan `acquire`/`raster`/`present`:
- `acquire`  → `contract.get_surface_texture(app.surface)`.
- `raster`   → dispatch berdasarkan `l.kind` (lihat 3.4).
- `present`  → `contract.present_surface(app.surface)` + `release_surface_texture`.

### 3.3 Model layer

Pertahankan 2-layer utama; sediakan layer tambahan lewat mekanisme yang sudah ada:

| ID | Kind | Isi | Sumber |
|---|---|---|---|
| `101` | `.Terminal` | semua pane terminal aktif tab | `terminal_view`, damage-driven |
| `201` | `.Chrome` | tab bar, pane border/focus ring, cursor, command center | `chrome_view`, cache nyata |
| `301` (opsional) | `.Three_D` | pane yang memakai `interactor` | `three_d`, di-blit di atas Terminal |
| `0xFFFFFFFE`/`0xFFFFFFFD` | `.Overlay` | modal/dropdown | `MODAL_LAYER_ID`, `CHROME_LAYER_ID` (`types.odin:22`) |

`layer_pool_acquire` sudah menangani reuse + realloc saat ukuran berubah + bump `version` + set `is_dirty` (`layer_pool.odin:50-129`), jadi resize layer otomatis aman.

### 3.4 Raster contract (refactor inti)

Ubah leaf renderer dari **"buat encoder + submit"** menjadi **"encode ke pass yang diberikan"**:

- `terminal_view_render_pane` → `terminal_view_encode(pass/enc, pane, layer_view, ...)`
- `chrome_renderer_render`      → `chrome_renderer_encode(pass/enc, dl, target_view, ...)`
- `three_d_draw`                → ganti parameter `wgpu.RenderPassEncoder` menjadi `contract.Gpu_RenderPassEncoder` (butuh migrasi `three_d` ke `contract`).

`raster` app untuk tiap `l.kind`:

```
.Terminal: begin pass ke l.view (loadOp=.Clear) → untuk tiap pane: encode pane (damage/strategy) → end pass
.Chrome:   chrome_renderer_encode(...)  (hanya bila chrome surface dirty)
.Three_D:  begin pass ke l.view → three_d_draw(contract pass) → end pass
```

Semua di dalam **encoder yang sama** yang diberikan `frame_tick`. Composite (blit semua layer) juga di encoder yang sama (`composer_pipeline_composite`, `pipeline.odin:236`).

### 3.5 Terminal damage-driven + strategy selector

Wire damage yang sudah ada:

1. `session.term.damage` diisi parser (sudah jalan).
2. Di raster Terminal untuk pane terkait: `journal := terminal_consume_damage(&pane.session.term)` (`terminal.odin:70`).
3. `journal.dirty_rows` (per-row: `full` atau `spans`) → emit instance **hanya** untuk baris/span kotor. Jika `journal.has_damage == false` dan layer masih clean → raster dilewati sepenuhnya.
4. **Buffer instance per-pane persisten** (bukan `instance_renderer_begin` yang reset tiap frame): update sub-range `[row*cols .. row*cols+n]` via `write_buffer(offset=...)`. Perlu helper upload sub-range di app (tidak butuh perubahan contract).
5. **Strategy selector** (`selector.odin`) diaktifkan:
   - `Strategy_Inputs{ dirty_cells, total_cells, ratio, full_rows, span_count, scroll }` dari journal.
   - `strategy_select(inp, &state, compute_avail, fullscreen_avail)` → `.Instance` / `.Compute_Tiles` / `.Fullscreen`.
   - `.Instance` → `terminal/instance` (sekarang).
   - `.Compute_Tiles` → `terminal/tile` (compute shader ke offscreen texture lalu blit). Butuh `begin_compute_pass` (sudah ada di contract: `backend.odin:378`) + storage texture.
   - `.Fullscreen` → `terminal/fullscreen` (single triangle baca cell storage buffer).
   - `strategy_record(state, s, ns)` dari durasi submit untuk override online.
   - `scroll` dan single-cell update dikunci ke `.Instance` (sudah di `selector.odin:67,124`).
6. `scheduler_mark_damage(s, LAYER_TERMINAL, rect)` saat journal `has_damage`.

Catatan: `.Compute_Tiles`/`.Fullscreen` butuh cell storage buffer di GPU; saat ini `instance` mengirim instance records dari CPU. Wiring penuh ketiga strategi = menambah path upload cell/params. Ini pekerjaan Fase 3 (lihat §5).

### 3.6 Chrome cache nyata

- `chrome_view_build_and_render` berhenti memanggil `mark_dirty(true)` tiap frame.
- Hitung **signature murah** dari draw list (mis. hash jumlah command + rect/kind/color, atau `version` state chrome) → `chrome_renderer_mark_dirty(sig_berubah || resize)`.
- Bila tidak dirty: `raster` untuk `.Chrome` **dilewati**; `composite` tetap men-blit texture cache chrome (`frame_tick` men-blit semua layer in-use, `frame.odin:112`).
- Ini mengaktifkan Strategy 1 (`chrome/surface/surface.odin`) yang sekarang mati.

### 3.7 three_d ter-wire

- Migrasi `three_d` dari `vendor:wgpu` langsung ke `core/render/contract` (draw param jadi `contract.Gpu_RenderPassEncoder`).
- Render ke layer `.Three_D` (303) di atas Terminal, di bawah Chrome; di-update via driver.
- Manfaatkan `three_d_resize` (`three_d.odin:463`) saat resize layer.
- Jika pane tak memakai `interactor`, layer Three_D di-release (`composer_pipeline_release_layer`).

### 3.8 Live-resize & present path (fix utama)

**Event path (`src/app/term/events.odin` + helper):**

1. Tangani `WINDOW_RESIZED`, `WINDOW_PIXEL_SIZE_CHANGED`, **dan** `WINDOW_EXPOSED`.
2. Saat resize: `sdl3.FlushEvents(WINDOW_RESIZED, WINDOW_PIXEL_SIZE_CHANGED)` untuk buang backlog basi, lalu `window_update_pixel_size` dan ambil ukuran live dari OS.
3. `app_handle_window_resize`: set `layout.screen_w/h`, `configure_surface` ukuran baru, `composer_view_resize`, `chrome_view_resize`, `layer_pool` akan realloc saat `acquire` berikutnya.
4. `scheduler_force_next(&app.fsched)` → `frame_tick` sekarang (present intermediate).
5. Opsi kuat: pasang `sdl3.AddEventWatch` yang, untuk event resize/expose, langsung `scheduler_force_next` + tick, sehingga present tak menunggu drain loop (ini mekanisme yang terbukti di `legacy/src/app/main.odin:1935`).

**CAMetalLayer (macOS):**

- Panggil ulang konfigurasi gravity **setelah** `create_surface` (CAMetalLayer sudah ada): `contentsGravity = kCAGravityTopLeft` + `contentsScale = backingScaleFactor`.
- Tujuan: saat drawable lama masih ter-display, CoreAnimation mem-pin 1:1 (tidak stretch/pillarbox) sampai frame baru tiba.

**Present mode:**

- Default `Fifo`. Pertimbangkan `Immediate`/`Mailbox` saat drag interaktif (via `contract.set_present_mode`, `wgpu.odin:420`) bila present latency jadi masalah.

### 3.9 Model koordinat/DPI

- **Satu sumber kebenaran: pixel fisik.** `layout.screen_w/h = window.pixel_w/h`; semua uniform/layer/surface diturunkan dari sini.
- `Visual_Metrics` diskalakan sekali di `visual_metrics_make(scale)`; `layout_set_scale` mempertahankan `cell_w/h` bila sudah ada (`layout.odin:32-39`).
- Pastikan `configure_surface`, `composer_view_resize`, `chrome_view_resize` memakai nilai pixel yang sama dalam satu frame (sekarang sudah, tapi tidak ada guard/assert).

---

## 4. Perubahan kontrak backend

Perlu dicek/ditambah (hanya bila wiring strategi tile/fullscreen jadi):

| Kebutuhan | Status di `contract` |
|---|---|
| Compute pass + dispatch | **Ada** (`begin_compute_pass`, `compute_dispatch`, `backend.odin:378-382`) |
| Storage texture binding | **Ada** (`Gpu_Binding_Type.Storage_Texture`, `backend.odin:163`) |
| `render_set_viewport`/`scissor` | **Ada** (belum dipakai app) |
| Upload sub-range buffer | `write_buffer(offset)` sudah menerima offset — cukup di sisi app |
| Depth attachment | **Ada** (`begin_render_pass_with_depth`) untuk three_d |

Kesimpulan: kemungkinan **tidak perlu** perubahan kontrak; cukup refactor leaf agar encode ke pass yang diberikan.

---

## 5. Migration plan

Setiap fase harus hijau `make test` **dan** `make check` sebelum lanjut. Bench (`make bench`) dipakai untuk memverifikasi klaim performa.

### Fase 0 — Refactor raster encode-scoped (fondasi)
- Ubah `terminal_view_render_pane` & `chrome_renderer_render` menjadi encode ke `pass` eksternal (tanpa encoder/submit sendiri).
- Migrasi `three_d_draw` ke `contract.Gpu_RenderPassEncoder`.
- Perkenalkan `app.frame_driver` (`acquire`/`raster`/`present`).
- **DoD:** build hijau; harness render tetap jalan; belum ada perubahan perilaku.
- **Risiko:** rendah–sedang (banyak call-site).

### Fase 1 — Resize correctness (fix bug yang dilaporkan)
- Event: tangani `WINDOW_RESIZED`/`PIXEL_SIZE_CHANGED`/`EXPOSED`; flush backlog; force + tick.
- CAMetalLayer: gravity/contentsScale setelah surface dibuat.
- **DoD:** tidak ada stretch saat live resize (uji manual drag + e2e `resize_e2e_real`).
- **Risiko:** rendah.

### Fase 2 — App pindah ke `frame_tick`
- Ganti `app_render_frame` dengan `frame_tick`; sambungkan `Frame_Scheduler` + `Transition_Manager`.
- Pindahkan animasi tab-bar/cursor ke `transition` + `scheduler_set_anim_active`/`set_deadline`.
- **DoD:** 1 encoder + 1 submit/frame; idle zero-work terverifikasi (tidak ada submit saat diam); `chrome cache` mulai efektif.
- **Risiko:** sedang.

### Fase 3 — Damage-driven + strategy selector
- Wire `terminal_consume_damage` → raster baris/span; buffer instance per-pane persisten + upload sub-range.
- Aktifkan `strategy_select`; implementasi path `.Compute_Tiles` (`tile`) dan `.Fullscreen` (`fullscreen`) + upload cell/params.
- **DoD:** invariant #3 (O(changes) damage) terukur; `strategy_record` mengisi telemetry; p95 render turun.
- **Risiko:** tinggi (shader/storage buffer baru).

### Fase 4 — Chrome cache nyata + three_d
- Signature draw list → mark dirty; hapus `mark_dirty(true)` per frame.
- Wire `three_d` sebagai layer.
- **DoD:** chrome tidak di-raster saat statis (counter `cached_frames` naik, `redraw_count` datar); three_d tampil di pane yang memakainya.
- **Risiko:** sedang.

### Fase 5 — Hardening
- Hapus jalur lama yang tak terpakai setelah migrasi (`composer_view` ad-hoc path).
- Tambah `test-render-contract` untuk: (a) 1 submit/frame, (b) idle zero submit, (c) resize force present, (d) cache hit chrome.

---

## 6. Pemetaan invariant (KB)

| Invariant | Bagaimana target memenuhi |
|---|---|
| 1. Steady-state zero heap alloc | Buffers/pools pre-allocated; `frame_tick` tanpa alloc; upload sub-range via offset |
| 2. ASCII fast path | Tetap di parser/glyph atlas (tidak berubah) |
| 3. O(changes) damage | `Damage_Journal` spans → raster baris/span saja (Fase 3) |
| 4. Idle zero work | `scheduler_needs_frame` gate + chrome cache (Fase 2/4) |

---

## 7. Risiko & open questions

- **R1:** Memindahkan raster ke encode-scoped menyentuh banyak renderer (instance/chrome/three_d). Mitigasi: Fase 0 tanpa perubahan perilaku, harness jadi regression gate.
- **R2:** `.Compute_Tiles`/`.Fullscreen` butuh storage buffer cell di GPU + shader baru. Mitigasi: default tetap `.Instance`, selector hanya mengaktifkan tile/fullscreen setelah `compute_avail`/`fullscreen_avail` benar-benar siap.
- **R3:** `frame_tick` men-blit **semua** layer in-use tiap frame; bila layer > 2 perlu cek biaya blit.
- **Q1:** Apakah animasi tab-bar/cursor dipindah ke `composer/transition` (konsisten) atau tetap di layout/cursor lalu hanya mark damage? 
- **Q2:** Apakah three_d dirender sebagai layer penuh (303) atau hanya di pane bertanda? 
- **Q3:** Izin mengubah `three_d` (migrasi ke `contract`) — saat ini import wgpu langsung, melanggar "backend-only leaf".
- **Q4:** Present mode saat drag: tetap `Fifo` (default) atau `Immediate`?

---

## 8. Verifikasi (definisi selesai per fase)

1. `make test` hijau (tampilkan output).
2. `make check` (`-strict-style`) hijau.
3. `make bench`/`make bench-quick` untuk klaim performa (p50/p95/p99).
4. Uji resize manual: drag lambat & cepat, lebar & tinggi; tidak ada stretch/pillarbox; teks 1:1.
5. Re-read file yang diubah; tidak ada dead code/komentar sisa.
