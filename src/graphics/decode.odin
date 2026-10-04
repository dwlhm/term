package graphics

import "base:runtime"
import "core:bytes"
import "core:image/png"
import "core:mem"
import "core:os"
import "core:c"
import posix "core:sys/posix"

Decoded_Image :: struct {
	width:  int,
	height: int,
	data:   []u8,
}

DECODE_RGB_CHANNELS       :: 3
DECODE_RGBA_CHANNELS      :: 4
DECODE_PNG_DEPTH_8        :: 8
DECODE_PNG_DEPTH_16       :: 16
DECODE_PNG_SIGNATURE_SIZE :: 8
DECODE_PNG_IHDR_SIZE      :: 13
DECODE_PNG_IHDR_TOTAL     :: DECODE_PNG_SIGNATURE_SIZE + 4 + DECODE_PNG_IHDR_SIZE + 4

_decode_checked_product :: proc(a, b: int) -> (value: int, ok: bool) {
	if a < 0 || b < 0 {
		return 0, false
	}
	if a != 0 && b > max(int)/a {
		return 0, false
	}
	return a * b, true
}

_decode_rgba_size :: proc(width, height: int) -> (pixels, bytes: int, ok: bool) {
	if width <= 0 || height <= 0 {
		return 0, 0, false
	}

	pixels, ok = _decode_checked_product(width, height)
	if !ok {
		return 0, 0, false
	}
	bytes, ok = _decode_checked_product(pixels, DECODE_RGBA_CHANNELS)
	return pixels, bytes, ok
}

// decode_raw converts packed RGB24 or RGBA32 pixels to owned RGBA8 pixels.
decode_raw :: proc(payload: []u8, w, h, channels: int, allocator: runtime.Allocator) -> (Decoded_Image, Feed_Result) {
	pixels, output_len, ok := _decode_rgba_size(w, h)
	if !ok {
		return {}, .Invalid
	}

	if channels != DECODE_RGB_CHANNELS && channels != DECODE_RGBA_CHANNELS {
		return {}, .Invalid
	}

	input_len: int
	input_ok: bool
	input_len, input_ok = _decode_checked_product(pixels, channels)
	if !input_ok || len(payload) != input_len {
		return {}, .Invalid
	}

	data, alloc_err := make([]u8, output_len, allocator)
	if alloc_err != nil {
		return {}, .Invalid
	}

	if channels == DECODE_RGBA_CHANNELS {
		copy(data, payload)
		return Decoded_Image{width = w, height = h, data = data}, .Ok
	}

	for i := 0; i < pixels; i += 1 {
		src := payload[i*DECODE_RGB_CHANNELS:]
		dst := data[i*DECODE_RGBA_CHANNELS:]
		dst[0] = src[0]
		dst[1] = src[1]
		dst[2] = src[2]
		dst[3] = 255
	}

	return Decoded_Image{width = w, height = h, data = data}, .Ok
}

_decode_png_u32be :: proc(data: []u8) -> u32 {
	return u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
}

_decode_png_header :: proc(payload: []u8) -> (width, height, depth, channels: int, ok: bool) {
	if len(payload) < DECODE_PNG_IHDR_TOTAL {
		return 0, 0, 0, 0, false
	}

	png_signature := [DECODE_PNG_SIGNATURE_SIZE]u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}
	for i := 0; i < DECODE_PNG_SIGNATURE_SIZE; i += 1 {
		if payload[i] != png_signature[i] {
			return 0, 0, 0, 0, false
		}
	}

	if _decode_png_u32be(payload[0:4]) != 0x89504e47 {
		return 0, 0, 0, 0, false
	}
	if _decode_png_u32be(payload[DECODE_PNG_SIGNATURE_SIZE:]) != DECODE_PNG_IHDR_SIZE {
		return 0, 0, 0, 0, false
	}
	if payload[DECODE_PNG_SIGNATURE_SIZE+4] != 'I' ||
	   payload[DECODE_PNG_SIGNATURE_SIZE+5] != 'H' ||
	   payload[DECODE_PNG_SIGNATURE_SIZE+6] != 'D' ||
	   payload[DECODE_PNG_SIGNATURE_SIZE+7] != 'R' {
		return 0, 0, 0, 0, false
	}

	width_u32 := _decode_png_u32be(payload[16:])
	height_u32 := _decode_png_u32be(payload[20:])
	if width_u32 == 0 || height_u32 == 0 {
		return 0, 0, 0, 0, false
	}
	if u64(width_u32) > u64(max(int)) || u64(height_u32) > u64(max(int)) {
		return 0, 0, 0, 0, false
	}

	depth_u8 := payload[24]
	color_type := payload[25]
	width = int(width_u32)
	height = int(height_u32)
	depth = int(depth_u8)

	switch color_type {
	case 0:
		channels = 1
	case 2:
		channels = DECODE_RGB_CHANNELS
	case 3:
		channels = DECODE_RGB_CHANNELS
	case 4:
		channels = 2
	case 6:
		channels = DECODE_RGBA_CHANNELS
	case:
		return 0, 0, 0, 0, false
	}

	if depth != DECODE_PNG_DEPTH_8 && depth != DECODE_PNG_DEPTH_16 {
		return 0, 0, 0, 0, false
	}
	if color_type == 3 && depth == DECODE_PNG_DEPTH_16 {
		return 0, 0, 0, 0, false
	}

	_, _, ok = _decode_rgba_size(width, height)
	return width, height, depth, channels, ok
}

