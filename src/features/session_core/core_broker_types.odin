package feature_session_core

// Broker data: limits, requests, the shell adapter's per-session state,
// waiting workers and watches, and the effects a call asks the core for
// (core_broker.odin explains the model).

import proto "../session_proto"

CORE_MAX_REQUESTS          :: 32
BROKER_MAX_LISTENERS       :: 64
BROKER_MAX_WATCHES         :: 64
BROKER_BODY_CAP            :: proto.TELL_BODY_MAX
BROKER_TEXT_CAP            :: 64 * 1024
BROKER_PROGRESS_CAP        :: 4 * 1024
BROKER_MAX_EFFECTS         :: 8 * CORE_MAX_REQUESTS + BROKER_MAX_WATCHES + BROKER_MAX_LISTENERS
BROKER_DEFAULT_TIMEOUT_MS  :: 30 * 60 * 1000
BROKER_RESULT_TTL_MS       :: 10 * 60 * 1000 // a result nobody fetched is kept this long
BROKER_START_MS            :: 10_000 // a starting shell gets this long to show its first prompt
BROKER_DRAIN_MS            :: 5_000  // a cancelled shell command holds its target at most this long
BROKER_INT_RETRY_MS        :: 200    // SIGINT again until the command ends: 133;C precedes its fork

Broker_Status :: proto.Tell_Status
Broker_Reject :: proto.Tell_Reject

// Shell_Readiness is what the parser says about a target's shell.
Shell_Readiness :: enum u8 {
	None,     // no OSC 133 seen
	Starting, // no prompt yet, no command ran: the shell is still starting
	Busy,     // a command runs or a full-screen program owns the screen
	Ready,    // at its prompt
}

Human_Input :: enum u8 {Interrupt, Other} // ^C/lone Esc vs any other keystroke

Target_Kind :: enum u8 {Shell, Worker}

Req_Phase :: enum u8 {Free, Starting, Running, Finished, Spent}

Broker_Request :: struct {
	id:           u64,
	parent:       u64, // the request whose work sent this one (0 = none)
	phase:        Req_Phase,
	kind:         Target_Kind,
	status:       Broker_Status,
	started:      bool, // a shell target ran it (133;C): an interrupt reaches it
	shell_only:   bool, // a command for the shell adapter (`run`): no worker takes it
	from, to:     u32, // from 0 = outside term
	waiter:       int, // the sender's connection waiting for progress and result (-1 = none)
	exit_code:    i32,
	due_ns:       i64,
	full_due_ns:  i64, // due_ns once a starting shell is ready
	finished_ns:  i64,
	progress_seq: u32,
	body_len:     int,
	text_len:     int,
	progress_len: int,
	body:         [BROKER_BODY_CAP]u8,
	text:         [BROKER_TEXT_CAP]u8,
	progress:     [BROKER_PROGRESS_CAP]u8,
}

// Broker_Party: the shell adapter's state of one session.
Broker_Party :: struct {
	sid:   u32, // 0 = free entry
	shell: int, // request its shell adapter runs (-1 = none)
	// A cancelled shell request: its typed line still runs, and 133;C comes
	// before the shell forks it, so SIGINT repeats from 133;C until 133;D. The
	// shell stays bound until then or drain_due_ns (0 = not draining).
	drain_due_ns:  i64,
	drain_next_ns: i64, // next SIGINT (0 = wait for 133;C)
}

// Broker_Listener: one worker of sid waiting in `next`: one free slot.
Broker_Listener :: struct {
	used:   bool,
	sid:    u32,
	viewer: int,
	due_ns: i64, // 0 = no deadline
}

// Broker_Watch: a `result --wait` on up to proto.RESULT_MAX_IDS requests.
Broker_Watch :: struct {
	used:   bool,
	follow: bool, // progress frames too
	viewer: int,
	caller: u32,
	n_ids:  int,
	ids:    [proto.RESULT_MAX_IDS]u64,
	due_ns: i64,
}

Broker_Effect_Kind :: enum u8 {
	Inject,    // type reqs[req].body into shell sid
	Interrupt, // SIGINT what shell sid runs
	Assign,    // answer viewer's `next` with reqs[req]
	Result,    // answer viewer with the result of reqs[req]
	Progress,  // send viewer the progress of reqs[req]
	Expired,   // viewer's `next` or `result --wait` timed out
	Gone,      // viewer's `next` waited for a session that ended
	Row,       // sid's request columns changed
}

// Broker_Effect: viewer (like Broker_Listener.viewer, Broker_Watch.viewer and
// Broker_Request.waiter) is the core's waiter key, an index into Core.waits.
Broker_Effect :: struct {
	kind:   Broker_Effect_Kind,
	sid:    u32,
	viewer: int,
	req:    int,
}

Broker :: struct {
	now:       proc() -> i64, // monotonic ns (the core's clock; tests pass a fake)
	next_id:   u64,
	reqs:      []Broker_Request,
	parties:   [CORE_MAX_SESSIONS]Broker_Party,
	listeners: [BROKER_MAX_LISTENERS]Broker_Listener,
	watches:   [BROKER_MAX_WATCHES]Broker_Watch,
	effects:   [BROKER_MAX_EFFECTS]Broker_Effect,
	n_effects: int,
}
