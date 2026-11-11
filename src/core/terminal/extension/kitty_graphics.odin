package terminal_extension

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:strconv"
import "core:strings"

MAX_KITTY_IMAGES :: 32

Kitty_Screen :: enum u8 {
	Primary   = 0,
	Alternate = 1,
}

Kitty_Image :: struct {
	id:                 u32,
	width, height:      int,
	channels:           int,
	pixels:             []u8,
	cols, rows:         int,
	x_col, y_row:       int,
	is_virtual:         bool,
	is_active:          bool,
	screen:             Kitty_Screen,
	last_used:          u64,
	gpu_texture:        rawptr,
	gpu_view:           rawptr,
	gpu_group:          rawptr,
	gpu_dirty:          bool,
	animation:          Kitty_Animation,
}

Kitty_Responder          :: #type proc(term: rawptr, response: []u8) -> bool
Kitty_Cursor_Provider    :: #type proc(term: rawptr) -> (row: int, col: int)
Kitty_Cell_Size_Provider :: #type proc(term: rawptr) -> (cell_w: int, cell_h: int)
Kitty_Grid_Size_Provider :: #type proc(term: rawptr) -> (cols: int, rows: int)
Kitty_Cursor_Advancer    :: #type proc(term: rawptr, cols: int, rows: int)
Kitty_Damage_Notifier    :: #type proc(term: rawptr, start_row, row_count: int)
Kitty_Screen_Provider    :: #type proc(term: rawptr) -> Kitty_Screen

Kitty_Extension :: struct {
	images:              [MAX_KITTY_IMAGES]Kitty_Image,
	image_count:         int,
	lru_counter:         u64,
	placements:          [dynamic]Kitty_Placement,
	chunk_buf:           [dynamic]u8,
	in_chunk_transmission: bool,
	current_action:      u8,
	current_id:          u32,
	current_placement:   u32,
	current_format:      int, // 32 = RGBA, 24 = RGB, 100 = PNG
	current_medium:      u8,  // 'd' = direct, 's' = shm, 'f' = file, 't' = temp file
	current_compression: u8,  // 'z' = zlib / deflate
	current_delete:      u8,  // 'a', 'i', 'p', 'c', 'z'
	current_cursor_move: int, // 0 = advance, 1 = keep
	current_virtual:     int, // 1 = placeholder only (U=1)
	current_shm_size:    int,
	current_width:       int,
	current_height:      int,
	current_cols, current_rows:         int,
	current_src_x, current_src_y:       int,
	current_src_w, current_src_h:       int,
	current_z:                          int,
	current_frame_num, current_gap:     int,
	current_composition:                u8,
	current_anim_state:                 int,
	current_anim_loops:                 int,
	current_offset_x, current_offset_y: int,
	current_quiet:       int,
	responder:           Kitty_Responder,
	cursor_provider:     Kitty_Cursor_Provider,
	cell_size_provider:  Kitty_Cell_Size_Provider,
	grid_size_provider:  Kitty_Grid_Size_Provider,
	cursor_advancer:     Kitty_Cursor_Advancer,
	damage_notifier:     Kitty_Damage_Notifier,
	screen_provider:     Kitty_Screen_Provider,
	next_anon_id:        u32,
	total_pixel_bytes:   int,
	allocator:           runtime.Allocator,
}

_parse_int_val :: proc(s: string) -> int {
	val, ok := strconv.parse_int(s)
	return val if ok else 0
}

_kitty_handle_query :: proc(state: ^Kitty_Extension, term: rawptr, img_id: u32, is_query_action: bool = false) -> bool {
	if state == nil || state.responder == nil || term == nil do return false
	if img_id == 0 && !is_query_action do return false
	resp: string
	if state.current_placement > 0 {
		resp = fmt.tprintf("\x1b_Gi=%d,p=%d;OK\x1b\\", img_id, state.current_placement)
	} else if img_id > 0 {
		resp = fmt.tprintf("\x1b_Gi=%d;OK\x1b\\", img_id)
	} else {
		resp = "\x1b_Gi=0;OK\x1b\\"
	}
	return state.responder(term, transmute([]u8)resp)
}

_kitty_respond_error :: proc(state: ^Kitty_Extension, term: rawptr, img_id: u32, code: Kitty_Error_Code) -> bool {
	if state == nil || state.responder == nil || term == nil do return false
	name := kitty_error_name(code)
	if len(name) == 0 do return false
	resp := fmt.tprintf("\x1b_Gi=%d;%s\x1b\\", img_id, name)
	return state.responder(term, transmute([]u8)resp)
}

_kitty_animation_bytes :: proc(anim: ^Kitty_Animation) -> int {
	total := 0
	for frame in anim.frames do total += len(frame.pixels)
	return total
}

