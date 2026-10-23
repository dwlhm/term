package terminal_extension

// Resource and path guards for the Kitty graphics protocol.
//
// The PTY byte stream is untrusted input: every dimension, size and path that
// arrives through an APC sequence must be validated before it is allowed to
// allocate memory, touch the file system, or reach the GPU backend.

import "base:runtime"
import "core:os"
import "core:strings"

// Protocol-independent storage bounds. A single image may not exceed
// KITTY_MAX_PIXELS, and all images (plus their animation frames) together may
// not exceed KITTY_MAX_TOTAL_PIXEL_BYTES.
KITTY_MAX_DIMENSION        :: 8192
KITTY_MAX_PIXELS           :: 16 * 1024 * 1024
KITTY_MAX_TOTAL_PIXEL_BYTES :: 128 * 1024 * 1024
KITTY_MAX_PAYLOAD_BYTES    :: 64 * 1024 * 1024
KITTY_MAX_FILE_BYTES       :: 64 * 1024 * 1024
KITTY_MAX_ANIM_FRAMES      :: 256

// Kitty_Error_Code is the wire-level error vocabulary of the protocol.
Kitty_Error_Code :: enum {
	None,
	Invalid_Request, // EINVAL
	Out_Of_Space,    // ENOSPC
	Unsupported,     // EUNSUPPORTED
}

kitty_error_name :: proc(code: Kitty_Error_Code) -> string {
	switch code {
	case .Invalid_Request: return "EINVAL"
	case .Out_Of_Space:    return "ENOSPC"
	case .Unsupported:     return "EUNSUPPORTED"
	case .None:            return ""
	}
	return ""
}

// kitty_dims_valid rejects zero, negative, oversized and overflowing image
// geometries before any pixel buffer is allocated for them.
kitty_dims_valid :: proc(w, h: int) -> bool {
	if w <= 0 || h <= 0 do return false
	if w > KITTY_MAX_DIMENSION || h > KITTY_MAX_DIMENSION do return false
	return w * h <= KITTY_MAX_PIXELS
}

// _kitty_temp_dir returns the platform temporary directory without a trailing
// separator. Allocated from the temp allocator: valid for the current scope.
_kitty_temp_dir :: proc() -> string {
	dir, found := os.lookup_env("TMPDIR", context.temp_allocator)
	if !found || len(dir) == 0 do return "/tmp"
	for len(dir) > 1 && dir[len(dir) - 1] == '/' {
		dir = dir[:len(dir) - 1]
	}
	return dir
}

_kitty_path_is_relative :: proc(path: string) -> bool {
	if len(path) == 0 do return true
	if path[0] != '/' do return true
	return strings.contains(path, "/../") || strings.has_suffix(path, "/..")
}

// kitty_path_in_temp_dir reports whether path names a direct child of the
// temporary directory. Kitty only ever hands out doomed files from there, so a
// path outside it must never be deleted on behalf of the guest program.
kitty_path_in_temp_dir :: proc(path: string) -> bool {
	if _kitty_path_is_relative(path) do return false
	base := _kitty_temp_dir()
	if !strings.has_prefix(path, base) do return false
	rest := path[len(base):]
	if len(rest) > 0 && rest[0] == '/' do rest = rest[1:]
	if len(rest) == 0 do return false
	return !strings.contains(rest, "/")
}

// _kitty_path_is_readable_file accepts any absolute regular-file path that the
// guest program is entitled to read. Device nodes, FIFOs, sockets and
// directories are rejected so a hostile stream cannot block or exhaust us.
_kitty_path_is_plain_absolute :: proc(path: string) -> bool {
	if _kitty_path_is_relative(path) do return false
	if strings.contains_rune(path, 0) do return false
	return true
}

// _kitty_bounded_allocator caps a single decode pass (zlib inflate) so a
// compression bomb cannot expand past KITTY_MAX_PAYLOAD_BYTES.
_Kitty_Bounded_Allocator :: struct {
	parent: runtime.Allocator,
	used:   int,
	limit:  int,
}

_kitty_bounded_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, align: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	st := (^_Kitty_Bounded_Allocator)(allocator_data)
	if st == nil do return nil, .Invalid_Argument

	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size < 0 || st.used + size > st.limit do return nil, .Out_Of_Memory
		mem, err := st.parent.procedure(st.parent.data, mode, size, align, old_memory, old_size, loc)
		if err == nil do st.used += len(mem)
		return mem, err
	case .Free:
		if old_memory != nil && old_size > 0 do st.used = max(0, st.used - old_size)
		return st.parent.procedure(st.parent.data, mode, size, align, old_memory, old_size, loc)
	case .Resize, .Resize_Non_Zeroed:
		delta := size - old_size
		if size < 0 || (delta > 0 && st.used + delta > st.limit) do return nil, .Out_Of_Memory
		mem, err := st.parent.procedure(st.parent.data, mode, size, align, old_memory, old_size, loc)
		if err == nil do st.used += delta
		return mem, err
	case .Query_Features, .Query_Info:
		return st.parent.procedure(st.parent.data, mode, size, align, old_memory, old_size, loc)
	}
	return nil, .Mode_Not_Implemented
}

_kitty_make_bounded_allocator :: proc(st: ^_Kitty_Bounded_Allocator, parent: runtime.Allocator, limit: int) -> runtime.Allocator {
	st.parent = parent
	st.used = 0
	st.limit = limit
	return runtime.Allocator{procedure = _kitty_bounded_allocator_proc, data = rawptr(st)}
}

// _kitty_read_regular_file reads a size-capped regular file. Symbolic links to
// regular files are fine, but the opened descriptor must itself be a regular
// file with a known, bounded size.
_kitty_read_regular_file :: proc(path: string, allocator: runtime.Allocator) -> (data: []u8, ok: bool) {
	if !_kitty_path_is_plain_absolute(path) do return nil, false

	file, open_err := os.open(path)
	if open_err != nil do return nil, false
	defer os.close(file)

	info, info_err := os.fstat(file, allocator)
	defer os.file_info_delete(info, allocator)
	if info_err != nil do return nil, false
	if info.type != .Regular do return nil, false
	if info.size <= 0 || info.size > KITTY_MAX_FILE_BYTES do return nil, false

	buf, read_err := os.read_entire_file_from_file(file, allocator)
	if read_err != nil do return nil, false
	if len(buf) == 0 || len(buf) > KITTY_MAX_FILE_BYTES {
		delete(buf, allocator)
		return nil, false
	}
	return buf, true
}
