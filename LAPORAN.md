# LAPORAN UTAMA — Terminal Emulator Berperforma Tinggi (Odin)

> Proyek: terminal emulator berperforma tinggi dalam Odin — 21 fase (0–20) selesai.
> Filosofi: jalur terpendek PTY bytes -> terminal state -> glyph -> pixel; kerja proporsional terhadap perubahan aktual.
> Prinsip: Don't compute what can be inferred. Don't copy what can be referenced. Don't redraw what did not change. Don't assume an optimization is faster. Measure it.

---

## Daftar Isi

- 1. Ringkasan Eksekutif
- 2. Arsitektur Akhir
- 3. Invarian Arsitektural
- 4. Laporan Per Fase (0–20)
- 5. Tabel Benchmark Gabungan
- 6. Keputusan Arsitektur Kunci
- 7. Status Test Akhir
- 8. Cara Memakai Harness untuk Ide Baru
- 9. Pekerjaan Lanjutan

---

## 1. Ringkasan Eksekutif

Seluruh 21 fase (Fase 0 sampai Fase 20) telah selesai. Hasilnya adalah terminal emulator di Odin dengan karakteristik berikut:

- **Fondasi terukur:** Fase 0 membangun benchmark harness + trace replay dengan metrik p50/p95/p99/p99.9. Semua keputusan sesudahnya diambil lewat gate angka, bukan intuisi.
- **State terminal O(perubahan):** grid ring-buffer dengan scroll O(1), hierarki damage cell -> span -> row, parser VT scalar dengan tabel transisi 2KB.
- **Path ASCII cepat tanpa cabang mahal:** ASCII tidak melewati decode, shaping, atau lookup. UTF-8, grapheme combining-mark, fallback multi-font, dan shaping Arab hanya aktif di luar path ASCII.
- **Renderer adaptif 3 strategi:** Instance untuk teks jarang dan scroll kecil, Compute_Tiles untuk baris teks padat, Fullscreen untuk layar penuh. Selektor adaptif memilih per frame dengan biaya 35.9ns dan tidak pernah meng-override carve-out scroll/1-sel.
- **Upload proporsional:** dirty upload 1 sel hanya 288B dibanding layar penuh 184320B (sekitar 1/640), dengan draw tetap 2.
- **Scroll datar:** scroll O(1) terbukti datar sekitar 251–275ns untuk 24 -> 192 baris (rasio < 1.5), tanpa memmove, dengan DECSTBM ditutup.
- **Ketahanan font realistis:** fallback chain maksimal 4 font + presentation-form Arab + shape cache 1024; badai cache-miss 37.16ms diredam menjadi 0.692ms (x53.7) lewat rasterisasi asinkron dengan 1 worker dan strategi blank-then-pop-in.
- **Kemenangan prinsip no-dogma terbesar:** SIMD dipertahankan sebagai scalar karena SIMD 19x pada ASCII murni tetapi 0.2x pada CSI/OSC/UTF-8 (geomean 0.68 < 1.15). SDF/MSDF dibuang karena 5 dari 6 gate gagal. WGPU dipertahankan. FIFO dipertahankan. Fase 20 ditutup tanpa kerja GPU analitik baru karena atlas hanya 128 KiB dan tidak ada kebutuhan zoom/effects.

Status akhir: semua fase berstatus selesai dengan verdict eksplisit KEEP / DISCARD / TUTUP, didukung benchmark dan test.

---

## 2. Arsitektur Akhir

### 2.1 Pipeline data ujung-ke-ujung

```
PTY bytes -> input ring -> SIMD/scalar scanner -> VT state machine -> terminal mutator -> semantic state + damage -> render compiler -> packed GPU grid -> adaptive selector -> Instance | Compute_Tiles | Fullscreen -> GPU backend WGPU -> present
```

Penjelasan tiap tahap:

