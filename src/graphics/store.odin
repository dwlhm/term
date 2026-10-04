package graphics

import "base:runtime"
import "core:bytes"
import "core:compress/zlib"

KGP_MAX_IMAGES :: 256
KGP_MAX_PLACEMENTS :: 128
KGP_MAX_FRAMES :: 64
KGP_MAX_IMAGE_BYTES :: 64 * 1024 * 1024
KGP_UPLOAD_QUEUE_CAP :: 256

KGP_STORE_VISIBLE_ROW_LIMIT :: 1000000
KGP_STORE_RESPONSE_BUFFER_SIZE :: 64
KGP_DEFAULT_FRAME_GAP_MS :: 40

Animation_State :: enum u8 {
	Stopped = 1,
	Loading = 2,
	Running = 3,
}

Frame :: struct {
	width, height: int,
	data:          []u8,
	gap_ms:        i32,
	allocator:     runtime.Allocator,
}

Image_Slot :: struct {
	used: bool,
	id: u32,
	number: u32,
	generation: u64,
	frames: [KGP_MAX_FRAMES]Frame,
	frame_count: int,
	current_frame: int,
	animation_state: Animation_State,
	animation_loops: u32,
	animation_loop_count: u32,
}

Placement :: struct {
	used: bool,
	image_id: u32,
	image_number: u32,
	placement_id: u32,
	row, col: int,
	cell_x, cell_y: u32,
	cols, rows: u16,
	z: i32,
	src_x, src_y, src_w, src_h: u32,
	parent_id, parent_pl: u32,
	rel_h, rel_v: i32,
	unicode_ph: u8,
}

Pending_Upload :: struct {
	valid:         bool,
	image_id:      u32,
	generation:    u64,
	width, height: int,
	data:          []u8,
	allocator:     runtime.Allocator,
	synced_gen:    u64,
}

Store :: struct {
	images: [KGP_MAX_IMAGES]Image_Slot,
	image_count: int,
	placements: [KGP_MAX_PLACEMENTS]Placement,
	placement_count: int,
	next_number: u32,
	epoch: u64,
	placement_epoch: u64,
	uploads: [KGP_UPLOAD_QUEUE_CAP]Pending_Upload,
	upload_count: int,
	assembly: Assembly,
}

Feed_Context :: struct {
	cursor_row, cursor_col, grid_rows, grid_cols: int,
	allocator: runtime.Allocator,
}

_store_bump_epoch :: proc(s: ^Store) -> u64 {
	s.epoch += 1
	if s.epoch == 0 {
		s.epoch = 1
	}
	return s.epoch
}

_store_bump_placement_epoch :: proc(s: ^Store) {
	s.placement_epoch += 1
	if s.placement_epoch == 0 {
		s.placement_epoch = 1
	}
}

_store_reset_assembly :: proc(s: ^Store, allocator: runtime.Allocator) {
	if s == nil do return
	previous_allocator := context.allocator
	context.allocator = allocator
	assembly_reset(&s.assembly)
	context.allocator = previous_allocator
}

_store_release_frame :: proc(frame: ^Frame, allocator: runtime.Allocator) {
	if frame == nil do return
	if frame.data != nil {
		delete(frame.data, frame.allocator)
	}
	_ = allocator
	frame^ = Frame{}
}

_store_release_image :: proc(image: ^Image_Slot, allocator: runtime.Allocator) {
	if image == nil do return
	for i := 0; i < image.frame_count; i += 1 {
		_store_release_frame(&image.frames[i], allocator)
	}
	image^ = Image_Slot{}
}

_store_release_upload :: proc(upload: ^Pending_Upload, allocator: runtime.Allocator) {
	if upload == nil do return
	if upload.data != nil {
		delete(upload.data, upload.allocator)
	}
	_ = allocator
	upload^ = Pending_Upload{}
}

_store_release_all_uploads :: proc(s: ^Store, allocator: runtime.Allocator) {
	for i := 0; i < s.upload_count; i += 1 {
		_store_release_upload(&s.uploads[i], allocator)
	}
	for i := s.upload_count; i < KGP_UPLOAD_QUEUE_CAP; i += 1 {
		s.uploads[i] = Pending_Upload{}
	}
	s.upload_count = 0
}

_store_image_has_placement :: proc(s: ^Store, image_id, image_number: u32) -> bool {
	if s == nil do return false
	for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
		p := &s.placements[i]
		if !p.used do continue
		if p.image_id == image_id && p.image_number == image_number {
			return true
		}
	}
	return false
}

_store_remove_uploads_for_image :: proc(s: ^Store, image_id: u32, allocator: runtime.Allocator) {
	if s == nil do return
	write_index := 0
	for i := 0; i < s.upload_count; i += 1 {
		upload := &s.uploads[i]
		if upload.image_id == image_id {
			_store_release_upload(upload, allocator)
			continue
		}
		if write_index != i {
			s.uploads[write_index] = s.uploads[i]
			s.uploads[i] = Pending_Upload{}
		}
		write_index += 1
	}
	for i := write_index; i < s.upload_count; i += 1 {
		s.uploads[i] = Pending_Upload{}
	}
	s.upload_count = write_index
}