// decode_png loads a PNG through core:image/png and returns owned RGBA8 pixels.
decode_png :: proc(payload: []u8, allocator: runtime.Allocator) -> (Decoded_Image, Feed_Result) {
	header_width, header_height, _, _, header_ok := _decode_png_header(payload)
	if !header_ok {
		return {}, .Invalid
	}

	img, png_err := png.load_from_bytes(payload, options = {.alpha_add_if_missing}, allocator = allocator)
	if img == nil {
		return {}, .Invalid
	}
	defer png.destroy(img)
	if png_err != nil {
		return {}, .Invalid
	}

	if img.width != header_width || img.height != header_height {
		return {}, .Invalid
	}
	if img.width <= 0 || img.height <= 0 {
		return {}, .Invalid
	}
	if img.channels < 1 || img.channels > DECODE_RGBA_CHANNELS {
		return {}, .Invalid
	}
	if img.depth != DECODE_PNG_DEPTH_8 && img.depth != DECODE_PNG_DEPTH_16 {
		return {}, .Invalid
	}

	pixels, output_len, ok := _decode_rgba_size(img.width, img.height)
	if !ok {
		return {}, .Invalid
	}

	source_len: int
	source_ok: bool
	source_len, source_ok = _decode_checked_product(pixels, img.channels)
	if !source_ok {
		return {}, .Invalid
	}
	if img.depth == DECODE_PNG_DEPTH_16 {
		source_len, source_ok = _decode_checked_product(source_len, 2)
		if !source_ok {
			return {}, .Invalid
		}
	}

	source := bytes.buffer_to_bytes(&img.pixels)
	if len(source) != source_len {
		return {}, .Invalid
	}

	data, alloc_err := make([]u8, output_len, allocator)
	if alloc_err != nil {
		return {}, .Invalid
	}

	if img.depth == DECODE_PNG_DEPTH_8 {
		for i := 0; i < pixels; i += 1 {
			src := source[i*img.channels:]
			dst := data[i*DECODE_RGBA_CHANNELS:]
			switch img.channels {
			case 1:
				dst[0] = src[0]
				dst[1] = src[0]
				dst[2] = src[0]
				dst[3] = 255
			case 2:
				dst[0] = src[0]
				dst[1] = src[0]
				dst[2] = src[0]
				dst[3] = src[1]
			case 3:
				dst[0] = src[0]
				dst[1] = src[1]
				dst[2] = src[2]
				dst[3] = 255
			case 4:
				copy(dst[:DECODE_RGBA_CHANNELS], src[:DECODE_RGBA_CHANNELS])
			}
		}
	} else {
		samples := mem.slice_data_cast([]u16, source)
		for i := 0; i < pixels; i += 1 {
			src := samples[i*img.channels:]
			dst := data[i*DECODE_RGBA_CHANNELS:]
			switch img.channels {
			case 1:
				gray := u8(src[0] >> 8)
				dst[0] = gray
				dst[1] = gray
				dst[2] = gray
				dst[3] = 255
			case 2:
				gray := u8(src[0] >> 8)
				dst[0] = gray
				dst[1] = gray
				dst[2] = gray
				dst[3] = u8(src[1] >> 8)
			case 3:
				dst[0] = u8(src[0] >> 8)
				dst[1] = u8(src[1] >> 8)
				dst[2] = u8(src[2] >> 8)
				dst[3] = 255
			case 4:
				dst[0] = u8(src[0] >> 8)
				dst[1] = u8(src[1] >> 8)
				dst[2] = u8(src[2] >> 8)
				dst[3] = u8(src[3] >> 8)
			}
		}
	}

	return Decoded_Image{width = img.width, height = img.height, data = data}, .Ok
}

// decode_image dispatches KGP image formats and always returns RGBA8.
decode_image :: proc(format: Format, payload: []u8, w, h: int, allocator: runtime.Allocator) -> (Decoded_Image, Feed_Result) {
	switch format {
	case .PNG:
		return decode_png(payload, allocator)
	case .RGB24:
		return decode_raw(payload, w, h, DECODE_RGB_CHANNELS, allocator)
	case .RGBA32:
		return decode_raw(payload, w, h, DECODE_RGBA_CHANNELS, allocator)
	case:
		return {}, .Unsupported
	}
}

KGP_SHM_NAME_MAX :: 255