```
PTY bytes -> input ring
  Input mentah dari PTY ditampung di ring agar pembacaan tidak memblokir dan tidak menyalin lebih dari perlu.
  Prinsip: Don't copy what can be referenced.

input ring -> SIMD/scalar scanner
  Scanner memilah run ASCII murni dari sekuens CSI/OSC/UTF-8.
  ASCII murni lewat jalur cepat; sisanya ke path lengkap.
  Verdict Fase 13: scalar DIPERTAHANKAN untuk campuran realistis.

SIMD/scalar scanner -> VT state machine
  VT state machine memakai tabel transisi 2KB.
  Throughput terukur: ~39 MB/s ASCII, 3.4M CSI/detik.

VT state machine -> terminal mutator
  Mutator mengubah grid: tulis sel, scroll, erase, mode DECSTBM, atribut SGR.
  Scroll O(1) via ring-buffer offset; audit membuktikan tanpa memmove.

terminal mutator -> semantic state + damage
  State semantik menyimpan sel + atribut; damage menandai cell -> span -> row yang berubah.
  Kompleksitas O(perubahan), bukan O(layar).

semantic state + damage -> render compiler
  Render compiler mengubah sel kotor menjadi sel GPU yang dipadatkan.
  Memakai Render_Cell_V2 64-bit + Style_LUT; chain-break terbukti via grep.
  Pilihan default P64 (P48 ternyata 8B, SoA kalah).

render compiler -> packed GPU grid
  Grid GPU yang padat diunggah secara dirty: hanya baris/sel kotor.
  1 sel = 288B vs layar penuh = 184320B.

packed GPU grid -> adaptive selector
  Selector memilih strategi per frame dalam 35.9ns.
  Aturan: T1=I, T2=C, T3=I, T4=F pada mix uji; carve-out scroll/1-sel tak pernah dioverride.

adaptive selector -> Instance | Compute_Tiles | Fullscreen
  Instance: 2 draw (background + glyph), terbaik untuk jarang dan scroll kecil.
  Compute_Tiles: terbaik untuk baris padat (T2 baris 3x compute).
  Fullscreen: 1 draw(3,1), terbaik untuk penuh (crossover 25% vs instance, 100% vs compute).

Instance | Compute_Tiles | Fullscreen -> GPU backend WGPU -> present
  Backend KEEP WGPU. Overhead vtable 46ns/frame = 0.0003%.
  Atlas fixed-slot 512 via stb_truetype; 95/95 ASCII.
```

### 2.2 Diagram komponen terperinci

```
PTY -> ring buffer -> scanner -> parser -> grid -> damage -> compiler -> uploader -> strategi -> WGPU -> layar
  PTY         : sumber byte (escape, CSI, OSC, UTF-8, ASCII)
  ring buffer : input ring, menampung burst tanpa alokasi steady-state
  scanner     : pemilah ASCII-run vs kontrol (bagian Fase 2/3)
  parser      : VT state machine 2KB, scalar
  grid        : ring-buffer grid O(1) scroll + DECSTBM
  damage      : hierarki cell -> span -> row
  compiler    : Render_Cell_V2 64-bit + Style_LUT
  uploader    : dirty upload 288B per sel
  strategi    : Instance vs Compute_Tiles vs Fullscreen + adaptive 35.9ns
  WGPU        : backend GPU final + atlas prosedural diganti raster stb_truetype
  layar       : present via SDL3 + WGPU
```

### 2.3 Peta direktori (ringkas)

```
src/app/ -> entry aplikasi
src/app_phase4/ -> baseline SDL3 + WGPU
src/app_phase5/ -> atlas fixed-slot + stb_truetype
src/app_phase6/ -> instance renderer live GPU
src/bench/ -> benchmark harness + trace replay
src/parser/ -> VT state machine + ASCII run parser + scanner
src/terminal/ -> grid ring-buffer + mutator + damage + UTF-8/grapheme + fallback
src/render/ -> atlas + compiler + packed grid + Instance + Compute_Tiles + Fullscreen + adaptive + experiments
src/render/experiments/ -> eksperimen SDF/MSDF + sdf_decide + sdf_experiment_run
src/platform/ -> SDL3 + WGPU backend + glue
src/tests/ -> render + terminal + parser + bench + experiments + gpu-bench
docs/phase20_analytic_glyph_note.md -> catatan penutup Fase 20
PHASE1_IMPLEMENTATION_PLAN.md -> rencana Fase 1
implementation_plan_phase2.md -> rencana Fase 2
```

---

## 3. Invarian Arsitektural

Empat invarian dipertahankan dari awal sampai akhir dan diverifikasi lewat benchmark/audit:

### 3.1 Steady-state alokasi 0

- Setelah inisialisasi, frame steady-state tidak mengalokasi.
- Ring buffer, pool grapheme 256x4, shape cache 1024, slot atlas 512 semuanya pre-alokasi.
- Rasterisasi asinkron memakai 1 worker dengan antrean terbatas agar tidak ada alokasi dadakan di path frame.

### 3.2 ASCII path tanpa decode/shaping/lookup

- ASCII tidak melewati UTF-8 decode, tidak melewati shaping, tidak melewati lookup font berat.
- UTF-8 + grapheme combining-mark, fallback chain, dan presentation-form Arab hanya aktif untuk non-ASCII.
- Bukti: Fase 10 ASCII -3.3% dalam gate ±10%; Fase 11 ASCII +2.1%. Artinya penambahan Unicode tidak merusak path cepat.

### 3.3 Kompleksitas O(perubahan)

- Semua kerja proporsional terhadap sel/baris yang berubah, bukan ukuran layar.
- Damage: cell -> span -> row.
- Upload: 1 sel 288B vs penuh 184320B.
- Draw: tetap 2 untuk Instance; Fullscreen 1 draw(3,1) hanya saat penuh benar-benar lebih murah.
- Scroll: O(1) via offset ring, bukan memmove baris.

### 3.4 Idle nol kerja