_store_free_image_index :: proc(s: ^Store, index: int, allocator: runtime.Allocator) {
	if s == nil || index < 0 || index >= KGP_MAX_IMAGES do return
	image := &s.images[index]
	if !image.used do return
	image_id := image.id
	_store_release_image(image, allocator)
	_store_remove_uploads_for_image(s, image_id, allocator)
	if s.image_count > 0 {
		s.image_count -= 1
	}
}

store_init :: proc(s: ^Store) {
	if s == nil do return
	s^ = Store{}
	s.next_number = 1
}

store_destroy :: proc(s: ^Store, allocator: runtime.Allocator) {
	if s == nil do return
	for i := 0; i < KGP_MAX_IMAGES; i += 1 {
		_store_release_image(&s.images[i], allocator)
	}
	_store_release_all_uploads(s, allocator)
	_store_reset_assembly(s, allocator)
	s^ = Store{}
}

_store_clone_bytes :: proc(src: []u8, allocator: runtime.Allocator) -> (result: []u8, ok: bool) {
	if len(src) == 0 {
		return nil, true
	}
	allocated, alloc_err := make([]u8, len(src), allocator)
	if alloc_err != nil {
		return nil, false
	}
	result = allocated
	copy(result, src)
	return result, true
}

// store_sync publishes a deep snapshot of src into the existing dst object.
// Every copied byte buffer is allocated with allocator and records that
// allocator on the destination object; source-owned buffers are never shared.
store_sync :: proc(dst: ^Store, src: ^Store, allocator: runtime.Allocator) {
	if dst == nil || src == nil || dst == src do return

	replacement := new(Store, allocator)
	if replacement == nil do return
	replacement.image_count = src.image_count
	replacement.placement_count = src.placement_count
	replacement.next_number = src.next_number
	replacement.epoch = src.epoch
	replacement.placement_epoch = src.placement_epoch
	replacement.placements = src.placements

	for i := 0; i < KGP_MAX_IMAGES; i += 1 {
		source_image := &src.images[i]
		destination_image := &replacement.images[i]
		destination_image^ = source_image^
		frame_count := clamp(source_image.frame_count, 0, KGP_MAX_FRAMES)
		destination_image.frame_count = frame_count
		for frame_index := 0; frame_index < KGP_MAX_FRAMES; frame_index += 1 {
			source_frame := &source_image.frames[frame_index]
			destination_frame := &destination_image.frames[frame_index]
			destination_frame.data = nil
			destination_frame.allocator = allocator
			if frame_index >= frame_count || len(source_frame.data) == 0 {
				continue
			}
			cloned, ok := _store_clone_bytes(source_frame.data, allocator)
			if !ok {
				store_destroy(replacement, allocator)
				free(replacement, allocator)
				return
			}
			destination_frame.data = cloned
		}
	}

	replacement.upload_count = clamp(src.upload_count, 0, KGP_UPLOAD_QUEUE_CAP)
	for upload_index := 0; upload_index < KGP_UPLOAD_QUEUE_CAP; upload_index += 1 {
		source_upload := &src.uploads[upload_index]
		destination_upload := &replacement.uploads[upload_index]
		destination_upload^ = source_upload^
		destination_upload.data = nil
		destination_upload.allocator = allocator
		if upload_index >= replacement.upload_count || len(source_upload.data) == 0 {
			continue
		}
		cloned, ok := _store_clone_bytes(source_upload.data, allocator)
		if !ok {
			store_destroy(replacement, allocator)
			free(replacement, allocator)
			return
		}
		destination_upload.data = cloned
	}

	// The front store is never a KGP input owner, so an in-progress source
	// assembly is intentionally not carried across the publication boundary.
	// This also avoids exposing a continuation buffer to the renderer.
	replacement.assembly = Assembly{}

	store_destroy(dst, allocator)
	dst^ = replacement^
	free(replacement, allocator)
}

store_clear :: proc(s: ^Store, allocator: runtime.Allocator) {
	if s == nil do return
	new_epoch := s.epoch + 1
	if new_epoch == 0 {
		new_epoch = 1
	}
	new_placement_epoch := s.placement_epoch + 1
	if new_placement_epoch == 0 {
		new_placement_epoch = 1
	}
	for i := 0; i < KGP_MAX_IMAGES; i += 1 {
		_store_release_image(&s.images[i], allocator)
	}
	_store_release_all_uploads(s, allocator)
	_store_reset_assembly(s, allocator)
	for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
		s.placements[i] = Placement{}
	}
	s.image_count = 0
	s.placement_count = 0
	s.upload_count = 0
	s.next_number = 1
	s.epoch = new_epoch
	s.placement_epoch = new_placement_epoch
}

store_clear_placements :: proc(s: ^Store) {
	if s == nil do return
	for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
		s.placements[i] = Placement{}
	}
	s.placement_count = 0
	_store_bump_placement_epoch(s)
}