_kitty_account_release :: proc(state: ^Kitty_Extension, bytes: int) {
	if bytes > 0 do state.total_pixel_bytes = max(0, state.total_pixel_bytes - bytes)
}

_kitty_account_reserve :: proc(state: ^Kitty_Extension, bytes: int) -> bool {
	if state == nil || bytes <= 0 do return false
	if state.total_pixel_bytes + bytes > KITTY_MAX_TOTAL_PIXEL_BYTES do return false
	state.total_pixel_bytes += bytes
	return true
}

// _kitty_reclaim_pixels evicts idle images (and their placements) until `needed`
// bytes fit into the shared pixel budget.
_kitty_reclaim_pixels :: proc(state: ^Kitty_Extension, needed: int) -> bool {
	if state.total_pixel_bytes + needed <= KITTY_MAX_TOTAL_PIXEL_BYTES do return true
	for i in 0..<MAX_KITTY_IMAGES {
		if state.total_pixel_bytes + needed <= KITTY_MAX_TOTAL_PIXEL_BYTES do return true
		img := &state.images[i]
		if img.id == 0 || img.is_active || img.is_virtual do continue
		_kitty_handle_delete(state, img.id, 'i', 0, 0, 0, 0)
	}
	return state.total_pixel_bytes + needed <= KITTY_MAX_TOTAL_PIXEL_BYTES
}

@(private = "file")
_kitty_find_lru_slot :: proc(state: ^Kitty_Extension) -> int {
	oldest_lru: u64 = max(u64)
	slot := -1
	for i in 0..<MAX_KITTY_IMAGES {
		img := &state.images[i]
		if !img.is_active && img.last_used < oldest_lru {
			oldest_lru = img.last_used
			slot = i
		}
	}
	if slot != -1 do return slot

	oldest_lru = max(u64)
	for i in 0..<MAX_KITTY_IMAGES {
		img := &state.images[i]
		if img.last_used < oldest_lru {
			oldest_lru = img.last_used
			slot = i
		}
	}
	return slot if slot != -1 else 0
}

_kitty_store_image :: proc(state: ^Kitty_Extension, img_id: u32, w, h: int, px: []u8, term: rawptr, place: bool) -> bool {
	if state == nil do return false
	if !kitty_dims_valid(w, h) do return false
	if len(px) < w * h * 4 do return false
	if !_kitty_reclaim_pixels(state, len(px)) do return false
	if !_kitty_account_reserve(state, len(px)) do return false

	slot := -1
	for i in 0..<MAX_KITTY_IMAGES {
		img := &state.images[i]
		if img_id > 0 && img.id == img_id {
			slot = i
			break
		}
		if slot == -1 && img.id == 0 && !img.is_active {
			slot = i
		}
	}
	if slot == -1 do slot = _kitty_find_lru_slot(state)

	target := &state.images[slot]
	if target.id != 0 do _kitty_handle_delete(state, target.id, 'i', 0, 0, 0, 0)
	target = &state.images[slot]
	target.id, target.width, target.height, target.channels, target.pixels = img_id, w, h, 4, px
	target.screen = state.screen_provider(term) if (state.screen_provider != nil && term != nil) else .Primary
	target.is_virtual = (state.current_virtual == 1)
	target.gpu_dirty = true
	target.is_active = place || target.is_virtual
	target.cols = state.current_cols
	target.rows = state.current_rows
	state.lru_counter += 1
	target.last_used = state.lru_counter

	if place && !target.is_virtual {
		_kitty_handle_put(state, term, img_id)
	}
	return true
}

_kitty_reset_ctrl_state :: proc(state: ^Kitty_Extension) {
	if state == nil do return
	state.current_cols, state.current_rows, state.current_width, state.current_height = 0, 0, 0, 0
	state.current_src_x, state.current_src_y, state.current_src_w, state.current_src_h = 0, 0, 0, 0
	state.current_z, state.current_frame_num, state.current_gap = 0, 0, 0
	state.current_composition = 0
	state.current_anim_state, state.current_anim_loops = 0, 0
	state.current_offset_x, state.current_offset_y = 0, 0
	state.current_medium, state.current_format, state.current_delete = 'd', 32, 0
	state.current_compression = 0
	state.current_virtual, state.current_cursor_move, state.current_quiet, state.current_shm_size = 0, 0, 0, 0
	state.current_action = 'T'
	state.current_id = 0
	state.current_placement = 0
	state.in_chunk_transmission = false
}