- Saat tidak ada byte PTY baru dan tidak ada damage, tidak ada compile, upload, atau draw ulang yang tidak perlu.
- Prinsip yang ditegakkan: Don't redraw what did not change.
- Adaptive selector + damage memastikan frame idle tidak membayar biaya strategi berat.

---

## 4. Laporan Per Fase (0–20)

### Fase 0 — Benchmark Harness + Trace Replay

- **Tujuan:** menegakkan prinsip "Don't assume an optimization is faster. Measure it." dengan harness yang dapat diulang dan trace replay yang realistis.
- **File/komponen yang dibangun:** `src/bench/` (harness benchmark, pelari trace replay, penghitung persentil).
- **Hasil benchmark dan angka:** metrik p50/p95/p99/p99.9 untuk setiap eksperimen. Harness ini menjadi gerbang semua fase berikutnya; tidak ada klaim performa tanpa angka persentil.
- **Keputusan penting:** semua fase wajib lewat gate harness. Tanpa harness ini, perdebatan SIMD vs scalar, Instance vs Compute, dan SDF vs bitmap tidak akan bisa diputuskan secara mekanis.

### Fase 1 — Grid Ring-Buffer O(1) Scroll + Damage Hierarchy

- **Tujuan:** membuat state terminal dengan scroll O(1) dan damage yang proporsional terhadap perubahan.
- **File/komponen yang dibangun:** `src/terminal/` (grid ring-buffer, mutator, hierarki damage cell -> span -> row).
- **Hasil benchmark dan angka:** scroll O(1) secara struktur; 33 test lulus.
- **Keputusan penting:** scroll diimplementasikan sebagai pergeseran offset ring, bukan memmove memori baris. Damage dirancang berlapis agar compiler dan uploader hanya memproses yang kotor.

### Fase 2 — Scalar VT Parser + Tabel Transisi 2KB

- **Tujuan:** parser VT yang cepat, kecil, dan dapat diprediksi untuk campuran ASCII + CSI realistis.
- **File/komponen yang dibangun:** `src/parser/` (VT state machine, tabel transisi 2KB, penghitung CSI).
- **Hasil benchmark dan angka:** ~39 MB/s ASCII; 3.4M CSI/detik; 31 test lulus.
- **Keputusan penting:** pilih scalar + tabel kompak 2KB. Tabel kecil ramah cache dan mudah diaudit. Kecepatan CSI jutaan per detik membuktikan state machine tidak menjadi bottleneck untuk trace realistis.

### Fase 3 — ASCII Run Parser (Bagian dari Fase 2)

- **Tujuan:** memisahkan run ASCII murni agar tidak membayar biaya parsing kontrol per byte.
- **File/komponen yang dibangun:** bagian dari `src/parser/` (ASCII run parser / scanner ASCII-run).
- **Hasil benchmark dan angka:** termasuk dalam angka Fase 2 (~39 MB/s ASCII). Tidak ada benchmark terpisah karena memang satu kesatuan arsitektur.
- **Keputusan penting:** ASCII-run adalah fondasi invarian "ASCII path tanpa decode/shaping/lookup". Fase ini tidak berdiri sendiri; ia adalah optimasi struktural di dalam parser Fase 2.

### Fase 4 — SDL3 + WGPU Baseline + Atlas Prosedural Sementara

- **Tujuan:** menegakkan jalur present nyata seawal mungkin agar semua pengukuran sesudahnya di atas GPU sungguhan, bukan mock.
- **File/komponen yang dibangun:** `src/app_phase4/`, `src/platform/` (SDL3 + WGPU backend + glue + atlas prosedural sementara).
- **Hasil benchmark dan angka:** baseline frame tersaji (angka spesifik diwarisi sebagai pembanding fase 6/8/14/15). Atlas prosedural hanya placeholder.
- **Keputusan penting:** atlas prosedural dinyatakan sementara sejak awal; diganti rasterisasi font sungguhan di Fase 5. Baseline ini mencegah optimasi yang hanya cepat di CPU tetapi lambat saat present.

### Fase 5 — Atlas Fixed-Slot 512 + Rasterisasi stb_truetype

- **Tujuan:** mengganti placeholder dengan raster font sungguhan yang deterministik.
- **File/komponen yang dibangun:** `src/render/atlas.odin` (atlas fixed-slot 512, rasterisasi stb_truetype).
- **Hasil benchmark dan angka:** 95/95 ASCII terraster dengan benar; box-drawing tidak ada karena Menlo tidak punya glif tersebut (bukan bug atlas).
- **Keputusan penting:** fixed-slot 512 dipilih untuk kesederhanaan dan determinisme. Geometri atlas yang lahir di sini mengunci masa depan: 16 kolom x 32 baris, glif 16px, tekstur 256x512px = 131072 byte = 128 KiB R8. Angka ini menjadi alasan penolakan glyph analitik di Fase 20.

### Fase 6 — Instance Renderer Live GPU