store_scroll :: proc(s: ^Store, delta: int) {
	if s == nil do return
	changed := false
	for i := KGP_MAX_PLACEMENTS - 1; i >= 0; i -= 1 {
		p := &s.placements[i]
		if !p.used do continue
		p.row -= delta
		changed = true
		if p.row < -KGP_STORE_VISIBLE_ROW_LIMIT || p.row > KGP_STORE_VISIBLE_ROW_LIMIT {
			p^ = Placement{}
			if s.placement_count > 0 {
				s.placement_count -= 1
			}
		}
	}
	if changed {
		_store_bump_placement_epoch(s)
	}
}

_store_find_newest_by_number :: proc(s: ^Store, number: u32) -> ^Image_Slot {
	if s == nil || number == 0 do return nil
	best: ^Image_Slot = nil
	best_generation: u64 = 0
	for i := 0; i < KGP_MAX_IMAGES; i += 1 {
		image := &s.images[i]
		if !image.used || image.number != number do continue
		if best == nil || image.generation >= best_generation {
			best = image
			best_generation = image.generation
		}
	}
	return best
}

store_find_image :: proc(s: ^Store, id, number: u32) -> ^Image_Slot {
	if s == nil do return nil
	if id != 0 {
		for i := 0; i < KGP_MAX_IMAGES; i += 1 {
			image := &s.images[i]
			if image.used && image.id == id {
				return image
			}
		}
		return nil
	}
	return _store_find_newest_by_number(s, number)
}

store_find_placement :: proc(s: ^Store, image_id, image_number, placement_id: u32) -> ^Placement {
	if s == nil || placement_id == 0 do return nil
	for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
		p := &s.placements[i]
		if p.used && p.placement_id == placement_id &&
			(image_id == 0 || p.image_id == image_id) &&
			(image_number == 0 || p.image_number == image_number) {
			return p
		}
	}
	return nil
}

_store_has_key :: proc(control: []u8, wanted: u8) -> bool {
	start := 0
	for start < len(control) {
		end := start
		for end < len(control) && control[end] != ',' {
			end += 1
		}
		equal := start
		for equal < end && control[equal] != '=' {
			equal += 1
		}
		if equal == start + 1 && control[start] == wanted {
			return true
		}
		start = end + 1
	}
	return false
}

_store_next_number :: proc(s: ^Store) -> u32 {
	candidate := s.next_number
	if candidate == 0 {
		candidate = 1
	}
	for attempts := 0; attempts < KGP_MAX_IMAGES + 1; attempts += 1 {
		in_use := false
		for i := 0; i < KGP_MAX_IMAGES; i += 1 {
			if s.images[i].used && s.images[i].number == candidate {
				in_use = true
				break
			}
		}
		if !in_use {
			next := candidate + 1
			if next == 0 {
				next = 1
			}
			s.next_number = next
			return candidate
		}
		candidate += 1
		if candidate == 0 {
			candidate = 1
		}
	}
	return 0
}

_store_id_in_use :: proc(s: ^Store, id: u32) -> bool {
	if id == 0 do return true
	for i := 0; i < KGP_MAX_IMAGES; i += 1 {
		if s.images[i].used && s.images[i].id == id {
			return true
		}
	}
	return false
}

_store_allocate_id :: proc(s: ^Store) -> u32 {
	for candidate: u32 = 1; candidate != 0; candidate += 1 {
		if !_store_id_in_use(s, candidate) {
			return candidate
		}
	}
	return 0
}

_store_encode_base64 :: proc(src: []u8, allocator: runtime.Allocator) -> (result: []u8, ok: bool) {
	if len(src) > (max(int) - 2) / 4 * 3 {
		return nil, false
	}
	output_len := ((len(src) + 2) / 3) * 4
	output, alloc_err := make([]u8, output_len, allocator)
	if alloc_err != nil {
		return nil, false
	}
	result = output
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	out := 0
	for i := 0; i < len(src); i += 3 {
		remaining := len(src) - i
		b0 := src[i]
		b1: u8 = 0
		b2: u8 = 0
		if remaining > 1 {
			b1 = src[i+1]
		}
		if remaining > 2 {
			b2 = src[i+2]
		}
		result[out] = alphabet[b0 >> 2]
		result[out+1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]
		if remaining > 1 {
			result[out+2] = alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)]
		} else {
			result[out+2] = '='
		}
		if remaining > 2 {
			result[out+3] = alphabet[b2 & 0x3f]
		} else {
			result[out+3] = '='
		}
		out += 4
	}
	return result, true
}

_store_decompress :: proc(payload: []u8, expected_size: int, allocator: runtime.Allocator) -> (data: []u8, ok: bool) {
	buffer: bytes.Buffer
	previous_allocator := context.allocator
	context.allocator = allocator
	zlib_err := zlib.inflate_from_byte_array(payload, &buffer, expected_output_size = expected_size)
	inflated := bytes.buffer_to_bytes(&buffer)
	if zlib_err != nil || len(inflated) > KGP_MAX_IMAGE_BYTES {
		bytes.buffer_destroy(&buffer)
		context.allocator = previous_allocator
		return nil, false
	}
	cloned, alloc_err := _store_clone_bytes(inflated, allocator)
	bytes.buffer_destroy(&buffer)
	context.allocator = previous_allocator
	return cloned, alloc_err
}

