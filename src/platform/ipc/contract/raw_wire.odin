package platform_ipc_contract

// The wire of spec 7.10 for fake peers: [kind u8][channel u32 LE][len u32 LE]
// [payload]; request/reply frames on channel 0 start with u32 req (notices
// use req 0); HELLO = u32 version · u8 role · u64 caps · str build, with no
// req; FAIL = u32 req · u8 code · str reason. The connecting side sends HELLO
// first and the server answers HELLO; a refused peer gets HELLO, FAIL (req 0)
// and a close.

import "core:sys/posix"
import ipc "../"

HELLO_KIND :: u8(3) // Protocol.hello_kind default
FAIL_KIND  :: u8(4) // Protocol.fail_kind default
FRAME_HEAD :: 9

Raw_Frame :: struct {
	kind:    u8,
	channel: u32,
	body:    []u8, // view into the caller's buffer
}

Raw_Fail :: struct {
	req:    u32,
	code:   u8,
	reason: string,
}

version_u32 :: proc(v: ipc.Version) -> u32 { return u32(v.major) << 16 | u32(v.minor) << 8 | u32(v.patch) }

// raw_send writes one frame whose payload is parts back to back.
raw_send :: proc(fd: posix.FD, kind: u8, channel: u32, parts: ..[]u8) -> bool {
	n := 0
	for p in parts do n += len(p)
	head: [FRAME_HEAD]u8
	if !raw_write(fd, frame_head(head[:], kind, channel, n)) do return false
	for p in parts do if !raw_write(fd, p) do return false
	return true
}

// frame_head lays out a frame header for a payload of n bytes.
frame_head :: proc(buf: []u8, kind: u8, channel: u32, n: int) -> []u8 {
	w := ipc.wire_writer(buf)
	ipc.ww_u8(&w, kind)
	ipc.ww_u32(&w, channel)
	ipc.ww_u32(&w, u32(n))
	return ipc.wire_bytes_written(&w)
}

// frame_bytes lays out one whole frame in buf.
frame_bytes :: proc(buf: []u8, kind: u8, channel: u32, body: []u8) -> []u8 {
	head := len(frame_head(buf, kind, channel, len(body)))
	return buf[:head + copy(buf[head:], body)]
}

// raw_request sends a channel 0 request: u32 req, then body.
raw_request :: proc(fd: posix.FD, req: u32, kind: u8, body: ..[]u8) -> bool {
	r := u32le_bytes(req)
	parts: [8][]u8
	parts[0] = r[:]
	for b, i in body do parts[i + 1] = b
	return raw_send(fd, kind, 0, ..parts[:len(body) + 1])
}

// raw_frame reads one frame into buf within timeout_ms.
raw_frame :: proc(fd: posix.FD, buf: []u8, timeout_ms: int) -> (f: Raw_Frame, ok: bool) {
	head: [FRAME_HEAD]u8
	if !raw_read(fd, head[:], timeout_ms) do return
	r := ipc.wire_reader(head[:])
	f.kind = ipc.wr_u8(&r)
	f.channel = ipc.wr_u32(&r)
	n := int(ipc.wr_u32(&r))
	if n > len(buf) || !raw_read(fd, buf[:n], timeout_ms) do return
	f.body = buf[:n]
	return f, true
}

// raw_req: the u32 req that starts a channel 0 frame body.
raw_req :: proc(f: Raw_Frame) -> u32 {
	r := ipc.wire_reader(f.body)
	return ipc.wr_u32(&r)
}

raw_fail :: proc(f: Raw_Frame) -> (m: Raw_Fail, ok: bool) {
	if f.kind != FAIL_KIND || f.channel != 0 do return
	r := ipc.wire_reader(f.body)
	m.req = ipc.wr_u32(&r)
	m.code = ipc.wr_u8(&r)
	m.reason = ipc.wr_str(&r)
	return m, ipc.wr_done(&r)
}

hello_body :: proc(buf: []u8, v: ipc.Version, role: u8) -> []u8 {
	w := ipc.wire_writer(buf)
	ipc.ww_u32(&w, version_u32(v))
	ipc.ww_u8(&w, role)
	ipc.ww_u64(&w, 0)
	ipc.ww_str(&w, "contract")
	return ipc.wire_bytes_written(&w)
}

// raw_hello sends our HELLO and takes the server's; false when it refused
// (a FAIL within settle_ms; 0 = do not wait for one).
raw_hello :: proc(fd: posix.FD, v := TEST_VERSION, role := TEST_ROLE_CLIENT, settle_ms := 50) -> bool {
	hb: [64]u8
	if !raw_send(fd, HELLO_KIND, 0, hello_body(hb[:], v, role)) do return false
	buf: [256]u8
	f, ok := raw_frame(fd, buf[:], 2000)
	if !ok || f.kind != HELLO_KIND do return false
	return settle_ms == 0 || !raw_wait(fd, settle_ms) || _no_fail_follows(fd)
}

// A refusal is HELLO then FAIL; anything else after HELLO is a live link.
@(private = "file")
_no_fail_follows :: proc(fd: posix.FD) -> bool {
	head: [1]u8
	n := posix.recv(fd, raw_data(head[:]), 1, {.PEEK})
	return n == 1 && head[0] != FAIL_KIND
}

u32le_bytes :: proc(v: u32) -> (b: [4]u8) {
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, v)
	return
}