- **Tujuan:** renderer GPU pertama yang live dengan jumlah draw minimal.
- **File/komponen yang dibangun:** `src/app_phase6/`, `src/render/` (instance renderer, path background + glyph).
- **Hasil benchmark dan angka:** live GPU valid dengan 2 draw: background + glyph.
- **Keputusan penting:** 2 draw menjadi baseline yang harus dikalahkan strategi lain. Setiap strategi baru wajib membuktikan lebih murah dari 2 draw ini pada bebannya masing-masing, bukan secara rata-rata.

### Fase 7 — Packed Render_Cell_V2 64-bit + Style_LUT

- **Tujuan:** memadatkan data sel GPU agar compiler dan upload murah dan ramah cache.
- **File/komponen yang dibangun:** `src/render/` (Render_Cell_V2 64-bit, Style_LUT).
- **Hasil benchmark dan angka:** chain-break terbukti via grep (tidak ada rantai dependensi tersembunyi); default P64 ditetapkan karena P48 ternyata 8B (tidak menghemat), dan SoA kalah dari P64 yang dipadatkan.
- **Keputusan penting:** pilih P64. Pelajaran: jangan percaya asumsi ukuran/struktur tanpa mengukur layout aktual dan grep dependensi.

### Fase 8 — Dirty Upload

- **Tujuan:** menegakkan O(perubahan) pada batas CPU -> GPU.
- **File/komponen yang dibangun:** `src/render/` (uploader dirty, compiler damage -> packed grid).
- **Hasil benchmark dan angka:** 1 sel 288B vs layar penuh 184320B (sekitar 1/640); draw tetap 2.
- **Keputusan penting:** upload penuh hanya untuk kasus penuh yang terbukti; selain itu selalu dirty. Ini yang membuat pengetikan 1 karakter dan kursor berkedip murah.

### Fase 9 — Scroll O(1) Terbukti Datar + Audit Tanpa Memmove

- **Tujuan:** membuktikan klaim O(1) Fase 1 dengan angka, bukan teori.
- **File/komponen yang dibangun:** `src/terminal/` (jalur scroll, audit memmove, penanganan DECSTBM).
- **Hasil benchmark dan angka:** sekitar 251–275ns untuk 24 -> 192 baris, rasio < 1.5 (datar). Audit membuktikan tanpa memmove. DECSTBM ditutup (scroll region terminal ditangani benar).
- **Keputusan penting:** scroll dinyatakan selesai dan tidak dioptimasi lagi. Carve-out scroll dikunci agar selector adaptif Fase 16 tidak pernah meng-override-nya dengan strategi yang salah.

### Fase 10 — UTF-8 + Grapheme (Combining-Mark Only, Pool 256x4)

- **Tujuan:** mendukung Unicode realistis tanpa merusak path ASCII.
- **File/komponen yang dibangun:** `src/terminal/` (decoder UTF-8, grapheme combining-mark only, pool 256x4).
- **Hasil benchmark dan angka:** ASCII -3.3% dalam gate ±10% (lulus). Wide CJK didukung; ZWJ tanpa ligature (disengaja, documented).
- **Keputusan penting:** batasi grapheme pada combining-mark only + pool kecil 256x4. ZWJ ligature ditolak karena biaya shaping penuh tidak sebanding dengan manfaat untuk terminal. Wide CJK ditangani sebagai lebar 2 kolom.

### Fase 11 — Fallback Chain ≤4 Font + Arabic Presentation-Form + Shape Cache 1024

- **Tujuan:** menutup lubang glif hilang untuk CJK dan Arab tanpa menghukum ASCII.
- **File/komponen yang dibangun:** `src/terminal/`, `src/render/` (fallback chain maksimal 4 font, presentation-form Arab, shape cache 1024).
- **Hasil benchmark dan angka:** ASCII +2.1% (tidak regresi, bahkan sedikit lebih baik karena cache). CJK cold 3248µs / hot 163µs (cache bekerja ~20x).
- **Keputusan penting:** batasi chain ≤4 font agar worst-case lookup terbatas. Presentation-form (bukan shaping Arab penuh) dipilih sebagai titik tengah yang cukup untuk terminal. Shape cache 1024 menjadi prasyarat sebelum async di Fase 12.

### Fase 12 — Async Rasterization (Badai Miss 37.16ms -> 0.692ms)

- **Tujuan:** menghilangkan jank saat banyak glif baru muncul sekaligus (misal membuka file CJK/Arab pertama kali).
- **File/komponen yang dibangun:** `src/render/` (pekerja raster asinkron, antrean miss, strategi blank-then-pop-in).
- **Hasil benchmark dan angka:** badai miss 37.16ms -> 0.692ms (x53.7). 1 worker (cukup, tidak perlu pool besar).
- **Keputusan penting:** pilih blank-then-pop-in (sel kosong dulu lalu muncul) dibanding memblokir frame. Pilih 1 worker karena rasterisasi bukan bottleneck throughput setelah cache panas; menambah worker hanya menambah kompleksitas sinkronisasi.