// read_shared_memory reads an owned range from a POSIX shared-memory object.
// The object is always closed and unlinked after the attempt, as required by
// the KGP shared-memory medium.
read_shared_memory :: proc(name: []u8, offset, size: u32, allocator: runtime.Allocator) -> (data: []u8, res: Feed_Result) {
	if len(name) < 2 || len(name) > KGP_SHM_NAME_MAX || name[0] != '/' {
		return nil, .Invalid
	}
	for c, i in name {
		if c == 0 || (i > 0 && c == '/') {
			return nil, .Invalid
		}
	}

	name_buf: [KGP_SHM_NAME_MAX + 1]u8
	copy(name_buf[:], name)
	name_buf[len(name)] = 0
	shm_name := cstring(&name_buf[0])
	fd: posix.FD
	when ODIN_OS == .Darwin {
		fd = posix.shm_open(shm_name, {})
	} else {
		fd = posix.shm_open(shm_name, {}, 0)
	}
	if fd < 0 {
		return nil, .Invalid
	}

	stat: posix.stat_t
	stat_ok := posix.fstat(fd, &stat) == .OK
	object_size: u64 = 0
	if stat_ok {
		if stat.st_size < 0 {
			stat_ok = false
		} else {
			object_size = u64(stat.st_size)
		}
	}
	end := u64(offset) + u64(size)
	bounds_ok := stat_ok && u64(offset) <= object_size && end >= u64(offset) && end <= object_size
	if !bounds_ok || object_size > u64(max(int)) {
		close_ok := posix.close(fd) == .OK
		unlink_ok := posix.shm_unlink(shm_name) == .OK
		if !close_ok || !unlink_ok {
			return nil, .Invalid
		}
		return nil, .Invalid
	}

	if size == 0 {
		close_ok := posix.close(fd) == .OK
		unlink_ok := posix.shm_unlink(shm_name) == .OK
		if !close_ok || !unlink_ok {
			return nil, .Invalid
		}
		empty, empty_err := make([]u8, 0, allocator)
		if empty_err != nil {
			return nil, .Invalid
		}
		return empty, .Ok
	}

	mapping := posix.mmap(nil, c.size_t(object_size), {.READ}, {.SHARED}, fd, 0)
	if mapping == nil || mapping == posix.MAP_FAILED {
		close_ok := posix.close(fd) == .OK
		unlink_ok := posix.shm_unlink(shm_name) == .OK
		if !close_ok || !unlink_ok {
			return nil, .Invalid
		}
		return nil, .Invalid
	}

	mapped := ([^]u8)(mapping)[:int(object_size)]
	allocated, alloc_err := make([]u8, int(size), allocator)
	copy_ok := alloc_err == nil
	if copy_ok {
		copy(allocated, mapped[int(offset):int(end)])
	}
	data = allocated
	munmap_ok := posix.munmap(mapping, c.size_t(object_size)) == .OK
	close_ok := posix.close(fd) == .OK
	unlink_ok := posix.shm_unlink(shm_name) == .OK
	if !copy_ok || !munmap_ok || !close_ok || !unlink_ok {
		if data != nil {
			delete(data, allocator)
		}
		return nil, .Invalid
	}
	return data, .Ok
}

// read_file_medium decodes a base64 path, reads a bounded file range, and
// removes the path when temporary is true.
read_file_medium :: proc(path_b64: []u8, offset, size: u32, temporary: bool, allocator: runtime.Allocator) -> (data: []u8, res: Feed_Result) {
	path_buf, alloc_err := make([]u8, len(path_b64), allocator)
	if alloc_err != nil {
		return nil, .Invalid
	}

	path_len, path_ok := base64_decode(path_buf, path_b64)
	if !path_ok || path_len == 0 {
		delete(path_buf, allocator)
		return nil, .Invalid
	}
	path_buf = path_buf[:path_len]

	file_data, read_err := os.read_entire_file(string(path_buf), allocator)
	remove_err: os.Error
	if temporary {
		remove_err = os.remove(string(path_buf))
	}
	delete(path_buf, allocator)

	if read_err != nil || remove_err != nil {
		delete(file_data, allocator)
		return nil, .Invalid
	}

	end := u64(offset) + u64(size)
	if end > u64(len(file_data)) {
		delete(file_data, allocator)
		return nil, .Invalid
	}

	if size == 0 {
		delete(file_data, allocator)
		empty, empty_err := make([]u8, 0, allocator)
		if empty_err != nil {
			return nil, .Invalid
		}
		return empty, .Ok
	}

	if offset == 0 && u64(size) == u64(len(file_data)) {
		return file_data, .Ok
	}

	data, alloc_err = make([]u8, int(size), allocator)
	if alloc_err != nil {
		delete(file_data, allocator)
		return nil, .Invalid
	}
	copy(data, file_data[int(offset):int(end)])
	delete(file_data, allocator)
	return data, .Ok
}