_store_decode :: proc(c: ^Control, payload: []u8, allocator: runtime.Allocator) -> (image: Decoded_Image, res: Feed_Result) {
	if c == nil do return {}, .Invalid
	w := 0
	h := 0
	if u64(c.src_w) > u64(max(int)) || u64(c.src_h) > u64(max(int)) {
		return {}, .Invalid
	}
	w = int(c.src_w)
	h = int(c.src_h)
	source := payload
	owned_source: []u8 = nil
	switch c.medium {
	case .Direct:
	case .File, .Temp_File:
		path_b64, path_ok := _store_encode_base64(payload, allocator)
		if !path_ok {
			return {}, .No_Space
		}
		defer delete(path_b64, allocator)
		file_payload, file_res := read_file_medium(path_b64, c.file_offset, c.file_size, c.medium == .Temp_File, allocator)
		if file_res != .Ok {
			return {}, file_res
		}
		owned_source = file_payload
		source = owned_source
	case .Shared_Memory:
		shm_payload, shm_res := read_shared_memory(payload, c.file_offset, c.file_size, allocator)
		if shm_res != .Ok {
			return {}, shm_res
		}
		owned_source = shm_payload
		source = owned_source
	case:
		return {}, .Unsupported
	}
	defer if owned_source != nil { delete(owned_source, allocator) }

	if c.compression != 0 {
		if c.compression != 'z' {
			return {}, .Unsupported
		}
		expected_size := -1
		if c.format != .PNG {
			_, rgba_size, size_ok := _decode_rgba_size(w, h)
			if !size_ok {
				return {}, .Invalid
			}
			expected_size = rgba_size / DECODE_RGBA_CHANNELS * DECODE_RGB_CHANNELS
			if c.format == .RGBA32 {
				expected_size = rgba_size
			}
		}
		decompressed, decompress_ok := _store_decompress(source, expected_size, allocator)
		if !decompress_ok {
			return {}, .Invalid
		}
		defer delete(decompressed, allocator)
		source = decompressed
	}
	return decode_image(c.format, source, w, h, allocator)
}

_store_enqueue_upload :: proc(s: ^Store, image_id: u32, generation: u64, width, height: int, data: []u8, allocator: runtime.Allocator) -> Feed_Result {
	if s.upload_count >= KGP_UPLOAD_QUEUE_CAP {
		return .No_Space
	}
	copy_data, alloc_err := make([]u8, len(data), allocator)
	if alloc_err != nil {
		return .No_Space
	}
	copy(copy_data, data)
	s.uploads[s.upload_count] = Pending_Upload{
		valid = true,
		image_id = image_id,
		generation = generation,
		width = width,
		height = height,
		data = copy_data,
		allocator = allocator,
		synced_gen = 0,
	}
	s.upload_count += 1
	return .Ok
}

_store_find_free_image_index :: proc(s: ^Store) -> int {
	for i := 0; i < KGP_MAX_IMAGES; i += 1 {
		if !s.images[i].used {
			return i
		}
	}
	return -1
}

_store_install_image :: proc(s: ^Store, c: ^Control, decoded: ^Decoded_Image, has_id, has_number: bool, allocator: runtime.Allocator) -> (id: u32, image: ^Image_Slot, res: Feed_Result) {
	if s == nil || c == nil || decoded == nil || decoded.data == nil {
		return 0, nil, .Invalid
	}
	if len(decoded.data) > KGP_MAX_IMAGE_BYTES {
		return 0, nil, .No_Space
	}
	if s.upload_count >= KGP_UPLOAD_QUEUE_CAP {
		return 0, nil, .No_Space
	}
	if has_id && c.id == 0 {
		return 0, nil, .Invalid
	}
	if has_number && c.number == 0 {
		return 0, nil, .Invalid
	}

	image_index := -1
	if has_id {
		for i := 0; i < KGP_MAX_IMAGES; i += 1 {
			if s.images[i].used && s.images[i].id == c.id {
				image_index = i
				break
			}
		}
		if image_index < 0 {
			image_index = _store_find_free_image_index(s)
			if image_index < 0 {
				return 0, nil, .No_Space
			}
		}
	} else {
		image_index = _store_find_free_image_index(s)
		if image_index < 0 {
			return 0, nil, .No_Space
		}
	}

	new_id := c.id
	if !has_id {
		new_id = _store_allocate_id(s)
		if new_id == 0 {
			return 0, nil, .No_Space
		}
	}
	old := &s.images[image_index]
	new_number := u32(0)
	if old.used && !has_number {
		new_number = old.number
	} else if has_number {
		new_number = c.number
		for i := 0; i < KGP_MAX_IMAGES; i += 1 {
			if i != image_index && s.images[i].used && s.images[i].number == new_number {
				return 0, nil, .Invalid
			}
		}
	} else {
		new_number = _store_next_number(s)
		if new_number == 0 {
			return 0, nil, .No_Space
		}
	}

	generation := s.epoch + 1
	if generation == 0 {
		generation = 1
	}
	upload_res := _store_enqueue_upload(s, new_id, generation, decoded.width, decoded.height, decoded.data, allocator)
	if upload_res != .Ok {
		return 0, nil, upload_res
	}
	s.epoch = generation
	if old.used {
		_store_release_image(old, allocator)
	} else {
		s.image_count += 1
	}
	old^ = Image_Slot{
		used = true,
		id = new_id,
		number = new_number,
		generation = generation,
		frame_count = 1,
		current_frame = 0,
		animation_state = .Stopped,
	}
	old.frames[0] = Frame{width = decoded.width, height = decoded.height, data = decoded.data, allocator = allocator}
	return new_id, old, .Ok
}