### Fase 13 — SIMD: Scalar DIPERTAHANKAN (Kemenangan Prinsip No-Dogma)

- **Tujuan:** menguji apakah SIMD benar-benar lebih cepat untuk campuran input realistis.
- **File/komponen yang dibangun:** eksperimen scanner SIMD vs scalar di `src/parser/` + harness `src/bench/`.
- **Hasil benchmark dan angka:** SIMD 19x pada ASCII murni tetapi 0.2x pada CSI/OSC/UTF-8; geomean 0.68 < 1.15 (scalar menang secara geometris untuk campuran realistis).
- **Keputusan penting:** scalar DIPERTAHANKAN. Ini kemenangan prinsip "Don't assume an optimization is faster. Measure it." SIMD hanya menang pada mikro-benchmark ASCII murni yang tidak mewakili trace nyata. Keputusan ini dicatat sebagai bukti bahwa tim berani menolak optimasi populer demi angka.

### Fase 14 — Compute Tiles (Smoke GPU Valid + Crossover)

- **Tujuan:** menguji strategi compute-shader tiling sebagai alternatif instance.
- **File/komponen yang dibangun:** `src/render/` (compute tiles path, harness perbandingan strategi).
- **Hasil benchmark dan angka:** smoke GPU valid. Crossover terukur: T2 baris 3x compute (compute menang 3x pada baris padat), T3 scroll 8x instance (instance menang 8x pada scroll), T4 penuh 11.8x compute (compute menang 11.8x pada layar penuh). Scroll membalik crossover.
- **Keputusan penting:** tidak ada strategi tunggal yang menang di semua beban. Temuan "scroll membalik crossover" menjadi alasan langsung lahirnya selector adaptif Fase 16 dan strategi fullscreen Fase 15.

### Fase 15 — Fullscreen Grid (Crossover 25% vs Instance, 100% vs Compute)

- **Tujuan:** menutup celah beban layar-penuh yang tidak dimenangkan instance maupun compute tiles secara dominan.
- **File/komponen yang dibangun:** `src/render/` (fullscreen grid path, 1 draw(3,1)).
- **Hasil benchmark dan angka:** crossover 25% vs instance (fullscreen menang saat kotor ≥25% dibanding instance), 100% vs compute (fullscreen menang saat penuh 100% dibanding compute). 1 draw(3,1).
- **Keputusan penting:** fullscreen adalah strategi ketiga yang sah, bukan pengganti. Dengan tiga strategi, seluruh spektrum beban tertutup: jarang/instance, baris-padat/compute, penuh/fullscreen.

### Fase 16 — Adaptive Strategy (35.9ns/Pilih)

- **Tujuan:** memilih strategi terbaik per frame secara otomatis dan murah.
- **File/komponen yang dibangun:** `src/render/` (adaptive selector).
- **Hasil benchmark dan angka:** 35.9ns per pilih; mix uji T1=I T2=C T3=I T4=F (masing-masing beban memilih pemenangnya); carve-out scroll/1-sel tak pernah dioverride.
- **Keputusan penting:** kunci carve-out scroll/1-sel sebagai aturan keras. Selector tidak boleh "pintar" mengalahkan aturan O(perubahan) yang sudah terbukti. Biaya 35.9ns dapat diabaikan dibanding biaya draw/upload.

### Fase 17 — KEEP WGPU

- **Tujuan:** memutuskan backend GPU final secara mekanis.
- **File/komponen yang dibangun:** evaluasi di `src/platform/` (WGPU vs Vulkan vs SDL3-GPU).
- **Hasil benchmark dan angka:** overhead vtable 46ns/frame = 0.0003% (dapat diabaikan).
- **Keputusan penting:** KEEP WGPU. Vulkan ditolak karena tanpa driver (tidak ada keuntungan terukur). SDL3-GPU ditolak karena butuh translasi shader (biaya migrasi tanpa keuntungan terukur). Prinsip: jangan pindah backend tanpa angka yang membenarkan.

### Fase 18 — KEEP-FIFO (Cache Atlas)

- **Tujuan:** memutuskan kebijakan eviksi cache atlas.
- **File/komponen yang dibangun:** evaluasi kebijakan eviksi di `src/render/atlas.odin` + harness.
- **Hasil benchmark dan angka:** nol eviksi di semua trace realistis; hit 0.95–0.999.
- **Keputusan penting:** KEEP-FIFO. Kebijakan sederhana menang karena beban nyata tidak pernah menekan atlas 512 slot sampai eviksi. LRU/LFU yang lebih pintar ditolak karena kompleksitas tanpa keuntungan terukur.

### Fase 19 — DISCARD SDF/MSDF (5 dari 6 Gate Gagal)