_kitty_sanitize_base64 :: proc(raw: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(raw) == 0 do return nil
	clean := make([dynamic]u8, 0, len(raw), allocator)
	for b in raw {
		switch b {
		case '\r', '\n', ' ', '\t':
			continue
		case '-':
			append(&clean, '+') // Base64URL translation
		case '_':
			append(&clean, '/') // Base64URL translation
		case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/':
			append(&clean, b)
		case '=':
			// Discard intermediate '=' padding; we re-pad correctly at the end
			continue
		case:
			continue
		}
	}
	rem := len(clean) % 4
	if rem == 2 {
		append(&clean, '=')
		append(&clean, '=')
	} else if rem == 3 {
		append(&clean, '=')
	}
	return clean[:]
}

_kitty_decode_chunk_buf :: proc(state: ^Kitty_Extension) -> (px: []u8, w, h: int) {
	if len(state.chunk_buf) == 0 do return nil, 0, 0
	defer clear(&state.chunk_buf)

	clean_buf := _kitty_sanitize_base64(state.chunk_buf[:], state.allocator)
	if len(clean_buf) == 0 do return nil, 0, 0
	defer delete(clean_buf, state.allocator)

	raw_str := string(clean_buf)
	decoded, dec_err := base64.decode(raw_str, allocator = state.allocator)
	if dec_err != nil || len(decoded) == 0 do return nil, 0, 0
	defer delete(decoded, state.allocator)

	return _kitty_decode_payload(state, decoded)
}

_kitty_finish_transmission :: proc(state: ^Kitty_Extension, term: rawptr, place: bool) {
	px, w, h := _kitty_decode_chunk_buf(state)
	if len(px) == 0 || w <= 0 || h <= 0 do return

	if !kitty_dims_valid(w, h) || len(px) < w * h * 4 {
		delete(px, state.allocator)
		_kitty_respond_error(state, term, state.current_id, .Invalid_Request)
		return
	}

	img_id := state.current_id
	if img_id == 0 {
		state.next_anon_id += 1
		img_id = 0x80000000 + state.next_anon_id
	}
	// Ownership of `px` transfers to the image store only on success.
	if !_kitty_store_image(state, img_id, w, h, px, term, place) {
		delete(px, state.allocator)
		_kitty_respond_error(state, term, img_id, .Out_Of_Space)
	}
}

_kitty_finish_frame_transmission :: proc(state: ^Kitty_Extension, term: rawptr, img_id: u32) {
	px, w, h := _kitty_decode_chunk_buf(state)
	if len(px) == 0 || w <= 0 || h <= 0 do return

	img := _kitty_find_image(state, img_id)
	if img == nil || !kitty_dims_valid(w, h) || len(px) < w * h * 4 {
		delete(px, state.allocator)
		_kitty_respond_error(state, term, img_id, .Invalid_Request)
		return
	}
	_kitty_handle_frame(state, term, img, px, w, h)
}

kitty_graphics_handle_apc :: proc(ext: ^Terminal_Extension, payload: []u8, term: rawptr) -> bool {
	if ext == nil || len(payload) < 2 || payload[0] != 'G' do return false
	state := (^Kitty_Extension)(ext.user_data)
	if state == nil do return false

	semi_idx := -1
	for i in 1..<len(payload) {
		if payload[i] == ';' { semi_idx = i; break }
	}

	ctrl_str := string(payload[1:semi_idx]) if semi_idx >= 0 else string(payload[1:])
	action, more := _kitty_parse_ctrl_params(state, ctrl_str)
	img_id := state.current_id

	switch action {
	case 'q':
		ok := _kitty_handle_query(state, term, img_id, is_query_action = true)
		_kitty_reset_ctrl_state(state)
		return ok
	case 'd':
		cur_c, cur_r := 0, 0
		if state.cursor_provider != nil && term != nil {
			cur_r, cur_c = state.cursor_provider(term)
		}
		_kitty_handle_delete(
			state,
			img_id,
			state.current_delete,
			state.current_placement,
			cur_c,
			cur_r,
			state.current_z,
		)
		if state.current_quiet == 0 && img_id > 0 do _kitty_handle_query(state, term, img_id)
		_kitty_reset_ctrl_state(state)
		return true
	case 'p':
		_kitty_handle_put(state, term, img_id)
		if state.current_quiet == 0 && img_id > 0 do _kitty_handle_query(state, term, img_id)
		_kitty_reset_ctrl_state(state)
		return true
	case 'f':
		if semi_idx >= 0 && semi_idx + 1 < len(payload) {
			append(&state.chunk_buf, ..payload[semi_idx + 1:])
		}
		state.in_chunk_transmission = (more != 0)
		if more == 0 {
			finish_id := state.current_id
			_kitty_finish_frame_transmission(state, term, finish_id)
			if state.current_quiet == 0 && finish_id > 0 do _kitty_handle_query(state, term, finish_id)
			_kitty_reset_ctrl_state(state)
		}
		return true
	case 'a':
		img := _kitty_find_image(state, img_id)
		if img != nil do _kitty_handle_anim_ctrl(state, img)
		if state.current_quiet == 0 && img_id > 0 do _kitty_handle_query(state, term, img_id)
		_kitty_reset_ctrl_state(state)
		return true
	case 't', 'T':
		if semi_idx >= 0 && semi_idx + 1 < len(payload) {
			append(&state.chunk_buf, ..payload[semi_idx + 1:])
		}
		state.in_chunk_transmission = (more != 0)
		if more == 0 {
			finish_id := state.current_id
			_kitty_finish_transmission(state, term, place = (action == 'T'))
			if state.current_quiet == 0 && finish_id > 0 do _kitty_handle_query(state, term, finish_id)
			_kitty_reset_ctrl_state(state)
		}
		return true
	}
	return false
}