_store_next_placement_id :: proc(s: ^Store) -> u32 {
	for candidate: u32 = 1; candidate != 0; candidate += 1 {
		used := false
		for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
			if s.placements[i].used && s.placements[i].placement_id == candidate {
				used = true
				break
			}
		}
		if !used {
			return candidate
		}
	}
	return 0
}

_store_can_place :: proc(s: ^Store, c: ^Control) -> bool {
	if s == nil || c == nil do return false
	if c.placement_id != 0 {
		for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
			if s.placements[i].used && s.placements[i].placement_id == c.placement_id {
				return true
			}
		}
	}
	return s.placement_count < KGP_MAX_PLACEMENTS
}

_store_place :: proc(s: ^Store, c: ^Control, ctx: Feed_Context, image: ^Image_Slot) -> Feed_Result {
	if s == nil || c == nil || image == nil || !image.used do return .Invalid
	placement: ^Placement = nil
	if c.placement_id != 0 {
		placement = store_find_placement(s, 0, 0, c.placement_id)
	}
	if placement == nil {
		for i := 0; i < KGP_MAX_PLACEMENTS; i += 1 {
			if !s.placements[i].used {
				placement = &s.placements[i]
				break
			}
		}
	}
	if placement == nil {
		return .No_Space
	}
	if !placement.used {
		s.placement_count += 1
	}
	placement_id := c.placement_id
	if placement_id == 0 {
		placement_id = _store_next_placement_id(s)
		if placement_id == 0 {
			if s.placement_count > 0 {
				s.placement_count -= 1
			}
			return .No_Space
		}
	}
	src_w := c.src_rect_w
	src_h := c.src_rect_h
	if src_w == 0 {
		src_w = u32(image.frames[image.current_frame].width)
	}
	if src_h == 0 {
		src_h = u32(image.frames[image.current_frame].height)
	}
	placement^ = Placement{
		used = true,
		image_id = image.id,
		image_number = image.number,
		placement_id = placement_id,
		row = ctx.cursor_row,
		col = ctx.cursor_col,
		cell_x = c.cell_x,
		cell_y = c.cell_y,
		cols = c.cols,
		rows = c.rows,
		z = c.z,
		src_x = c.src_x,
		src_y = c.src_y,
		src_w = src_w,
		src_h = src_h,
		parent_id = c.parent_id,
		parent_pl = c.parent_pl,
		rel_h = c.rel_h,
		rel_v = c.rel_v,
		unicode_ph = c.unicode_ph,
	}
	_store_bump_placement_epoch(s)
	return .Ok
}

_store_frame_index :: proc(image: ^Image_Slot, frame_num: u32, append_allowed: bool) -> (index: int, ok: bool) {
	if image == nil || !image.used do return 0, false
	if frame_num == 0 {
		if !append_allowed || image.frame_count >= KGP_MAX_FRAMES {
			return 0, false
		}
		return image.frame_count, true
	}
	if frame_num > u32(KGP_MAX_FRAMES) {
		return 0, false
	}
	index = int(frame_num - 1)
	if index >= image.frame_count {
		return 0, false
	}
	return index, true
}

_store_pixel_blend :: proc(dst, src: []u8, replacement: bool) {
	if replacement {
		copy(dst[:DECODE_RGBA_CHANNELS], src[:DECODE_RGBA_CHANNELS])
		return
	}
	sa := u64(src[3])
	da := u64(dst[3])
	alpha_sum := sa * 255 + da * (255 - sa)
	if alpha_sum == 0 {
		dst[0] = 0
		dst[1] = 0
		dst[2] = 0
		dst[3] = 0
		return
	}
	for channel in 0..<3 {
		numerator := u64(src[channel]) * sa * 255 + u64(dst[channel]) * da * (255 - sa)
		dst[channel] = u8((numerator + alpha_sum/2) / alpha_sum)
	}
	dst[3] = u8((alpha_sum + 127) / 255)
}