- **Tujuan:** menguji apakah signed-distance-field dapat menggantikan bitmap atlas.
- **File/komponen yang dibangun:** `src/render/experiments/sdf_experiment.odin` (sdf_decide di :657, sdf_experiment_run di :715).
- **Hasil benchmark dan angka:** 5 dari 6 gate gagal; MAE 0.111 vs 0.04 (error hampir 3x ambang); stem hilang 4 (kualitas teks rusak).
- **Keputusan penting:** DISCARD SDF/MSDF. RETAIN mensyaratkan semua gate lolos simultan (sdf_experiment.odin:5-6). Kualitas bitmap dipertahankan. Ini penolakan berbasis gate pra-registrasi, bukan selera.

### Fase 20 — TUTUP dengan Catatan Riset + Trigger Buka-Ulang

- **Tujuan:** menutup eksplorasi glyph analitik tanpa meninggalkan lubang metodologi.
- **File/komponen yang dibangun:** `docs/phase20_analytic_glyph_note.md` (hanya dokumen; tidak ada file .odin yang ditambah/diubah/dihapus).
- **Hasil benchmark dan angka:** atlas hanya 128 KiB (256x512px R8 dari 16x16 slot 16px); tanpa zoom/effects tak ada kerja yang dibenarkan. Cubic gap tercatat (stb_truetype punya vcubic di :361, vertex dengan cx1/cy1 di :365-368) sebagai risiko spike yang diketahui.
- **Keputusan penting:** TUTUP dengan 4 trigger buka-ulang mekanis T1–T4 (zoom, geometri atlas/fill-path, outline-effects, gate SDF). Tidak ada trigger yang menyala saat ini, maka penolakan berdiri dan tidak ada kerja implementasi yang diotorisasi.

---

## 5. Tabel Benchmark Gabungan

### 5.1 Parser dan terminal

| Area | Metrik | Angka | Fase | Verdict |
|---|---|---|---|---|
| Parser ASCII | throughput | ~39 MB/s | 2 | KEEP scalar |
| Parser CSI | throughput | 3.4M CSI/detik | 2 | KEEP scalar |
| Tabel transisi VT | ukuran | 2KB | 2 | KEEP |
| ASCII run | cakupan | bagian Fase 2 | 3 | KEEP |
| Grid scroll 24 -> 192 baris | latensi | ~251–275ns, rasio < 1.5 | 9 | O(1) terbukti |
| Scroll memmove | audit | tanpa memmove | 9 | KEEP ring-buffer |
| DECSTBM | status | ditutup | 9 | DONE |
| UTF-8 + grapheme | dampak ASCII | -3.3% dalam gate ±10% | 10 | PASS |
| Fallback Arab/CJK | dampak ASCII | +2.1% | 11 | PASS |
| CJK cold / hot | latensi | 3248µs / 163µs | 11 | cache ~20x |
| Shape cache | ukuran | 1024 | 11 | KEEP |
| Grapheme pool | ukuran | 256x4 | 10 | KEEP |
| Fallback chain | kedalaman | ≤4 font | 11 | KEEP |

### 5.2 Render dan upload

| Area | Metrik | Angka | Fase | Verdict |
|---|---|---|---|---|
| Atlas slot | kapasitas | 512 fixed-slot | 5 | KEEP |
| Atlas ASCII | cakupan | 95/95 | 5 | PASS (box-drawing absen karena Menlo) |
| Atlas geometri | ukuran | 256x512px = 131072B = 128 KiB R8 | 5/20 | KUNCI |
| Instance draw | jumlah | 2 (background + glyph) | 6 | BASELINE |
| Packed sel | format | Render_Cell_V2 64-bit + Style_LUT, default P64 | 7 | KEEP P64 |
| Dirty upload 1 sel | byte | 288B | 8 | KEEP |
| Upload penuh | byte | 184320B | 8 | hanya saat penuh |
| Rasio 1-sel vs penuh | rasio | ~1/640 | 8 | O(perubahan) |
| Async badai miss | latensi | 37.16ms -> 0.692ms (x53.7) | 12 | KEEP 1 worker |
| Async strategi | perilaku | blank-then-pop-in | 12 | KEEP |

### 5.3 Strategi dan backend

| Area | Metrik | Angka | Fase | Verdict |
|---|---|---|---|---|
| SIMD ASCII murni | speedup | 19x | 13 | MENANG lokal |
| SIMD CSI/OSC/UTF-8 | speedup | 0.2x | 13 | KALAH telak |
| Geomean campuran | skor | 0.68 < 1.15 | 13 | scalar DIPERTAHANKAN |
| Compute T2 baris | speedup | 3x compute | 14 | compute menang |
| Instance T3 scroll | speedup | 8x instance | 14 | instance menang |
| Compute T4 penuh | speedup | 11.8x compute | 14 | compute menang |
| Fullscreen vs instance | crossover | 25% | 15 | fullscreen menang saat kotor ≥25% |
| Fullscreen vs compute | crossover | 100% | 15 | fullscreen menang saat penuh |
| Fullscreen draw | jumlah | 1 draw(3,1) | 15 | KEEP |
| Adaptive pilih | biaya | 35.9ns/pilih | 16 | KEEP |
| Adaptive mix | pilihan | T1=I T2=C T3=I T4=F | 16 | BENAR semua |
| Carve-out | override | tak pernah dioverride | 16 | KUNCI |
| WGPU vtable | overhead | 46ns/frame = 0.0003% | 17 | KEEP WGPU |
| FIFO hit | rasio | 0.95–0.999, nol eviksi realistis | 18 | KEEP-FIFO |
| SDF MAE | error | 0.111 vs 0.04 | 19 | GAGAL |
| SDF stem | hilang | 4 | 19 | GAGAL |
| SDF gate | lolos | 1 dari 6 (5 gagal) | 19 | DISCARD |

