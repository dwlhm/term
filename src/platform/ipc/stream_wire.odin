package platform_ipc

// Little-endian field codec for stream payloads: fixed-size scalars and
// u32-length-prefixed byte strings. No allocation: the writer fills a caller
// buffer, the reader returns views into the payload. Any overrun clears `ok`
// and every later read returns zero values, so decoders check `ok` once.

Wire_Writer :: struct {
	buf: []u8,
	n:   int,
	ok:  bool,
}

Wire_Reader :: struct {
	buf: []u8,
	off: int,
	ok:  bool,
}

wire_writer :: proc(buf: []u8) -> Wire_Writer { return {buf = buf, ok = true} }
wire_reader :: proc(buf: []u8) -> Wire_Reader { return {buf = buf, ok = true} }

wire_bytes_written :: proc(w: ^Wire_Writer) -> []u8 { return w.buf[:w.n] }

@(private = "file")
_room :: proc(w: ^Wire_Writer, k: int) -> []u8 {
	if !w.ok || w.n + k > len(w.buf) {
		w.ok = false
		return nil
	}
	w.n += k
	return w.buf[w.n - k:w.n]
}

ww_u8 :: proc(w: ^Wire_Writer, v: u8) { if d := _room(w, 1); d != nil do d[0] = v }
ww_u16 :: proc(w: ^Wire_Writer, v: u16) { if d := _room(w, 2); d != nil do d[0], d[1] = u8(v), u8(v >> 8) }
ww_u32 :: proc(w: ^Wire_Writer, v: u32) { if d := _room(w, 4); d != nil do _put_u32(d, v) }
ww_i32 :: proc(w: ^Wire_Writer, v: i32) { ww_u32(w, u32(v)) }
ww_u64 :: proc(w: ^Wire_Writer, v: u64) { ww_u32(w, u32(v)); ww_u32(w, u32(v >> 32)) }
ww_bool :: proc(w: ^Wire_Writer, v: bool) { ww_u8(w, 1 if v else 0) }

ww_bytes :: proc(w: ^Wire_Writer, b: []u8) {
	ww_u32(w, u32(len(b)))
	if d := _room(w, len(b)); d != nil do copy(d, b)
}

ww_str :: proc(w: ^Wire_Writer, s: string) { ww_bytes(w, transmute([]u8)s) }

@(private = "file")
_take :: proc(r: ^Wire_Reader, k: int) -> []u8 {
	if !r.ok || k < 0 || r.off + k > len(r.buf) {
		r.ok = false
		return nil
	}
	r.off += k
	return r.buf[r.off - k:r.off]
}

wr_u8 :: proc(r: ^Wire_Reader) -> u8 {
	d := _take(r, 1)
	return d[0] if d != nil else 0
}

wr_u16 :: proc(r: ^Wire_Reader) -> u16 {
	d := _take(r, 2)
	return u16(d[0]) | u16(d[1]) << 8 if d != nil else 0
}

wr_u32 :: proc(r: ^Wire_Reader) -> u32 {
	d := _take(r, 4)
	return _get_u32(d) if d != nil else 0
}

wr_i32 :: proc(r: ^Wire_Reader) -> i32 { return i32(wr_u32(r)) }

wr_u64 :: proc(r: ^Wire_Reader) -> u64 {
	lo := u64(wr_u32(r))
	return lo | u64(wr_u32(r)) << 32
}

wr_bool :: proc(r: ^Wire_Reader) -> bool { return wr_u8(r) != 0 }

// wr_bytes returns a view into the payload (not a copy).
wr_bytes :: proc(r: ^Wire_Reader) -> []u8 {
	n := wr_u32(r)
	if !r.ok || n > u32(len(r.buf) - r.off) {
		r.ok = false
		return nil
	}
	return _take(r, int(n))
}

wr_str :: proc(r: ^Wire_Reader) -> string { return string(wr_bytes(r)) }

// wr_done: every field decoded and no trailing garbage.
wr_done :: proc(r: ^Wire_Reader) -> bool { return r.ok && r.off == len(r.buf) }