kitty_graphics_init :: proc(ext: ^Terminal_Extension, term: rawptr) {
	if ext == nil do return
	state := new(Kitty_Extension, context.allocator)
	state.allocator = context.allocator
	state.chunk_buf = make([dynamic]u8, 0, 16384, state.allocator)
	state.placements = make([dynamic]Kitty_Placement, 0, 256, state.allocator)
	_kitty_reset_ctrl_state(state)
	ext.user_data = rawptr(state)
}

kitty_graphics_deinit :: proc(ext: ^Terminal_Extension) {
	if ext == nil || ext.user_data == nil do return
	state := (^Kitty_Extension)(ext.user_data)
	_kitty_handle_delete(state, 0, 'a', 0, 0, 0, 0)
	delete(state.chunk_buf)
	delete(state.placements)
	free(state, state.allocator)
	ext.user_data = nil
}

kitty_graphics_handle_clear :: proc(ext: ^Terminal_Extension, mode: int, term: rawptr) {
	if ext == nil || ext.user_data == nil do return
	state := (^Kitty_Extension)(ext.user_data)
	screen: Kitty_Screen = .Primary
	if state.screen_provider != nil && term != nil {
		screen = state.screen_provider(term)
	}
	_kitty_handle_clear_screen(state, mode, screen)
}

kitty_graphics_handle_scroll :: proc(ext: ^Terminal_Extension, n: int, top, bottom: int, term: rawptr) {
	if ext == nil || ext.user_data == nil do return
	state := (^Kitty_Extension)(ext.user_data)
	if len(state.placements) == 0 do return // every LF scrolls: skip the screen lookup when nothing is placed
	screen: Kitty_Screen = .Primary
	if state.screen_provider != nil && term != nil {
		screen = state.screen_provider(term)
	}
	_kitty_handle_grid_scroll(state, n, top, bottom, screen)
}

kitty_graphics_handle_resize :: proc(ext: ^Terminal_Extension, new_rows, new_cols: int, delta_y: int, term: rawptr) {
	if ext == nil || ext.user_data == nil do return
	state := (^Kitty_Extension)(ext.user_data)
	_kitty_handle_resize(state, new_rows, new_cols, delta_y, term)
}

kitty_graphics_handle_dcs :: proc(ext: ^Terminal_Extension, payload: []u8, term: rawptr) -> bool {
	if ext == nil || ext.user_data == nil || len(payload) == 0 do return false
	state := (^Kitty_Extension)(ext.user_data)

	q_found := false
	for b in payload {
		if b == 'q' || b == 'Q' {
			q_found = true
			break
		}
		if (b < '0' || b > '9') && b != ';' && b != '?' && b != ' ' {
			return false
		}
	}
	if !q_found do return false

	px, w, h, ok := sixel_decode(payload, state.allocator)
	if !ok || len(px) == 0 || w <= 0 || h <= 0 do return false

	state.next_anon_id += 1
	img_id := 0x82000000 + state.next_anon_id

	_kitty_store_image(state, img_id, w, h, px, term, place = true)
	return true
}

kitty_graphics_extension_make :: proc(allocator := context.allocator) -> Terminal_Extension {
	return Terminal_Extension{
		name          = "kitty_graphics",
		user_data     = nil,
		init          = kitty_graphics_init,
		handle_apc    = kitty_graphics_handle_apc,
		handle_dcs    = kitty_graphics_handle_dcs,
		handle_clear  = kitty_graphics_handle_clear,
		handle_scroll = kitty_graphics_handle_scroll,
		handle_resize = kitty_graphics_handle_resize,
		deinit        = kitty_graphics_deinit,
	}
}

kitty_graphics_get_image :: proc(ext_ptr: rawptr, id: u32) -> ^Kitty_Image {
	if ext_ptr == nil do return nil
	return _kitty_find_image((^Kitty_Extension)(ext_ptr), id)
}