_store_add_frame :: proc(s: ^Store, c: ^Control, image: ^Image_Slot, decoded: ^Decoded_Image, allocator: runtime.Allocator) -> Feed_Result {
	if s == nil || c == nil || image == nil || decoded == nil || !image.used || decoded.data == nil do return .Invalid
	if image.frame_count <= 0 || image.frame_count > KGP_MAX_FRAMES do return .Invalid
	if s.upload_count >= KGP_UPLOAD_QUEUE_CAP || len(decoded.data) > KGP_MAX_IMAGE_BYTES {
		return .No_Space
	}
	root := &image.frames[0]
	if root.width <= 0 || root.height <= 0 || len(root.data) != root.width*root.height*DECODE_RGBA_CHANNELS {
		return .Invalid
	}
	frame_index, frame_ok := _store_frame_index(image, c.frame_edit, c.frame_edit == 0)
	if !frame_ok {
		if c.frame_edit == 0 {
			return .No_Space
		}
		return .Invalid
	}
	if c.compose_mode > 1 {
		return .Invalid
	}

	payload_end_x := u64(c.src_x) + u64(decoded.width)
	payload_end_y := u64(c.src_y) + u64(decoded.height)
	if payload_end_x < u64(c.src_x) || payload_end_y < u64(c.src_y) ||
		payload_end_x > u64(root.width) || payload_end_y > u64(root.height) {
		return .Invalid
	}
	if c.frame_edit == 0 && c.frame_background > u32(image.frame_count) {
		return .Invalid
	}

	canvas_size := root.width * root.height * DECODE_RGBA_CHANNELS
	if c.frame_edit != 0 && len(image.frames[frame_index].data) != canvas_size {
		return .Invalid
	}
	canvas, alloc_err := make([]u8, canvas_size, allocator)
	if alloc_err != nil {
		return .No_Space
	}
	if c.frame_edit != 0 {
		copy(canvas, image.frames[frame_index].data)
	} else if c.frame_background != 0 {
		background := &image.frames[int(c.frame_background-1)]
		if len(background.data) != canvas_size {
			delete(canvas, allocator)
			return .Invalid
		}
		copy(canvas, background.data)
	} else if c.background_color_set {
		color := c.background_color
		for i := 0; i < root.width*root.height; i += 1 {
			pixel := canvas[i*DECODE_RGBA_CHANNELS:]
			pixel[0] = u8(color >> 24)
			pixel[1] = u8(color >> 16)
			pixel[2] = u8(color >> 8)
			pixel[3] = u8(color)
		}
	}

	for row := 0; row < decoded.height; row += 1 {
		for col := 0; col < decoded.width; col += 1 {
			src := decoded.data[(row*decoded.width+col)*DECODE_RGBA_CHANNELS:]
			dst := canvas[((int(c.src_y)+row)*root.width+int(c.src_x)+col)*DECODE_RGBA_CHANNELS:]
			_store_pixel_blend(dst, src, c.compose_mode == 1)
		}
	}
	delete(decoded.data, allocator)
	decoded.data = nil

	generation := s.epoch + 1
	if generation == 0 {
		generation = 1
	}
	upload_res := _store_enqueue_upload(s, image.id, generation, root.width, root.height, canvas, allocator)
	if upload_res != .Ok {
		delete(canvas, allocator)
		return upload_res
	}
	gap: i32 = KGP_DEFAULT_FRAME_GAP_MS
	if frame_index == 0 {
		gap = 0
	} else if c.frame_edit != 0 {
		gap = image.frames[frame_index].gap_ms
	}
	if c.frame_gap_set && c.frame_gap != 0 {
		gap = c.frame_gap
	}
	if frame_index < image.frame_count {
		_store_release_frame(&image.frames[frame_index], allocator)
	} else {
		image.frame_count += 1
	}
	image.frames[frame_index] = Frame{width = root.width, height = root.height, data = canvas, gap_ms = gap, allocator = allocator}
	image.generation = generation
	s.epoch = generation
	return .Ok
}

_store_compose_frames :: proc(s: ^Store, c: ^Control, image: ^Image_Slot, allocator: runtime.Allocator) -> Feed_Result {
	if s == nil || c == nil || image == nil || !image.used do return .Invalid
	if c.compose_source == 0 || c.compose_destination == 0 ||
		c.compose_source > u32(image.frame_count) || c.compose_destination > u32(image.frame_count) {
		return .NotFound
	}
	if c.compose_mode > 1 {
		return .Invalid
	}
	source := &image.frames[int(c.compose_source-1)]
	destination := &image.frames[int(c.compose_destination-1)]
	if source.width <= 0 || source.height <= 0 || destination.width <= 0 || destination.height <= 0 {
		return .Invalid
	}
	width := c.src_rect_w
	height := c.src_rect_h
	if width == 0 { width = u32(source.width) }
	if height == 0 { height = u32(source.height) }
	source_end_x := u64(c.src_x) + u64(width)
	source_end_y := u64(c.src_y) + u64(height)
	destination_end_x := u64(c.cell_x) + u64(width)
	destination_end_y := u64(c.cell_y) + u64(height)
	if source_end_x < u64(c.src_x) || source_end_y < u64(c.src_y) ||
		destination_end_x < u64(c.cell_x) || destination_end_y < u64(c.cell_y) ||
		source_end_x > u64(source.width) || source_end_y > u64(source.height) ||
		destination_end_x > u64(destination.width) || destination_end_y > u64(destination.height) {
		return .Invalid
	}
	if source == destination {
		overlap := u64(c.src_x) < destination_end_x && u64(c.cell_x) < source_end_x &&
			u64(c.src_y) < destination_end_y && u64(c.cell_y) < source_end_y
		if overlap {
			return .Invalid
		}
	}
	if len(source.data) != source.width*source.height*DECODE_RGBA_CHANNELS ||
		len(destination.data) != destination.width*destination.height*DECODE_RGBA_CHANNELS {
		return .Invalid
	}
	if s.upload_count >= KGP_UPLOAD_QUEUE_CAP {
		return .No_Space
	}
	destination_width := destination.width
	destination_height := destination.height
	copy_data, copy_ok := _store_clone_bytes(destination.data, allocator)
	if !copy_ok {
		return .No_Space
	}
	for row := 0; row < int(height); row += 1 {
		for col := 0; col < int(width); col += 1 {
			src := source.data[((int(c.src_y)+row)*source.width+int(c.src_x)+col)*DECODE_RGBA_CHANNELS:]
			dst := copy_data[((int(c.cell_y)+row)*destination.width+int(c.cell_x)+col)*DECODE_RGBA_CHANNELS:]
			_store_pixel_blend(dst, src, c.compose_mode == 1)
		}
	}
	generation := s.epoch + 1
	if generation == 0 { generation = 1 }
	upload_res := _store_enqueue_upload(s, image.id, generation, destination.width, destination.height, copy_data, allocator)
	if upload_res != .Ok {
		delete(copy_data, allocator)
		return upload_res
	}
	_store_release_frame(destination, allocator)
	destination^ = Frame{width = destination_width, height = destination_height, data = copy_data, allocator = allocator}
	image.generation = generation
	s.epoch = generation
	return .Ok
}

