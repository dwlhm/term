package platform_ipc_contract

// Child mode: the test binary runs itself as a server in another process, for
// the tests that need one there. P23 starts it through Client_Opts.start with
// "" in argv[0] (= this executable); P30 spawns it under a low RLIMIT_NOFILE.
// @(init) runs before the test runner, so a child never runs the tests.
//
// The child serves test_protocol at the endpoint it is given and answers
// PING(CHILD_ASK_PID) with its pid and PING(CHILD_ASK_WAKES) with how often
// poll_set_wait returned. "serve" exits when its last peer leaves; both modes
// exit after CHILD_LIFE_MS at the latest. Exit 3 = the server did not open.

import "base:runtime"
import "core:c"
import "core:os"
import "core:sys/posix"
import ipc "../"

CHILD_FLAG      :: "--ipc-contract-child"
CHILD_LIFE_MS   :: 10_000
CHILD_ASK_PID   :: u32(0)
CHILD_ASK_WAKES :: u32(1)

@(init)
_child_main :: proc "contextless" () {
	args := runtime.args__
	if len(args) < 5 || string(args[1]) != CHILD_FLAG do return
	context = runtime.default_context()
	at := ipc.Endpoint{dir = string(args[3]), name = string(args[4])}
	switch string(args[2]) {
	case "serve":  posix._exit(_child_serve(at, false))
	case "emfile": posix._exit(_child_serve(at, true))
	}
	posix._exit(2)
}

// child_start: Client_Opts.start that runs this binary as a "serve" child.
child_start :: proc(at: ipc.Endpoint) -> []string {
	argv := make([]string, 5, context.temp_allocator)
	argv[0], argv[1], argv[2], argv[3], argv[4] = "", CHILD_FLAG, "serve", at.dir, at.name
	return argv
}

// child_spawn runs this binary as a child in mode; -1 when it did not start.
child_spawn :: proc(mode: string, at: ipc.Endpoint) -> posix.pid_t {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return -1
	argv := [?]cstring{cstr(exe), CHILD_FLAG, cstr(mode), cstr(at.dir), cstr(at.name), nil}
	pid: posix.pid_t
	if posix.posix_spawn(&pid, argv[0], nil, nil, raw_data(argv[:]), posix.environ) != .NONE do return -1
	return pid
}

child_reap :: proc(pid: posix.pid_t) {
	if pid <= 0 do return
	posix.kill(pid, .SIGKILL)
	status: c.int
	posix.waitpid(pid, &status, {})
}

// child_ask sends PING(what) to a child and returns its answer.
child_ask :: proc(cl: ^ipc.Client, what: u32) -> (v: u32, err: ipc.Error) {
	b := u32le_bytes(what)
	a: ipc.Answer
	a, err = ipc.client_call(cl, TEST_PING, b[:])
	if err.kind != .None do return
	v, _ = answer_u32(a)
	return
}

@(private = "file")
_child_serve :: proc(at: ipc.Endpoint, emfile: bool) -> c.int {
	set: ipc.Poll_Set
	srv: ipc.Server
	if ipc.poll_set_init(&set, 64).kind != .None do return 3
	defer ipc.poll_set_destroy(&set)
	if ipc.server_open(&srv, at, test_protocol(), &set).kind != .None do return 3
	defer ipc.server_close(&srv)
	if emfile do _leave_one_fd()
	due := now_ns() + CHILD_LIFE_MS * 1_000_000
	wakes, joined, live: u32
	for now_ns() < due {
		ipc.poll_set_wait(&set, due)
		wakes += 1
		for ev in ipc.server_next(&srv) {
			#partial switch e in ev {
			case ipc.Peer_Joined: joined, live = joined + 1, live + 1
			case ipc.Peer_Left:   live -= 1
			case ipc.Request:     _child_answer(&srv, e, wakes)
			}
		}
		if !emfile && joined > 0 && live == 0 do break
	}
	return 0
}

@(private = "file")
_child_answer :: proc(srv: ^ipc.Server, req: ipc.Request, wakes: u32) {
	req := req
	what: u32
	if !ipc.request_decode(&req, &what, dec_u32) do return
	reply_u32(srv, req, u32(posix.getpid()) if what == CHILD_ASK_PID else wakes)
}

// _leave_one_fd lowers RLIMIT_NOFILE so exactly one fd number stays free:
// the next accept takes it and the one after hits EMFILE.
@(private = "file")
_leave_one_fd :: proc() {
	free := posix.FD(0)
	for is_open(free) do free += 1
	lim: posix.rlimit
	posix.getrlimit(.NOFILE, &lim)
	lim.rlim_cur = posix.rlim_t(free + 1)
	posix.setrlimit(.NOFILE, &lim)
}
