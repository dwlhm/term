package feature_session_core_tests

// MSG_ACT against a program that prints the bytes it receives: keys, text and
// mouse are encoded for the modes it asked for, and refused when it asked for
// none.

import "core:encoding/hex"
import "core:strings"
import "core:testing"
import "core:time"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// ECHO_FIXTURE: raw mode, prints argv[1] (escapes decoded: the modes to ask
// for), then one "IN:<hex>" line per read.
ECHO_FIXTURE :: `import os, sys, tty
tty.setraw(0)
os.write(1, sys.argv[1].encode().decode("unicode_escape").encode("latin1") + b"READY\r\n")
while True:
    d = os.read(0, 4096)
    if not d:
        break
    os.write(1, ("IN:" + d.hex() + "\r\n").encode())
`

// echo_open starts ECHO_FIXTURE asking for modes and waits for it.
echo_open :: proc(v: ^View, modes: string) -> u32 {
	id := view_attached(v, view_spawn(v, {"/usr/bin/env", "python3", "-I", "-c", ECHO_FIXTURE, modes}))
	_snap_until_text(id, "READY")
	return id
}

@(private = "file")
_snap_until_text :: proc(id: u32, want: string) -> bool {
	for _ in 0 ..< 300 {
		if strings.contains(_screen(id), want) do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}

@(private = "file")
_screen :: proc(id: u32) -> string {
	snap, _, ok := cli_snapshot(id)
	if !ok do return ""
	b := strings.builder_make(context.temp_allocator)
	for row in snap.screen {
		for run in row.runs do strings.write_string(&b, run.text)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// echo_received waits for the program to report want (raw bytes) as one read.
echo_received :: proc(id: u32, want: string) -> bool {
	return _snap_until_text(id, strings.concatenate({"IN:", string(hex.encode(transmute([]u8)want, context.temp_allocator)), "\n"}, context.temp_allocator))
}

cli_act :: proc(payload: proc(w: ^ipc.Wire_Writer, id: u32, data: rawptr), id: u32, data: rawptr) -> (gen: u64, code: proto.Fail_Code, ok: bool) {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return
	defer ipc.stream_conn_destroy(&conn)
	buf: [4096]u8
	w := ipc.wire_writer(buf[:])
	payload(&w, id, data)
	ipc.stream_send(&conn, proto.MSG_ACT, 0, ipc.wire_bytes_written(&w))
	for {
		f := client.client_wait_frame(&conn, 4000) or_return
		r := ipc.wire_reader(f.payload)
		switch f.kind {
		case proto.MSG_ACT_RESULT:
			_ = ipc.wr_u32(&r)
			return ipc.wr_u64(&r), {}, true
		case proto.MSG_FAIL:
			_ = ipc.wr_u32(&r)
			return 0, proto.Fail_Code(ipc.wr_u8(&r)), false
		}
	}
}

@(private = "file")
_keys :: proc(id: u32, keys: ..proto.Act_Key) -> (proto.Fail_Code, bool) {
	k := keys
	_, code, ok := cli_act(proc(w: ^ipc.Wire_Writer, id: u32, data: rawptr) {
		proto.enc_act_keys(w, id, (^[]proto.Act_Key)(data)^)
	}, id, &k)
	return code, ok
}

@(private = "file")
_text :: proc(id: u32, text: string, paste := false) -> (proto.Fail_Code, bool) {
	T :: struct { text: string, paste: bool }
	t := T{text, paste}
	_, code, ok := cli_act(proc(w: ^ipc.Wire_Writer, id: u32, data: rawptr) {
		t := (^T)(data)
		proto.enc_act_text(w, id, t.text, t.paste)
	}, id, &t)
	return code, ok
}

@(private = "file")
_mouse :: proc(id: u32, m: proto.Act_Mouse) -> (proto.Fail_Code, bool) {
	mm := m
	_, code, ok := cli_act(proc(w: ^ipc.Wire_Writer, id: u32, data: rawptr) {
		proto.enc_act_mouse(w, id, (^proto.Act_Mouse)(data)^)
	}, id, &mm)
	return code, ok
}

// Key values of core/terminal/input_encode.Key.
K_CHAR  :: u8(1)
K_ENTER :: u8(2)
K_UP    :: u8(12)
K_F5    :: u8(20)
CTRL    :: u8(4)
SHIFT   :: u8(1)
SUPER   :: u8(8)

@(test)
test_act_keys_follow_the_program_modes :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	plain := echo_open(v, "")
	app := echo_open(v, "\\x1b[?1h")
	kitty := echo_open(v, "\\x1b[>10u") // all keys as escape codes + event types
	defer { view_close(v); tiers_stop(tiers) }

	_, ok := _keys(plain, {key = K_UP}, {key = K_CHAR, char = 'c', mods = CTRL})
	testing.expect(t, ok)
	testing.expect(t, echo_received(plain, "\x1b[A\x03"), "legacy arrow and ^C in one write")
	_, ok = _keys(plain, {key = K_CHAR, char = 'q', mods = SHIFT}, {key = K_F5}, {key = K_ENTER})
	testing.expect(t, ok && echo_received(plain, "Q\x1b[15~\r"), "a plain character goes in as text")
	_, ok = _keys(app, {key = K_UP})
	testing.expect(t, ok && echo_received(app, "\x1bOA"), "DECCKM arrows")
	_, ok = _keys(kitty, {key = K_CHAR, char = 'a'})
	testing.expect(t, ok && echo_received(kitty, "\x1b[97;1:1u\x1b[97;1:3u"), "a tap is press + release under Kitty event types")

	code, refused := _keys(plain, {key = K_CHAR, char = 'c', mods = SUPER})
	testing.expect(t, !refused && code == .Unsupported, "Super+c has no encoding")
	code, refused = _keys(plain, {key = 200})
	testing.expect(t, !refused && code == .Bad_Request, "unknown key")
	code, refused = _keys(plain, {key = K_CHAR, char = 0x1b})
	testing.expect(t, !refused && code == .Bad_Request, "a control character is not a key")
	code, refused = _keys(plain)
	testing.expect(t, !refused && code == .Bad_Request, "no keys")
}

@(test)
test_act_text_pastes_or_types :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	typed := echo_open(v, "")
	pasted := echo_open(v, "\\x1b[?2004h")
	kitty := echo_open(v, "\\x1b[>10u")
	defer { view_close(v); tiers_stop(tiers) }

	_, ok := _text(typed, "hi\nyo\r\nend")
	testing.expect(t, ok && echo_received(typed, "hi\ryo\rend"), "newlines are Enter")
	_, ok = _text(typed, "ab", paste = true)
	testing.expect(t, ok && echo_received(typed, "ab"), "a paste without ?2004 is typed")
	_, ok = _text(pasted, "a\x1b[201~b\n", paste = true)
	testing.expect(t, ok && echo_received(pasted, "\x1b[200~ab\r\x1b[201~"), "one paste; an embedded end marker is dropped")
	_, ok = _text(pasted, ":wq\n")
	testing.expect(t, ok && echo_received(pasted, ":wq\r"), "typed text is keys even where pastes are bracketed")
	_, ok = _text(kitty, "aB")
	testing.expect(t, ok && echo_received(kitty, "\x1b[97;1:1u\x1b[97;1:3u\x1b[98;2:1u\x1b[98;2:3u"), "typed under Kitty: key events, uppercase = Shift")
	code, refused := _text(typed, "")
	testing.expect(t, !refused && code == .Bad_Request)
}

@(test)
test_act_mouse_only_when_reported :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	none := echo_open(v, "")
	sgr := echo_open(v, "\\x1b[?1000h\\x1b[?1006h")
	defer { view_close(v); tiers_stop(tiers) }

	code, refused := _mouse(none, {kind = 0, button = 0, col = 3, row = 4})
	testing.expect(t, !refused && code == .Unsupported, "a program without mouse reports refuses clicks")
	_, ok := _mouse(sgr, {kind = 0, button = 0, col = 3, row = 4})
	testing.expect(t, ok && echo_received(sgr, "\x1b[<0;3;4M"), "SGR press")
	code, refused = _mouse(sgr, {kind = 2, button = 0, col = 3, row = 4})
	testing.expect(t, !refused && code == .Unsupported, "?1000 reports no drags")
	code, refused = _mouse(sgr, {kind = 0, col = 81, row = 1})
	testing.expect(t, !refused && code == .Bad_Request, "outside the screen")
}

@(test)
test_act_reports_the_generation_and_refuses_ended_targets :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	id := echo_open(v, "")
	gone := view_attached(v, view_sh(v, "exit 0"))
	defer { view_close(v); tiers_stop(tiers) }

	before, _, _ := cli_snapshot(id)
	k := []proto.Act_Key{{key = K_ENTER}}
	gen, _, ok := cli_act(proc(w: ^ipc.Wire_Writer, id: u32, data: rawptr) {
		proto.enc_act_keys(w, id, (^[]proto.Act_Key)(data)^)
	}, id, &k)
	testing.expect(t, ok && gen == before.gen, "the generation the input went in at")
	res, _, settled := cli_settle({id = id, since = gen, quiet_ms = 30, timeout_ms = 3000})
	testing.expect(t, settled && res.gen > gen, "the program's answer moves it")

	cli_settle({id = gone, since = max(u64), quiet_ms = 1, timeout_ms = 3000})
	code, refused := _keys(gone, {key = K_ENTER})
	testing.expect(t, !refused && code == .Exited, "an exited session takes no input")
	code, refused = _keys(999_999, {key = K_ENTER})
	testing.expect(t, !refused && code == .Not_Found)
}
