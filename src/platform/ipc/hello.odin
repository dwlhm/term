package platform_ipc

// HELLO on every link (spec 7.10): u32 version · u8 role · u64 caps · str
// build, no req. The connecting side sends it first; the other side answers
// with its own. Before 1.0 major and minor must match; from 1.0, major only.

import "core:fmt"

@(private)
_HELLO_MAX :: 256 // payload bound: a build id is a few dozen bytes

@(private)
_Hello :: struct {
	version: Version,
	role:    u8,
	caps:    u64,
	build:   string,
}

@(private)
_version_u32 :: proc(v: Version) -> u32 { return u32(v.major) << 16 | u32(v.minor) << 8 | u32(v.patch) }

@(private)
_version_of :: proc(n: u32) -> Version { return {u8(n >> 16), u8(n >> 8), u8(n)} }

@(private)
_version_match :: proc(a, b: Version) -> bool {
	return a.major == b.major && (a.major != 0 || a.minor == b.minor)
}

// _version_reason: "<proto>: client X.Y.Z, server X.Y.Z".
@(private)
_version_reason :: proc(name: string, client, server: Version) -> string {
	return fmt.tprintf("%s: client %d.%d.%d, server %d.%d.%d", name, client.major, client.minor, client.patch, server.major, server.minor, server.patch)
}

// _hello_body encodes our HELLO; build is the executable's build id.
@(private)
_hello_body :: proc(buf: []u8, v: Version, role: u8) -> []u8 {
	bb: [64]u8
	w := wire_writer(buf)
	ww_u32(&w, _version_u32(v))
	ww_u8(&w, role)
	ww_u64(&w, 0)
	ww_str(&w, _build_id(bb[:]))
	return wire_bytes_written(&w)
}

@(private)
_hello_decode :: proc(payload: []u8) -> (h: _Hello, ok: bool) {
	r := wire_reader(payload)
	h.version = _version_of(wr_u32(&r))
	h.role = wr_u8(&r)
	h.caps = wr_u64(&r)
	h.build = wr_str(&r)
	return h, wr_done(&r)
}
