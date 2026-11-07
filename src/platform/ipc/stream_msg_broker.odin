package platform_ipc

// Payloads of broker requests (MSG_TELL … MSG_ENDPOINT, docs/PROTOCOL.md).

// Row_Request: a session's part in broker requests.
Row_Request :: struct {
	serving:    u32, // requests it runs now (its shell adapter or its workers)
	serving_id: u64, // one of them (0 = none)
	awaiting:   u32, // requests it sent that still run
	listening:  u32, // its workers waiting in `next`: free slots
}

TELL_BODY_MAX :: 16 * 1024 // the broker's cap on a request body

Tell_Request :: struct {
	to:         u32,
	from:       u32, // the sender's own session ($TERM_SESSION_ID), 0 = outside term
	timeout_ms: u32, // 0 = the broker default
	parent:     u64, // the request the sender works on that this one serves (0 = the only one, if any)
	wait:       bool, // this connection gets the progress and the result
	shell:      bool, // only the shell adapter may take it (`run`), never a worker
	body:       string,
}

Tell_Reject :: enum u8 {
	None,
	Empty,         // no body
	Too_Large,     // body over TELL_BODY_MAX
	Busy,          // every worker of the target is taken, or its shell runs something
	Not_Listening, // no worker waits in `next` and no shell prompt to type at
	Multi_Line,    // a shell target runs one command per request
	Full,          // too many requests in flight
	Leased,        // an automation holds the session (term auto)
}

Tell_Status :: enum u8 {Done, Failed, Cancelled, Interrupted, Timeout, Error}

Tell_Phase :: enum u8 {
	Accepted = 1, // started; a waiting sender gets Progress and Finished here
	Rejected,
	Running,      // a `result` read: still runs (progress so far)
	Progress,
	Finished,
}

Tell_Result :: struct {
	id:        u64,
	phase:     Tell_Phase,
	reject:    Tell_Reject,
	status:    Tell_Status,
	exit_code: i32,
	from, to:  u32,
	progress:  string,
	text:      string,
}

// Next_Result: the request `term session next` took (MSG_REQUEST).
Next_Result :: struct {
	id:     u64,
	from:   u32,
	parent: u64,
	body:   string,
}

// Answer_Msg: a worker's MSG_ANSWER (final) or MSG_PROGRESS for a request it took.
Answer_Msg :: struct {
	by:     u32, // the worker's session
	id:     u64,
	failed: bool,
	text:   string,
}

RESULT_MAX_IDS :: 8

// Result_Request: MSG_RESULT. wait: answer when one of ids ends (follow: also
// on progress); otherwise read ids[0] now.
Result_Request :: struct {
	caller:     u32, // reading its own request's result frees it
	wait:       bool,
	follow:     bool,
	timeout_ms: u32,
	ids:        [RESULT_MAX_IDS]u64,
	n_ids:      u32,
}
