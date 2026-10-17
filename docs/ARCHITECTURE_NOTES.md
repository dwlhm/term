# Architecture Notes — Layering & Entry Point

Status: catatan observasi. **Belum ada perubahan kode.**
Bagian "Proposal" belum disetujui dan tidak menggantikan keputusan arsitektur mana pun.

---

## 1. Fakta (terverifikasi dari kode)

### 1.1 Entry point melakukan setup produk, bukan hanya fundamental
`src/app/term/main.odin:47` `app_init` mencampur tiga kelas pekerjaan:

| Baris | Isi | Kelas |
|---|---|---|
| 52-87 | window, instance/surface/device, font+atlas, terminal/chrome/composer view | fundamental |
| 89-95 | mouse, cursor, clipboard, command_center, `tabs_manager_init`, `multiplexer_init` | produk |
| 97-111 | hitung `term_cols/rows`, spawn pane, tab `"Shell"`, focus, partisi split tree, sync rect | kebijakan produk |

### 1.2 Manager N-session tidak ada sebagai unit tersendiri
Tidak ada tipe "manager untuk banyak shell/PTY". Fungsi itu jadi efek samping dari `Multiplexer`:

- `features/multiplexer/multiplexer.odin:32` — `panes: [dynamic]Pane_Entry` (registry N session)
- `features/multiplexer/multiplexer.odin:23` — `session: ^session.Terminal_Session`
- `features/multiplexer/multiplexer.odin:229` — `multiplexer_drain_all` (IO pump N session, zero UI)
- `features/multiplexer/multiplexer.odin:240` — `multiplexer_sync_split_rects` (produk/layout)
- `features/multiplexer/multiplexer.odin:206` — `multiplexer_toggle_zoom` (produk/gimmick)

`features/session` hanya mengurus **satu** session (pty + VT + damage).

### 1.3 Model pane membawa tipe core render
- `features/multiplexer/multiplexer.odin:24` — `interactor: three_d.Three_D_Interactor` (by value, dari `core/render/three_d`)
- `features/multiplexer/multiplexer.odin:15-18` — `Pane_Kind { Terminal, Three_D }`
- `features/multiplexer/multiplexer.odin:98` — `three_d.interactor_init` dipanggil di dalam feature
- `features/interaction/interaction.odin:121,176,202,219` — `three_d.interactor_on_mouse_*` dipanggil langsung dari feature

### 1.4 Dua pemilik geometri
- Split tree hidup di `features/tabs` (`tabs.odin:19` `Tab_Entry.split_tree`)
- `pane.rect` hidup di `features/multiplexer`
- Jembatan: `src/app/term/render.odin:19` `multiplexer_sync_split_rects(&app.mux, active_tab.split_tree)`

### 1.5 Invariant yang berlaku
`docs/ROADMAP_EXECUTION_PLAN.md:83-84` — Tier 1 `core_*` tidak boleh import `core_*` lain
(Zero Horizontal Coupling). Ini alasan session (pty + parser) ditaruh di Tier 2.

### 1.6 Zoom belum mengubah geometri
`multiplexer_toggle_zoom` hanya set `zoomed_pane_id`/`is_zoomed` + focus.
`saved_rect` (`multiplexer.odin:28`) tidak pernah ditulis/dibaca — tidak ada konsumen yang menerapkan rect zoom.

---

## 2. Proposal (belum disetujui)

Konsep pemisahan: **fundamental (product-agnostic)** vs **produk (gimmick)**.

- Fundamental: window, GPU, render, composer, font/atlas, PTY engine, VT parser,
  registry N-session + IO pump + routing id→session.
- Produk: penseleksian pane fokus, split layout, zoom, tab bar, judul tab, cols/rows awal.

Arah usulan:

1. Pecah `features/multiplexer` menjadi:
   - `session_manager` — registry N + `drain_all` + routing, zero UI (product-agnostic).
   - `panes` — layout/focus/zoom (produk).
2. Jadikan manager-N benar-benar core dengan memutus dependensi langsung ke
   `core_platform`: definisikan session terhadap `contract` (handle pty opaque + fn pointer),
   bukan `import pty`. Dengan begitu hanya butuh `core_terminal` + `contract`
   dan tidak melanggar Zero Horizontal Coupling.
3. Keluarkan `Three_D_Interactor` dari `Pane_Entry` (state kamera dimiliki `core/render/three_d`,
   pane hanya menyimpan handle/id).
4. `app_init` hanya bootstrap core + manager session; pembuatan pane/tab default
   dipindah ke "default workspace profile" yang jalan setelah core siap.
