package feature_holder_tests

// Test fixture: holder_run in a thread on a unique socket, plus a minimal
// core client over ipc.Stream_Conn that logs every frame in arrival order.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import holder ".."
import proto "../../session_proto"
import ipc "../../../platform/ipc"

Fixture :: struct {
	dir:      string,
	dir_buf:  [64]u8,
	path:     string,
	path_buf: [80]u8,
	th:       ^thread.Thread,
	code:     int,
	finished: bool, // atomic
}

Rec :: struct {
	kind:    u8,
	channel: u32,
	data:    []u8,
}

Client :: struct {
	conn:   ipc.Stream_Conn,
	log:    [dynamic]Rec,
	closed: bool,
	bytes:  int, // OUTPUT bytes received
	by_ch:  [8]int, // OUTPUT bytes per channel (< 8)
	max_f:  int, // largest OUTPUT payload
	keep:   bool, // false: OUTPUT is counted, not logged
}

@(private = "file")
_fixture_seq: int

fixture_start :: proc() -> ^Fixture {
	os.set_env("TERM_HOLDER_NO_CORE", "1")
	os.set_env("TERM_HOLDER_GRACE_MS", "1500")
	f := new(Fixture)
	_fixture_seq += 1
	// The socket's dir must be private to us (0700, not a symlink): /tmp is
	// neither, so each holder gets its own dir under its real path.
	real: [256]u8
	base := string(posix.realpath("/tmp", raw_data(real[:])))
	f.dir = fmt.bprintf(f.dir_buf[:], "%s/th-%d-%d", base, posix.getpid(), _fixture_seq)
	posix.mkdir(fmt.ctprintf("%s", f.dir), posix.S_IRWXU)
	f.path = fmt.bprintf(f.path_buf[:], "%s/h.sock", f.dir)
	f.th = thread.create_and_start_with_poly_data(f, proc(f: ^Fixture) {
		f.code = holder.holder_run(f.path)
		sync.atomic_store(&f.finished, true)
	})
	for _ in 0..<200 {
		if ipc.ipc_probe(f.path) == .None do break
		time.sleep(5 * time.Millisecond)
	}
	return f
}

fixture_running :: proc(f: ^Fixture) -> bool { return !sync.atomic_load(&f.finished) }

// fixture_stop shuts the holder down (if still running) and joins it.
fixture_stop :: proc(f: ^Fixture) -> int {
	if fixture_running(f) {
		if c := client_connect(f.path); c != nil {
			client_goodbye(c, .Shutdown)
			client_wait_kind(c, proto.MSG_BYE, 0, 6000)
			client_close(c)
		}
	}
	thread.join(f.th)
	thread.destroy(f.th)
	code := f.code
	posix.rmdir(fmt.ctprintf("%s", f.dir)) // the holder unlinked its socket
	free(f)
	return code
}

client_connect :: proc(path: string) -> ^Client {
	fd := posix.socket(.UNIX, .STREAM)
	addr: posix.sockaddr_un
	ipc.ipc_fill_sockaddr(path, &addr)
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return nil
	}
	c := new(Client)
	c.keep = true
	ipc.stream_conn_init(&c.conn, fd, 2 << 20)
	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_hello(&w, {version = proto.STREAM_PROTO_VERSION, role = .Core, build = "test"})
	client_send(c, proto.MSG_HELLO, 0, ipc.wire_bytes_written(&w))
	return c
}

client_close :: proc(c: ^Client) {
	for r in c.log do delete(r.data)
	delete(c.log)
	ipc.stream_conn_destroy(&c.conn)
	free(c)
}

client_send :: proc(c: ^Client, kind: u8, channel: u32, payload: []u8 = nil) {
	ipc.stream_send(&c.conn, kind, channel, payload)
	for _ in 0..<1000 {
		if ipc.stream_flush(&c.conn) != .None || !ipc.stream_wants_write(&c.conn) do return
		time.sleep(time.Millisecond)
	}
}

// client_pump waits up to timeout_ms for input and logs every frame.
client_pump :: proc(c: ^Client, timeout_ms: int) {
	if c.closed do return
	pfd := posix.pollfd{fd = c.conn.fd, events = {.IN}}
	if posix.poll(&pfd, 1, i32(timeout_ms)) <= 0 do return
	err := ipc.stream_fill(&c.conn)
	for {
		f, ok := ipc.stream_next(&c.conn)
		if !ok do break
		if f.kind == proto.MSG_OUTPUT {
			c.bytes += len(f.payload)
			if f.channel < len(c.by_ch) do c.by_ch[f.channel] += len(f.payload)
			c.max_f = max(c.max_f, len(f.payload))
		}
		if f.kind == proto.MSG_OUTPUT && !c.keep do continue
		append(&c.log, Rec{f.kind, f.channel, clone(f.payload)})
	}
	if err != .None || c.conn.err != .None do c.closed = true
}

@(private = "file")
clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

client_find :: proc(c: ^Client, kind: u8, channel: u32) -> int {
	for r, i in c.log do if r.kind == kind && r.channel == channel do return i
	return -1
}

// client_wait_kind pumps until a frame of kind/channel arrives; its log index or -1.
client_wait_kind :: proc(c: ^Client, kind: u8, channel: u32, timeout_ms: int) -> int {
	deadline := time.tick_now()._nsec + i64(timeout_ms) * 1_000_000
	for {
		if i := client_find(c, kind, channel); i >= 0 do return i
		left := (deadline - time.tick_now()._nsec) / 1_000_000
		if left <= 0 || c.closed do return -1
		client_pump(c, int(min(left, 50)))
	}
}

// client_output concatenates the OUTPUT of channel logged before index `before`.
client_output :: proc(c: ^Client, channel: u32, before := max(int)) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	for r, i in c.log {
		if i >= before do break
		if r.kind == proto.MSG_OUTPUT && r.channel == channel do append(&out, ..r.data)
	}
	return string(out[:])
}

client_wait_output :: proc(c: ^Client, channel: u32, want: string, timeout_ms: int) -> bool {
	deadline := time.tick_now()._nsec + i64(timeout_ms) * 1_000_000
	for time.tick_now()._nsec < deadline && !c.closed {
		if contains(client_output(c, channel), want) do return true
		client_pump(c, 50)
	}
	return contains(client_output(c, channel), want)
}

contains :: proc(s, sub: string) -> bool {
	for i := 0; i + len(sub) <= len(s); i += 1 do if s[i:i + len(sub)] == sub do return true
	return false
}

client_spawn :: proc(c: ^Client, id: u32, argv: []string, cols: u16 = 80, rows: u16 = 24) {
	m: proto.Spawn_Msg
	for a, i in argv do m.argv[i] = a
	m.argc = len(argv)
	m.cols, m.rows = cols, rows
	buf: [4096]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_spawn(&w, &m)
	client_send(c, proto.MSG_SPAWN, id, ipc.wire_bytes_written(&w))
}

client_signal :: proc(c: ^Client, id: u32, sig: posix.Signal) {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_i32(&w, i32(sig))
	client_send(c, proto.MSG_SIGNAL, id, b[:])
}

client_goodbye :: proc(c: ^Client, g: proto.Goodbye) {
	b := [1]u8{u8(g)}
	client_send(c, proto.MSG_GOODBYE, 0, b[:])
}

rec_u32 :: proc(r: Rec) -> u32 {
	rd := ipc.wire_reader(r.data)
	return ipc.wr_u32(&rd)
}
