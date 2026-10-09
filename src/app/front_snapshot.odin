package main

import "base:runtime"
import "core:sync"
import termgrid "../terminal"
import render "../render"
import inter "../interaction"

SNAPSHOT_SLOT_COUNT :: 3
NEW_FRAME_FLAG      :: 1 << 8
SLOT_INDEX_MASK     :: 0xFF
ROW_BITSET_WORDS    :: 8 // Supports up to 512 rows

// Front_Snapshot contains the immutable terminal render state copied from the
// backend worker thread for display by the frontend renderer.
Front_Snapshot :: struct {
	terminal:                    termgrid.Terminal,
	view:                        termgrid.Terminal_View,
	cursor:                      render.Cursor_Overlay,
	interaction:                 inter.Interaction_State,
	focused:                     bool,
	exited:                      bool,
	search_invalid_regex:        bool,
	scrollback_synced_pushed:    u64,
	scrollback_synced_clear_gen: u64,
	seq:                         u64,
	base_seq:                    u64,
}

// Reader_State tracks the main thread's slot consumption and redraw state.
Reader_State :: struct {
	read_index:        int,
	drawn_seq:         u64,
	force_full_redraw: bool,
}

Row_Bitset :: [ROW_BITSET_WORDS]u64

bitset_set :: #force_inline proc(b: ^Row_Bitset, row: int) {
	if row < 0 || row >= ROW_BITSET_WORDS * 64 do return
	b[row / 64] |= 1 << uint(row % 64)
}

bitset_is_set :: #force_inline proc(b: ^Row_Bitset, row: int) -> bool {
	if row < 0 || row >= ROW_BITSET_WORDS * 64 do return false
	return (b[row / 64] & (1 << uint(row % 64))) != 0
}

bitset_clear :: #force_inline proc(b: ^Row_Bitset) {
	b^ = {}
}

front_snapshot_init :: proc(s: ^Front_Snapshot, rows, cols: int, theme: termgrid.Theme) {
	if s == nil do return
	termgrid.terminal_init(&s.terminal, rows, cols, theme = theme)
	s.view = termgrid.Terminal_View{}
	s.cursor = render.Cursor_Overlay{}
	inter.interaction_init(&s.interaction)
	s.focused = true
	s.exited = false
	s.search_invalid_regex = false
	s.scrollback_synced_pushed = 0
	s.scrollback_synced_clear_gen = 0
	s.seq = 0
	s.base_seq = 0
}

front_snapshot_destroy :: proc(s: ^Front_Snapshot) {
	if s == nil do return
	termgrid.terminal_destroy(&s.terminal)
}

// backend_refresh_snapshot atomically inspects the exchange slot and adopts any
// newly published snapshot. Returns true if a new frame was acquired.
backend_refresh_snapshot :: proc(b: ^Backend) -> bool {
	if b == nil do return false
	middle := sync.atomic_load(&b.middle)
	if (middle & NEW_FRAME_FLAG) == 0 {
		return false
	}
	old := sync.atomic_exchange(&b.middle, b.reader.read_index)
	b.reader.read_index = old & SLOT_INDEX_MASK
	slot := &b.snapshots[b.reader.read_index]
	if slot.base_seq != b.reader.drawn_seq || b.reader.force_full_redraw {
		termgrid.damage_mark_all(&slot.terminal.damage, nil)
		b.reader.force_full_redraw = false
	}
	return true
}

// backend_snapshot returns a pointer to the active front snapshot owned by the main thread.
backend_snapshot :: proc(b: ^Backend) -> ^Front_Snapshot {
	if b == nil do return nil
	idx := b.reader.read_index
	if idx < 0 || idx >= SNAPSHOT_SLOT_COUNT do return nil
	return &b.snapshots[idx]
}

// backend_publish_snapshot synchronizes changed back buffer state into the write slot
// and atomically exchanges it with the middle slot for the main thread.
backend_publish_snapshot :: proc(b: ^Backend) {
	_backend_publish_snapshot(b)
}