---

## 6. Keputusan Arsitektur Kunci dan Alasannya

1. **Scalar dipertahankan atas SIMD.** Alasan: geomean campuran realistis 0.68 < 1.15; SIMD hanya menang pada ASCII murni yang tidak mewakili trace nyata. Prinsip no-dogma: ukur campuran nyata, bukan mikro-benchmark.
2. **Tiga strategi renderer + selector adaptif, bukan satu pemenang.** Alasan: crossover terbukti berbalik tergantung beban (baris padat milik compute, scroll milik instance, penuh milik fullscreen). Selector 35.9ns menutup spektrum tanpa biaya berarti.
3. **Dirty upload + damage hierarkis sebagai penegak O(perubahan).** Alasan: 1 sel 288B vs penuh 184320B membuktikan kerja proporsional. Tanpa ini, pengetikan ringan membayar biaya layar penuh.
4. **Scroll O(1) ring-buffer + carve-out yang dikunci.** Alasan: datar 251–275ns untuk 24 -> 192 baris dengan audit tanpa memmove. Carve-out mencegah selector adaptif merusak kemenangan yang sudah terbukti.
5. **ASCII path diisolasi dari Unicode.** Alasan: ASCII -3.3% dan +2.1% membuktikan penambahan UTF-8/grapheme/fallback tidak menghukum mayoritas byte. Combining-mark only, pool 256x4, chain ≤4, dan presentation-form adalah batasan yang disengaja agar worst-case tetap kecil.
6. **Async 1 worker + blank-then-pop-in untuk badai miss.** Alasan: 37.16ms -> 0.692ms (x53.7) menghilangkan jank tanpa pool thread yang kompleks. Memblokir frame ditolak; sel kosong sementara lebih baik daripada frame tersendat.
7. **KEEP WGPU + KEEP-FIFO karena beban nyata tidak menuntut lebih.** Alasan: overhead vtable 0.0003% dapat diabaikan; nol eviksi pada semua trace realistis dengan hit 0.95–0.999. Vulkan, SDL3-GPU, dan LRU/LFU ditolak karena biaya migrasi/kompleksitas tanpa keuntungan terukur.
8. **DISCARD SDF/MSDF + TUTUP analitik dengan trigger mekanis.** Alasan: 5 dari 6 gate gagal, MAE 0.111 vs 0.04, stem hilang 4. Fase 20 mengunci penolakan dengan atlas 128 KiB + cubic gap + 4 trigger T1–T4 agar pembukaan ulang hanya terjadi lewat angka, bukan opini.

---

## 7. Status Test Akhir

| Suite | Status | Catatan |
|---|---|---|
| render | lulus | mencakup atlas, compiler packed grid, Instance/Compute/Fullscreen, adaptive selector, async raster |
| terminal | lulus | mencakup grid ring-buffer, scroll O(1), DECSTBM, damage, UTF-8/grapheme, fallback, shape cache |
| parser | lulus | mencakup VT state machine 2KB, ASCII-run, CSI throughput; Fase 1: 33 test, Fase 2: 31 test sebagai fondasi |
| bench | lulus | harness p50/p95/p99/p99.9 + trace replay; gerbang semua keputusan Fase 0–20 |
| experiments | lulus | mencakup eksperimen SIMD vs scalar dan SDF/MSDF (sdf_decide + sdf_experiment_run); verdict DISCARD tercatat |
| gpu-bench | lulus | mencakup smoke GPU compute tiles, crossover T2/T3/T4, crossover fullscreen 25%/100%, biaya selector 35.9ns |

Tidak ada suite yang gagal pada penutupan Fase 20. Test bukan validasi implementasi, melainkan validasi acceptance criteria tiap fase.

---

## 8. Cara Memakai Harness untuk Ide Baru

Alur baku untuk setiap ide baru: hipotesis -> benchmark -> gate -> verdict. Tidak ada jalan pintas.

```
hipotesis -> benchmark -> gate -> verdict -> (KEEP | DISCARD | TUTUP-dengan-trigger)
```

Langkah rinci:

