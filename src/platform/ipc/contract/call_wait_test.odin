package platform_ipc_contract

// P13–P15: what may end or interleave with a waiting client_call. P13 and
// P15 use a fake server so the server side cannot help.

import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import ipc "../"

@(test)
test_P13_on_event_stop_interrupts_the_call :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	fs := Fake_Server{answer = proc(fd: posix.FD, f: Raw_Frame) {
		zero := u32le_bytes(0)
		raw_send(fd, TEST_CHANGED, 0, zero[:], transmute([]u8)string("n")) // a notice, never the answer
	}}
	if !fake_open(t, &fs, {dir, "s"}) do return
	defer fake_close(&fs)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	stop :: proc(data: rawptr, ev: ipc.Client_Event) -> ipc.Event_Action {
		_, is_notice := ev.(ipc.Notice)
		return .Stop if is_notice else .Continue
	}
	b := u32le_bytes(1)
	start := time.tick_now()
	_, err := ipc.client_call(&c, TEST_PING, b[:], {timeout = ipc.WAIT_FOREVER, on_event = stop})
	expect_kind(t, err, .Interrupted, "PING")
	testing.expectf(t, ms_since(start) < 1000, "Stop took %.0f ms", ms_since(start))
}

@(private = "file")
_target: ^ipc.Client

@(private = "file")
_signalled_at: i64 // atomic

@(private = "file")
_on_signal :: proc "c" (sig: posix.Signal) { ipc.client_interrupt(_target) }

// _kick raises SIGUSR2 on the waiting thread after 100 ms.
@(private = "file")
_kick :: proc(waiter: posix.pthread_t) {
	time.sleep(100 * time.Millisecond)
	sync.atomic_store(&_signalled_at, now_ns())
	posix.pthread_kill(waiter, .SIGUSR2)
}

@(test)
test_P13_interrupt_from_a_signal_handler :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	fs: Fake_Server // never answers
	if !fake_open(t, &fs, {dir, "s"}) do return
	defer fake_close(&fs)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	_target = &c
	old := posix.signal(.SIGUSR2, _on_signal)
	defer posix.signal(.SIGUSR2, old)
	kicker := thread.create_and_start_with_poly_data(posix.pthread_self(), _kick, context)
	defer thread.destroy(kicker)
	defer thread.join(kicker)
	b := u32le_bytes(1)
	_, err := ipc.client_call(&c, TEST_PING, b[:], {timeout = 3 * time.Second})
	ms := f64(now_ns() - sync.atomic_load(&_signalled_at)) / 1e6
	expect_kind(t, err, .Interrupted, "PING")
	testing.expectf(t, ms <= 50, ".Interrupted came %.1f ms after the signal", ms)
}

@(private = "file")
_Late :: struct {
	ticket: ipc.Ticket,
	seen:   int,
	right:  bool, // the late answer was the JOB's: its ticket, JOB_DONE, no error
}

@(test)
test_P14_late_answer_while_another_call_waits :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	// The owner holds JOB until PING arrives, then answers JOB first.
	job: ipc.Request
	o := Owner{data = &job, handle = proc(o: ^Owner, ev: ipc.Server_Event) {
		req, ok := ev.(ipc.Request)
		if !ok do return
		held := (^ipc.Request)(o.data)
		if req.kind == TEST_JOB do held^ = req
		if req.kind != TEST_PING do return
		reply_u32(&o.srv, held^, 1)
		reply_u32(&o.srv, req, 9)
	}}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	one := u32le_bytes(1)
	tk, err := ipc.client_start(&c, TEST_JOB, one[:])
	if !expect_ok(t, err, "client_start JOB") do return
	late := _Late{ticket = tk}
	on_event :: proc(data: rawptr, ev: ipc.Client_Event) -> ipc.Event_Action {
		l := (^_Late)(data)
		if e, ok := ev.(ipc.Late_Answer); ok {
			l.seen += 1
			l.right = e.ticket == l.ticket && e.answer.kind == TEST_JOB_DONE && e.err.kind == .None
		}
		return .Continue
	}
	if !ping(t, &c, 9, {on_event = on_event, data = &late}) do return
	testing.expect_value(t, late.seen, 1)
	testing.expect(t, late.right, "the Late_Answer was not the JOB's")
}

@(test)
test_P15_answer_kind_outside_the_catalog :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	fs := Fake_Server{answer = proc(fd: posix.FD, f: Raw_Frame) {
		if f.channel != 0 || f.kind != TEST_PING do return
		req := u32le_bytes(raw_req(f))
		raw_send(fd, 99, 0, req[:]) // our req, a kind no catalog row has
	}}
	if !fake_open(t, &fs, {dir, "s"}) do return
	defer fake_close(&fs)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	b := u32le_bytes(1)
	_, err := ipc.client_call(&c, TEST_PING, b[:], {timeout = 2 * time.Second})
	expect_kind(t, err, .Bad_Reply, "PING")
}
