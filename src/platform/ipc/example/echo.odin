package ipc_example

// Echo over the IPC package, with nothing from term: a Server on a Poll_Set
// in a thread of its own answers ECHO with the text it got, and a Client in
// main calls it. Exit 0 = the answer came back intact. It is the proof that
// the package stands alone (spec 7.1) and the shortest complete use of it.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import ipc "../"

ROLE_CLIENT :: u8(1)
ECHO        :: u8(20) // str text → ECHO_BACK
ECHO_BACK   :: u8(21) // str text

catalog := [?]ipc.Msg_Spec{{request = ECHO, answer = ECHO_BACK}}

protocol :: proc() -> ipc.Protocol {
	return {name = "ipc echo", version = {0, 1, 0}, roles = {int(ROLE_CLIENT)}, catalog = catalog[:]}
}

Echo_Server :: struct {
	set:      ipc.Poll_Set,
	srv:      ipc.Server,
	stopping: bool, // atomic
}

decode_text :: proc(r: ^ipc.Wire_Reader) -> string { return ipc.wr_str(r) }

serve :: proc(s: ^Echo_Server) {
	for !sync.atomic_load(&s.stopping) {
		ipc.poll_set_wait(&s.set, -1)
		for ev in ipc.server_next(&s.srv) {
			req, ok := ev.(ipc.Request)
			if !ok do continue
			text: string
			if !ipc.request_decode(&req, &text, decode_text) do continue // FAIL Bad_Request is sent
			buf: [512]u8
			w := ipc.wire_writer(buf[:])
			ipc.ww_str(&w, text)
			ipc.reply(&s.srv, req, ipc.wire_bytes_written(&w))
		}
	}
}

call :: proc(at: ipc.Endpoint, text: string) -> (got: string, err: ipc.Error) {
	c: ipc.Client
	if err = ipc.client_open(&c, at, protocol(), {role = ROLE_CLIENT}); err.kind != .None do return
	defer ipc.client_close(&c)
	buf: [512]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_str(&w, text)
	a: ipc.Answer
	if a, err = ipc.client_call(&c, ECHO, ipc.wire_bytes_written(&w)); err.kind != .None do return
	r := ipc.wire_reader(a.body)
	got = ipc.wr_str(&r)
	if !ipc.wr_done(&r) do err = {kind = .Bad_Reply}
	return
}

// run serves and calls once; Error is a struct, so every step checks kind.
run :: proc() -> (err: ipc.Error) {
	dir_buf: [256]u8
	dir: string
	if dir, err = ipc.private_dir(dir_buf[:], "ipc-echo"); err.kind != .None do return
	at := ipc.Endpoint{dir, fmt.tprintf("echo-%d.sock", os.get_pid())}
	s: Echo_Server
	if err = ipc.poll_set_init(&s.set, 16); err.kind != .None do return
	defer ipc.poll_set_destroy(&s.set)
	if err = ipc.server_open(&s.srv, at, protocol(), &s.set); err.kind != .None do return
	defer ipc.server_close(&s.srv)
	th := thread.create_and_start_with_poly_data(&s, serve)
	defer {
		sync.atomic_store(&s.stopping, true)
		ipc.poll_set_poke(&s.set)
		thread.join(th)
		thread.destroy(th)
	}
	got: string
	if got, err = call(at, "hello"); err.kind != .None do return
	if got != "hello" do return {kind = .Bad_Reply, reason = got}
	fmt.println("echo:", got)
	return
}

main :: proc() {
	if err := run(); err.kind != .None {
		fmt.eprintln("ipc echo:", ipc.error_message(err), err.reason)
		os.exit(1)
	}
}