_store_animate :: proc(s: ^Store, c: ^Control, image: ^Image_Slot) -> Feed_Result {
	if s == nil || c == nil || image == nil || !image.used do return .Invalid
	if c.animation_state != 0 &&
		(c.animation_state < u32(Animation_State.Stopped) || c.animation_state > u32(Animation_State.Running)) {
		return .Invalid
	}
	if c.animate_current != 0 && c.animate_current > u32(image.frame_count) {
		return .Invalid
	}
	if c.animate_frame != 0 {
		if c.animate_frame > u32(image.frame_count) || !c.frame_gap_set || c.frame_gap == 0 {
			return .Invalid
		}
	} else if c.frame_gap_set {
		return .Invalid
	}
	if c.animation_state == 0 && c.animate_current == 0 && c.animation_loops == 0 && c.animate_frame == 0 {
		return .Invalid
	}

	if c.animation_state != 0 {
		image.animation_state = Animation_State(c.animation_state)
		if image.animation_state == .Stopped {
			image.animation_loop_count = 0
		}
	}
	if c.animate_current != 0 {
		image.current_frame = int(c.animate_current - 1)
	}
	if c.animation_loops != 0 {
		image.animation_loops = c.animation_loops
		image.animation_loop_count = 0
	}
	if c.animate_frame != 0 {
		image.frames[int(c.animate_frame-1)].gap_ms = c.frame_gap
	}
	_store_bump_epoch(s)
	return .Ok
}

_store_delete_matches :: proc(s: ^Store, c: ^Control, ctx: Feed_Context, allocator: runtime.Allocator) -> Feed_Result {
	if s == nil || c == nil do return .Invalid
	mode := c.delete_mode
	if mode == 0 {
		return .Invalid
	}
	uppercase := mode >= 'A' && mode <= 'Z'
	marked: [KGP_MAX_IMAGES]bool
	for i := KGP_MAX_PLACEMENTS - 1; i >= 0; i -= 1 {
		p := &s.placements[i]
		if !p.used do continue
		matches := false
		switch mode {
		case 'a', 'A':
			matches = true
		case 'i', 'I':
			target := c.delete_id
			if target == 0 {
				target = c.id
			}
			matches = target != 0 && p.image_id == target
		case 'n', 'N':
			target := c.delete_num
			if target == 0 {
				target = c.number
			}
			matches = target != 0 && p.image_number == target
		case 'c', 'C':
			matches = p.row == ctx.cursor_row && p.col == ctx.cursor_col
		case 'f', 'F':
			target := c.delete_pl
			if target == 0 {
				target = c.placement_id
			}
			matches = target != 0 && p.placement_id == target
		case 'x', 'y':
			target_x := c.delete_x
			target_y := c.delete_y
			if target_x == 0 {
				target_x = c.cell_x
			}
			if target_y == 0 {
				target_y = c.cell_y
			}
			if mode == 'x' {
				matches = p.col == int(target_x)
			} else {
				matches = p.row == int(target_y)
			}
		case 'z', 'Z':
			matches = p.z == c.delete_z || p.z == c.z
		case 'w', 'W':
			row_start := ctx.cursor_row
			col_start := ctx.cursor_col
			row_end := row_start + int(c.rows)
			col_end := col_start + int(c.cols)
			if c.rows == 0 {
				row_end = row_start + 1
			}
			if c.cols == 0 {
				col_end = col_start + 1
			}
			matches = p.row >= row_start && p.row < row_end && p.col >= col_start && p.col < col_end
		case:
			return .Invalid
		}
		if !matches do continue
		for image_index := 0; image_index < KGP_MAX_IMAGES; image_index += 1 {
			image := &s.images[image_index]
			if image.used && image.id == p.image_id && image.number == p.image_number {
				marked[image_index] = true
				break
			}
		}
		p^ = Placement{}
		if s.placement_count > 0 {
			s.placement_count -= 1
		}
	}
	if mode == 'I' || mode == 'N' {
		target_id := c.delete_id
		target_number := c.delete_num
		if mode == 'I' && target_id == 0 {
			target_id = c.id
		}
		if mode == 'N' && target_number == 0 {
			target_number = c.number
		}
		for i := 0; i < KGP_MAX_IMAGES; i += 1 {
			image := &s.images[i]
			if image.used && ((mode == 'I' && target_id != 0 && image.id == target_id) ||
				(mode == 'N' && target_number != 0 && image.number == target_number)) {
				marked[i] = true
			}
		}
	}
	_store_bump_placement_epoch(s)
	if uppercase {
		for i := 0; i < KGP_MAX_IMAGES; i += 1 {
			if marked[i] && !_store_image_has_placement(s, s.images[i].id, s.images[i].number) {
				_store_free_image_index(s, i, allocator)
			}
		}
		if mode == 'A' {
			for i := 0; i < KGP_MAX_IMAGES; i += 1 {
				if s.images[i].used {
					_store_free_image_index(s, i, allocator)
				}
			}
		}
	}
	return .Ok
}