_backend_publish_snapshot :: proc(b: ^Backend) {
	if b == nil do return
	slot_idx := b.write_index
	if slot_idx < 0 || slot_idx >= SNAPSHOT_SLOT_COUNT do return

	snap := &b.snapshots[slot_idx]
	dst := &snap.terminal
	src := &b.terminal
	view := &b.view

	// 1. Grid resize if dimensions changed
	dims_changed := dst.grid.row_count != src.grid.row_count || dst.grid.col_count != src.grid.col_count
	alt_screen_switched := dst.is_alt_screen != src.is_alt_screen
	origin_changed := dst.grid.origin != src.grid.origin
	do_full := b.needs_full_copy[slot_idx] || dims_changed || alt_screen_switched || origin_changed

	if dims_changed {
		termgrid.terminal_resize(dst, src.grid.row_count, src.grid.col_count)
	}

	// 2. Copy active grid cells (Delta-only via missed_rows unless full copy required)
	dst.grid.origin = src.grid.origin
	dst.grid.mask = src.grid.mask
	dst.grid.style_table = src.grid.style_table

	if dst.grid.cells != nil && src.grid.cells != nil {
		if do_full {
			copy(dst.grid.cells, src.grid.cells)
			if dst.grid.ext_colors != nil && src.grid.ext_colors != nil {
				copy(dst.grid.ext_colors, src.grid.ext_colors)
			}
			for i in 0..<src.grid.capacity {
				if i < len(dst.grid.rows) && i < len(src.grid.rows) {
					dst.grid.rows[i].generation = src.grid.rows[i].generation
					dst.grid.rows[i].wrapped = src.grid.rows[i].wrapped
					dst.grid.rows[i].is_prompt = src.grid.rows[i].is_prompt
					dst.grid.rows[i].ext.channels = src.grid.rows[i].ext.channels
				}
			}
			for r in 0..<dst.damage.row_count {
				if r < len(dst.damage.dirty_rows) {
					dst.damage.dirty_rows[r].full = true
				}
			}
		} else {
			for r in 0..<src.grid.row_count {
				dirty_in_src := false
				if r < src.damage.row_count && r < len(src.damage.dirty_rows) {
					dr := src.damage.dirty_rows[r]
					dirty_in_src = dr.full || dr.span_count > 0
				}
				is_missed := bitset_is_set(&b.missed_rows[slot_idx], r)
				if is_missed || dirty_in_src {
					src_phys := (src.grid.origin + r) & src.grid.mask
					dst_phys := (dst.grid.origin + r) & dst.grid.mask
					if src_phys < len(src.grid.rows) && dst_phys < len(dst.grid.rows) {
						copy(dst.grid.rows[dst_phys].cells, src.grid.rows[src_phys].cells)
						dst.grid.rows[dst_phys].generation = src.grid.rows[src_phys].generation
						dst.grid.rows[dst_phys].wrapped = src.grid.rows[src_phys].wrapped
						dst.grid.rows[dst_phys].is_prompt = src.grid.rows[src_phys].is_prompt
						dst.grid.rows[dst_phys].ext.channels = src.grid.rows[src_phys].ext.channels
						if len(dst.grid.rows[dst_phys].ext.colors) > 0 && len(src.grid.rows[src_phys].ext.colors) > 0 {
							copy(dst.grid.rows[dst_phys].ext.colors, src.grid.rows[src_phys].ext.colors)
						}
					}
					if r < len(dst.damage.dirty_rows) {
						dst.damage.dirty_rows[r].full = true
						dst.damage.dirty_rows[r].generation = src.grid.rows[src_phys].generation
					}
				}
			}
		}
	}

	// Record src damage into other slots' missed_rows before clearing src damage
	for r in 0..<src.damage.row_count {
		if r < len(src.damage.dirty_rows) {
			dr := src.damage.dirty_rows[r]
			if dr.full || dr.span_count > 0 {
				for s_idx in 0..<SNAPSHOT_SLOT_COUNT {
					if s_idx != slot_idx {
						bitset_set(&b.missed_rows[s_idx], r)
					}
				}
			}
		}
	}

	// 3. Alternate grid synchronization (only if alt screen is active)
	if src.is_alt_screen {
		dst.alt_grid.origin = src.alt_grid.origin
		dst.alt_grid.mask = src.alt_grid.mask
		dst.alt_grid.style_table = src.alt_grid.style_table
		if dst.alt_grid.cells != nil && src.alt_grid.cells != nil {
			copy(dst.alt_grid.cells, src.alt_grid.cells)
			if dst.alt_grid.ext_colors != nil && src.alt_grid.ext_colors != nil {
				copy(dst.alt_grid.ext_colors, src.alt_grid.ext_colors)
			}
		}
		for i in 0..<src.alt_grid.capacity {
			if i < len(dst.alt_grid.rows) && i < len(src.alt_grid.rows) {
				dst.alt_grid.rows[i].generation = src.alt_grid.rows[i].generation
				dst.alt_grid.rows[i].wrapped = src.alt_grid.rows[i].wrapped
				dst.alt_grid.rows[i].is_prompt = src.alt_grid.rows[i].is_prompt
				dst.alt_grid.rows[i].ext.channels = src.alt_grid.rows[i].ext.channels
			}
		}
	}

	dst.is_alt_screen = src.is_alt_screen
	dst.cursor = src.cursor
	dst.saved_cursor = src.saved_cursor
	dst.saved_cursor_valid = src.saved_cursor_valid
	dst.current_style = src.current_style

	// 4. Scrollback lazily synced
	if dst.scrollback.max_lines != src.scrollback.max_lines || dst.scrollback.col_count != src.scrollback.col_count {
		termgrid.scrollback_destroy(&dst.scrollback, nil)
		termgrid.scrollback_init(&dst.scrollback, src.scrollback.col_count, src.scrollback.max_lines)
		snap.scrollback_synced_pushed = 0
		snap.scrollback_synced_clear_gen = 0
	}

	dst.scrollback.head = src.scrollback.head
	dst.scrollback.count = src.scrollback.count
	dst.scrollback.total_pushed = src.scrollback.total_pushed
	dst.scrollback.clear_generation = src.scrollback.clear_generation

	viewing_history := view != nil && view.scrollback_offset > 0
	needs_cell_sync := snap.scrollback_synced_pushed != src.scrollback.total_pushed ||
	                   snap.scrollback_synced_clear_gen != src.scrollback.clear_generation
	if viewing_history && needs_cell_sync {
		if dst.scrollback.cells != nil && src.scrollback.cells != nil {
			copy(dst.scrollback.cells, src.scrollback.cells)
			if dst.scrollback.ext_colors != nil && src.scrollback.ext_colors != nil {
				copy(dst.scrollback.ext_colors, src.scrollback.ext_colors)
			}
		}
		for i in 0..<src.scrollback.max_lines {
			dst.scrollback.rows[i].wrapped = src.scrollback.rows[i].wrapped
			dst.scrollback.rows[i].ext.channels = src.scrollback.rows[i].ext.channels
		}
		snap.scrollback_synced_pushed = src.scrollback.total_pushed
		snap.scrollback_synced_clear_gen = src.scrollback.clear_generation
	}

	// 5. Graphics
	graphics_changed := dst.graphics_namespace != src.graphics_namespace
	if dst.graphics == nil || src.graphics == nil {
		graphics_changed = graphics_changed || dst.graphics != src.graphics
	} else {
		graphics_changed = graphics_changed ||
			dst.graphics.epoch != src.graphics.epoch ||
			dst.graphics.placement_epoch != src.graphics.placement_epoch ||
			dst.graphics.upload_count != src.graphics.upload_count
	}
	if dst.graphics_alt == nil || src.graphics_alt == nil {
		graphics_changed = graphics_changed || dst.graphics_alt != src.graphics_alt
	} else {
		graphics_changed = graphics_changed ||
			dst.graphics_alt.epoch != src.graphics_alt.epoch ||
			dst.graphics_alt.placement_epoch != src.graphics_alt.placement_epoch ||
			dst.graphics_alt.upload_count != src.graphics_alt.upload_count
	}
	if graphics_changed {
		graphics_allocator := dst.state_allocator if dst.state_allocator_set else runtime.heap_allocator()
		termgrid.terminal_graphics_sync(dst, src, graphics_allocator)
		termgrid.damage_mark_all(&dst.damage, nil)
	}

	// 6. Damage & scroll ops
	for op in src.damage.scroll_ops {
		append(&dst.damage.scroll_ops, op)
	}
	termgrid.terminal_clear_damage(src)

	dst.cwd = src.cwd
	dst.cwd_len = clamp(src.cwd_len, 0, len(dst.cwd))

	if src.title_dirty {
		backend_post_event(b, .Title_Changed)
		dst.window_title = src.window_title
		dst.window_title_len = src.window_title_len
		dst.title_dirty = true
		src.title_dirty = false
	}

	dst.scroll_top = src.scroll_top
	dst.scroll_bottom = src.scroll_bottom
	dst.grapheme_store = src.grapheme_store
	dst.render_epoch = src.render_epoch
	dst.in_prompt_zone = src.in_prompt_zone
	dst.has_osc_133 = src.has_osc_133
	dst.bracketed_paste = src.bracketed_paste
	dst.focus_reporting = src.focus_reporting
	dst.app_cursor_keys = src.app_cursor_keys
	dst.mouse_tracking = src.mouse_tracking
	dst.mouse_format = src.mouse_format
	dst.synchronized_output = src.synchronized_output
	dst.kitty_kb = src.kitty_kb
	dst.kitty_kb_alt = src.kitty_kb_alt
	if src.bell_event {
		backend_post_event(b, .Bell)
		dst.bell_event = true
		src.bell_event = false
	}
	for src.notification_count > 0 {
		notif, ok := termgrid.terminal_pop_notification(src)
		if ok {
			backend_post_notification(b, string(notif.title[:notif.title_len]), string(notif.message[:notif.message_len]))
			termgrid.terminal_push_notification(dst, notif.title[:notif.title_len], notif.message[:notif.message_len])
		}
	}
	if src.hyperlinks.count != dst.hyperlinks.count {
		dst.hyperlinks = src.hyperlinks
	}
	dst.charset_g0 = src.charset_g0
	dst.charset_g1 = src.charset_g1
	dst.active_charset_is_g1 = src.active_charset_is_g1
	dst.active_charset_is_dec = src.active_charset_is_dec

	// Auxiliary Front_Snapshot state
	snap.view = b.view
	snap.cursor = b.cursor
	snap.interaction = b.interaction
	snap.focused = b.focused
	snap.exited = b.pty.state == .Exited
	snap.search_invalid_regex = b.search_invalid_regex

	// Update sequence numbers and clear slot tracking
	snap.base_seq = snap.seq
	b.publish_seq += 1
	snap.seq = b.publish_seq
	bitset_clear(&b.missed_rows[slot_idx])
	b.needs_full_copy[slot_idx] = false

	// Lock-free 3-slot exchange
	old := sync.atomic_exchange(&b.middle, slot_idx | NEW_FRAME_FLAG)
	b.write_index = old & SLOT_INDEX_MASK
}
