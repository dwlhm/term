package terminal_extension

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:compress/zlib"
import "core:image"
import "core:image/jpeg"
import "core:image/png"
import "core:os"
import "core:strings"
import "core:sys/posix"
import stbi "vendor:stb/image"

// _kitty_decompress_zlib inflates zlib or raw deflate compressed streams into a freshly allocated buffer.
_kitty_decompress_zlib :: proc(data: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(data) == 0 do return nil
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, len(data) * 4, allocator)
	defer bytes.buffer_destroy(&buf)

	err := zlib.inflate(input = data, buf = &buf)
	if err != nil {
		bytes.buffer_reset(&buf)
		err_raw := zlib.inflate(input = data, buf = &buf, raw = true)
		if err_raw != nil do return nil
	}
	res := make([]u8, bytes.buffer_length(&buf), allocator)
	copy(res, bytes.buffer_to_bytes(&buf))
	return res
}

// _convert_rgb_to_rgba converts 24-bit RGB pixel buffer to 32-bit RGBA (alpha = 255).
_convert_rgb_to_rgba :: proc(src: []u8, w, h: int, allocator: runtime.Allocator) -> []u8 {
	total_pixels := w * h
	if total_pixels <= 0 do return nil
	dst := make([]u8, total_pixels * 4, allocator)
	px_count := min(total_pixels, len(src) / 3)
	for i in 0..<px_count {
		dst[i * 4 + 0] = src[i * 3 + 0]
		dst[i * 4 + 1] = src[i * 3 + 1]
		dst[i * 4 + 2] = src[i * 3 + 2]
		dst[i * 4 + 3] = 255
	}
	return dst
}

// _kitty_strip_apple_chunks strips Apple-proprietary chunks (e.g. iDOT, CgBI) from PNG byte streams
// to prevent decoder rejections on macOS screenshots.
_kitty_strip_apple_chunks :: proc(data: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(data) < 8 || string(data[:8]) != "\x89PNG\r\n\x1a\n" do return data
	has_apple := false
	offset := 8
	for offset + 8 <= len(data) {
		len_chunk := int(data[offset])<<24 | int(data[offset+1])<<16 | int(data[offset+2])<<8 | int(data[offset+3])
		if offset + 8 + len_chunk + 4 > len(data) do break
		type_chunk := string(data[offset+4:offset+8])
		if type_chunk == "iDOT" || type_chunk == "CgBI" {
			has_apple = true
			break
		}
		offset += 8 + len_chunk + 4
		if type_chunk == "IEND" do break
	}
	if !has_apple do return data

	filtered := make([dynamic]u8, 0, len(data), allocator)
	append(&filtered, ..data[:8])
	offset = 8
	for offset + 8 <= len(data) {
		len_chunk := int(data[offset])<<24 | int(data[offset+1])<<16 | int(data[offset+2])<<8 | int(data[offset+3])
		total_len := 8 + len_chunk + 4
		if offset + total_len > len(data) do break
		type_chunk := string(data[offset+4:offset+8])
		if type_chunk != "iDOT" && type_chunk != "CgBI" {
			append(&filtered, ..data[offset : offset + total_len])
		}
		offset += total_len
		if type_chunk == "IEND" do break
	}
	return filtered[:]
}

// _kitty_load_png decodes PNG bytes safely handling Apple screenshots.
_kitty_load_png :: proc(data: []u8, allocator: runtime.Allocator) -> (^image.Image, image.Error) {
	clean_data := _kitty_strip_apple_chunks(data, allocator)
	defer if len(clean_data) > 0 && len(clean_data) != len(data) do delete(clean_data, allocator)
	return png.load_from_bytes(clean_data, image.Options{.alpha_add_if_missing}, allocator)
}