_store_response_id :: proc(c: ^Control, result_id: u32) -> u32 {
	if result_id != 0 {
		return result_id
	}
	if c == nil do return 0
	if c.id != 0 {
		return c.id
	}
	return c.delete_id
}

_store_emit_response :: proc(c: ^Control, id: u32, res: Feed_Result, sink: Response_Sink) {
	if sink.write == nil do return
	if c != nil {
		if c.quiet == 2 || (c.quiet == 1 && res == .Ok) {
			return
		}
	}
	buffer: [KGP_STORE_RESPONSE_BUFFER_SIZE]u8
	response := kgp_format_response(buffer[:], id, res)
	if len(response) > 0 {
		sink.write(sink.user_data, response)
	}
}

_store_process :: proc(s: ^Store, ctx: Feed_Context, c: ^Control, payload: []u8, has_id, has_number: bool) -> (result: Feed_Result, result_id: u32) {
	if s == nil || c == nil do return .Invalid, 0
	switch c.action {
	case .Transmit, .Transmit_Put:
		if c.action == .Transmit_Put && !_store_can_place(s, c) {
			return .No_Space, 0
		}
		decoded, decode_res := _store_decode(c, payload, ctx.allocator)
		if decode_res != .Ok {
			return decode_res, c.id
		}
		id, image, install_res := _store_install_image(s, c, &decoded, has_id, has_number, ctx.allocator)
		if install_res != .Ok {
			if decoded.data != nil {
				delete(decoded.data, ctx.allocator)
			}
			return install_res, c.id
		}
		if c.action == .Transmit_Put {
			place_res := _store_place(s, c, ctx, image)
			if place_res != .Ok {
				return place_res, id
			}
		}
		return .Ok, id
	case .Put:
		image := store_find_image(s, c.id, c.number)
		if image == nil {
			return .NotFound, c.id
		}
		return _store_place(s, c, ctx, image), image.id
	case .Query:
		decoded, decode_res := _store_decode(c, payload, ctx.allocator)
		if decoded.data != nil {
			delete(decoded.data, ctx.allocator)
		}
		return decode_res, c.id
	case .Delete:
		return _store_delete_matches(s, c, ctx, ctx.allocator), c.id
	case .Frame:
		image := store_find_image(s, c.id, c.number)
		if image == nil {
			return .NotFound, c.id
		}
		decoded, decode_res := _store_decode(c, payload, ctx.allocator)
		if decode_res != .Ok {
			return decode_res, image.id
		}
		frame_res := _store_add_frame(s, c, image, &decoded, ctx.allocator)
		if frame_res != .Ok {
			if decoded.data != nil {
				delete(decoded.data, ctx.allocator)
			}
			return frame_res, image.id
		}
		return .Ok, image.id
	case .Animate:
		image := store_find_image(s, c.id, c.number)
		if image == nil {
			return .NotFound, c.id
		}
		return _store_animate(s, c, image), image.id
	case .Compose:
		image := store_find_image(s, c.id, c.number)
		if image == nil {
			return .NotFound, c.id
		}
		return _store_compose_frames(s, c, image, ctx.allocator), image.id
	}
	return .Invalid, c.id
}

store_feed :: proc(s: ^Store, ctx: Feed_Context, control: []u8, payload: []u8, sink: Response_Sink) -> Feed_Result {
	if s == nil {
		_store_emit_response(nil, 0, .Invalid, sink)
		return .Invalid
	}
	previous_allocator := context.allocator
	context.allocator = ctx.allocator
	defer context.allocator = previous_allocator

	has_id := _store_has_key(control, 'i')
	has_number := _store_has_key(control, 'I')
	if has_id && has_number {
		_store_emit_response(nil, 0, .Invalid, sink)
		return .Invalid
	}

	complete, assembly_res := assembly_feed(&s.assembly, control, payload)
	if !complete {
		return assembly_res
	}
	if assembly_res != .Ok {
		_store_emit_response(nil, 0, assembly_res, sink)
		return assembly_res
	}

	c := s.assembly.control
	result, result_id := _store_process(s, ctx, &c, s.assembly.buf[:], has_id, has_number)
	_store_reset_assembly(s, ctx.allocator)
	_store_emit_response(&c, _store_response_id(&c, result_id), result, sink)
	return result
}