1. **Tulis hipotesis dalam satu kalimat yang dapat diukur.**
   - Contoh: "Strategi X mengalahkan Instance pada beban scroll 192 baris."
   - Contoh: "Kebijakan Y mengurangi miss atlas CJK cold di bawah 1000µs."
   - Tanpa kalimat ini, eksperimen ditolak sejak awal.

2. **Jalankan benchmark lewat harness + trace replay.**
   - Perintah konseptual: jalankan pelari di `src/bench/` terhadap trace realistis (bukan input sintetis ASCII murni).
   - Kumpulkan p50/p95/p99/p99.9. Satu angka rata-rata tidak cukup.
   - Untuk GPU: jalankan `gpu-bench` (smoke + crossover). Untuk parser: ukur MB/s + CSI/detik. Untuk font: ukur cold vs hot.

3. **Tentukan gate pra-registrasi sebelum melihat hasil.**
   - Contoh: "ASCII dalam ±10%; geomean > 1.15 untuk mengganti scalar."
   - Contoh: "RETAIN SDF mensyaratkan semua 6 gate lolos simultan."
   - Contoh: "Fullscreen menang jika kotor ≥25% vs instance."
   - Gate ditulis dulu agar tidak ada penggeseran tiang gawang setelah angka keluar.

4. **Tetapkan verdict secara mekanis.**
   - KEEP: semua gate lolos + crossover jelas + tidak merusak invarian (alokasi 0, O(perubahan), idle nol kerja).
   - DISCARD: satu gate gagal = gagal (contoh Fase 19: 5 dari 6 gagal langsung DISCARD).
   - TUTUP-dengan-trigger: jika ide ditolak tetapi bisa relevan di masa depan, tulis catatan seperti Fase 20 dengan trigger T1–T4 yang menyebutkan metrik, metode, dan kondisi menyala.

5. **Catat carve-out bila menyentuh kemenangan lama.**
   - Jika ide menyentuh scroll, 1-sel, atau ASCII path, buktikan tidak ada regresi pada angka lama (scroll 251–275ns, upload 288B, ASCII ±10%).
   - Jika ragu, kunci carve-out seperti Fase 16: aturan keras mengalahkan selector pintar.

---

## 9. Pekerjaan Lanjutan yang Belum Dikerjakan

- **Native backend bila terukur.** WGPU dipertahankan karena overhead 0.0003% dan tidak ada driver Vulkan yang memberi keuntungan. Backend native (Metal/Vulkan/DX12 langsung) hanya dikerjakan jika ada hipotesis + gate + angka yang membuktikan kemenangan di atas WGPU pada trace realistis.
- **Ligature ZWJ penuh.** Saat ini ZWJ tanpa ligature (disengaja). Shaping penuh hanya dikerjakan jika ada kebutuhan terminal yang mensyaratkan dengan kriteria penerimaan eksplisit, tanpa merusak ASCII path.
- **Shaping Arab penuh.** Saat ini presentation-form + shape cache 1024 (cukup untuk terminal). Shaping kontekstual penuh ditolak sampai ada trace yang membuktikan kebutuhan.
- **Kebijakan eviksi di atas FIFO.** FIFO dipertahankan karena nol eviksi realistis. LRU/LFU/K-TLF hanya dibuka jika trace masa depan menekan atlas 512 slot sampai eviksi nyata.
- **Glyph analitik / SDF / efek outline / zoom.** Ditutup oleh Fase 19–20. Dibuka ulang hanya lewat trigger T1–T4: kebutuhan zoom dengan skala + metrik + ambang, perubahan geometri atlas atau fill-path kubik, kebutuhan outline-effects dengan kriteria, atau perubahan gate SDF disertai hasil harness non-DISCARD.
- **Worker raster tambahan.** Saat ini 1 worker cukup (x53.7). Penambahan worker hanya jika badai miss masa depan terbukti tidak tertangani 1 worker pada p99.9.
- **Strategi renderer keempat.** Tiga strategi + adaptif menutup spektrum saat ini. Strategi baru wajib menunjukkan crossover yang tidak tertutup T1=I T2=C T3=I T4=F dengan biaya pilih tetap puluhan nanos.

---

## Lampiran — Diagram Invarian

```
PT Y bytes -> scanner (ASCII cepat | kontrol lengkap) -> parser 2KB -> mutator O(1) -> damage cell -> span -> row -> compiler P64 -> dirty upload 288B -> pilih I|C|F 35.9ns -> WGPU 46ns overhead -> present
  Crack: CSI/OSC/UTF-8 campuran -> ditangani scalar (SIMD 0.2x ditolak)
  Crack: badai miss 37.16ms -> async 0.692ms + blank-then-pop-in
  Crack: SDF MAE 0.111 vs 0.04 -> DISCARD
  Need: atlas 512 + pool 256x4 + cache 1024 + 1 worker + harness p50-p99.9
```

*Akhir laporan. Satu file saja: LAPORAN.md. Tidak ada file lain yang diubah.*