// _kitty_load_image_from_bytes decodes PNG, JPEG, or raw RGB/RGBA buffers with auto-detection.
_kitty_load_image_from_bytes :: proc(state: ^Kitty_Extension, data: []u8) -> (pixels: []u8, width, height: int) {
	if state == nil || len(data) == 0 do return nil, 0, 0

	// Check if data is a compressed image format (PNG, JPEG, WebP, BMP, GIF via magic bytes or f=100)
	is_compressed := (state.current_format == 100) ||
		(len(data) >= 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n") ||
		(len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) ||
		(len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP") ||
		(len(data) >= 2 && data[0] == 'B' && data[1] == 'M')

	if is_compressed {
		// Use stb_image to decode all formats, including progressive JPEGs and all PNG variants
		w_c, h_c, comp_c: c.int
		stb_pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w_c, &h_c, &comp_c, 4)
		if stb_pixels != nil {
			defer stbi.image_free(stb_pixels)
			w := int(w_c)
			h := int(h_c)
			total_bytes := w * h * 4
			px := make([]u8, total_bytes, state.allocator)
			copy(px, ([^]u8)(stb_pixels)[:total_bytes])
			return px, w, h
		}

		// Fallback to core:image/png if stb_image failed on apple png chunks
		img, err := _kitty_load_png(data, state.allocator)
		if err == nil && img != nil {
			px := make([]u8, len(img.pixels.buf), state.allocator)
			copy(px, img.pixels.buf[:])
			w, h := img.width, img.height
			image.destroy(img, state.allocator)
			return px, w, h
		}
		return nil, 0, 0
	}

	w := state.current_width
	h := state.current_height
	if state.current_format == 24 {
		return _convert_rgb_to_rgba(data, w, h, state.allocator), w, h
	}

	dst := make([]u8, w * h * 4 if (w > 0 && h > 0) else len(data), state.allocator)
	copy(dst, data[:min(len(dst), len(data))])
	return dst, w, h
}

// _kitty_load_file reads an image from disk (regular file 'f' or temp file 't' auto-deleted).
_kitty_load_file :: proc(state: ^Kitty_Extension, file_path: string, is_temp: bool) -> (pixels: []u8, width, height: int) {
	if state == nil || len(file_path) == 0 do return nil, 0, 0
	defer if is_temp do os.remove(file_path)

	data, err := os.read_entire_file(file_path, state.allocator)
	if err != nil || len(data) == 0 do return nil, 0, 0
	defer delete(data, state.allocator)

	return _kitty_load_image_from_bytes(state, data)
}

// _kitty_load_shm maps a POSIX shared memory object, reads pixel data, and unlinks it.
_kitty_load_shm :: proc(state: ^Kitty_Extension, shm_name: string) -> (pixels: []u8, width: int, height: int) {
	if state == nil || len(shm_name) == 0 do return nil, 0, 0

	c_name := strings.clone_to_cstring(shm_name, context.temp_allocator)
	fd := posix.shm_open(c_name, posix.O_Flags{}, 0)
	if fd < 0 do return nil, 0, 0
	defer {
		posix.close(fd)
		posix.shm_unlink(c_name)
	}

	w := state.current_width
	h := state.current_height
	bytes_per_px := 4 if state.current_format == 32 else 3
	expected_bytes := state.current_shm_size if state.current_shm_size > 0 else (w * h * bytes_per_px)
	if expected_bytes <= 0 do return nil, 0, 0

	ptr := posix.mmap(nil, uint(expected_bytes), posix.Prot_Flags{.READ}, posix.Map_Flags{.SHARED}, fd, 0)
	if uintptr(ptr) == ~uintptr(0) do return nil, 0, 0
	defer posix.munmap(ptr, uint(expected_bytes))

	src := ([^]u8)(ptr)[:expected_bytes]
	return _kitty_load_image_from_bytes(state, src)
}

// _kitty_parse_ctrl_params extracts control key-value pairs from a Kitty graphics control string.
_kitty_parse_ctrl_params :: proc(state: ^Kitty_Extension, ctrl_str: string) -> (action: u8, more: u8) {
	if state == nil do return 'T', 0

	is_chunk_continuation := state.in_chunk_transmission || len(state.chunk_buf) > 0
	if !is_chunk_continuation {
		state.current_action = 'T'
		state.current_id = 0
	}
	action = state.current_action
	more = 0

	it := ctrl_str
	for len(it) > 0 {
		part: string
		comma_idx := strings.index_byte(it, ',')
		if comma_idx >= 0 {
			part = it[:comma_idx]
			it = it[comma_idx + 1:]
		} else {
			part = it
			it = ""
		}
		eq_idx := strings.index_byte(part, '=')
		if eq_idx < 1 do continue
		k := part[0]
		v := part[eq_idx + 1:]
		switch k {
		case 'a':
			if len(v) > 0 {
				action = v[0]
				state.current_action = v[0]
			}
		case 'm': if len(v) > 0 do more = v[0] - '0'
		case 'o': if len(v) > 0 do state.current_compression = v[0]
		case 't': if len(v) > 0 do state.current_medium = v[0]
		case 'd': if len(v) > 0 do state.current_delete = v[0]
		case 'C': state.current_cursor_move = _parse_int_val(v)
		case 'U': state.current_virtual = _parse_int_val(v)
		case 'i': state.current_id = u32(_parse_int_val(v))
		case 'p': state.current_placement = u32(_parse_int_val(v))
		case 'q': state.current_quiet = _parse_int_val(v)
		case 'f': state.current_format = _parse_int_val(v)
		case 's':
			if state.current_action == 'a' do state.current_anim_state = _parse_int_val(v)
			else do state.current_width = _parse_int_val(v)
		case 'v':
			if state.current_action == 'a' do state.current_anim_loops = _parse_int_val(v)
			else do state.current_height = _parse_int_val(v)
		case 'c':
			if state.current_action == 'f' do state.current_composition = u8(_parse_int_val(v))
			else if state.current_action == 'a' do state.current_frame_num = _parse_int_val(v)
			else do state.current_cols = _parse_int_val(v)
		case 'r':
			if state.current_action == 'f' do state.current_frame_num = _parse_int_val(v)
			else do state.current_rows = _parse_int_val(v)
		case 'x': state.current_src_x = _parse_int_val(v)
		case 'y': state.current_src_y = _parse_int_val(v)
		case 'w': state.current_src_w = _parse_int_val(v)
		case 'h': state.current_src_h = _parse_int_val(v)
		case 'z':
			val := _parse_int_val(v)
			state.current_z = val
			state.current_gap = val
		case 'X': state.current_offset_x = _parse_int_val(v)
		case 'Y': state.current_offset_y = _parse_int_val(v)
		case 'S': state.current_shm_size = _parse_int_val(v)
		}
	}
	return action, more
}

_kitty_decode_payload :: proc(state: ^Kitty_Extension, decoded: []u8) -> (px: []u8, w, h: int) {
	payload := decoded
	decomp: []u8 = nil
	if state.current_compression == 'z' {
		decomp = _kitty_decompress_zlib(decoded, state.allocator)
		if len(decomp) == 0 do return nil, 0, 0
		payload = decomp
	}
	defer if decomp != nil do delete(decomp, state.allocator)

	switch state.current_medium {
	case 's': return _kitty_load_shm(state, string(payload))
	case 'f': return _kitty_load_file(state, string(payload), false)
	case 't': return _kitty_load_file(state, string(payload), true)
	case:     return _kitty_load_image_from_bytes(state, payload)
	}
}

