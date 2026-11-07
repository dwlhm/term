package platform_ipc

// Message catalog for both stream links. Every payload is encoded with
// stream_wire.odin; decoded strings are views into the frame payload.
// Kinds 0..2 are the transport's own (stream.odin).

// Every link starts with HELLO from the connecting side, answered by HELLO.
MSG_HELLO :: u8(10)

// core → holder (channel = session id unless noted)
MSG_SPAWN      :: u8(20) // Spawn_Msg
MSG_INPUT      :: u8(21) // raw bytes for the program
MSG_RESIZE     :: u8(22) // Size_Msg
MSG_SIGNAL     :: u8(23) // i32 signal number, for the foreground process group
MSG_RELEASE    :: u8(24) // forget the session (hang up leftovers)
MSG_GOODBYE    :: u8(25) // channel 0, u8 Goodbye
MSG_PROC_QUERY :: u8(26) // foreground process info please
MSG_DRAIN      :: u8(27) // channel 0: take no new sessions, exit when empty

// holder → core
MSG_WELCOME      :: u8(40) // channel 0, Welcome_Msg header + Held_Session per session
MSG_TAIL         :: u8(41) // the session's recent raw output (≤ HOLDER_TAIL_BYTES)
MSG_OUTPUT       :: u8(42) // raw program output
MSG_SPAWNED      :: u8(43) // u32 pid + i64 started_unix
MSG_SPAWN_FAILED :: u8(44) // reason text
MSG_EXITED       :: u8(45) // Exit_Msg
MSG_BYE          :: u8(46) // channel 0: last frame before the holder lets go
MSG_PROC_INFO    :: u8(47) // Proc_Info_Msg

// viewer/cli → core, channel 0
MSG_LIST   :: u8(60) // → MSG_SESSIONS
MSG_CREATE :: u8(61) // u32 token + Spawn_Msg → MSG_ATTACHED (the creator is attached) | MSG_FAIL
MSG_KILL   :: u8(62) // u32 id → MSG_OK | MSG_FAIL
MSG_ATTACH :: u8(63) // u32 token + Attach_Msg → MSG_ATTACHED | MSG_FAIL
MSG_DETACH :: u8(64) // u32 channel
MSG_OBSERVE :: u8(65) // u32 id + u32 lines → MSG_OBSERVE_RESULT | MSG_FAIL
MSG_READ   :: u8(66) // u32 id + u32 history lines → MSG_TEXT (plain screen text) | MSG_FAIL
MSG_SEND   :: u8(67) // u32 id + raw bytes for the program → MSG_OK | MSG_FAIL
MSG_SESSION_SIGNAL :: u8(68) // u32 id + i32 signal (foreground group) → MSG_OK | MSG_FAIL
MSG_SESSION_SIZE   :: u8(69) // u32 id + Size_Msg (only while no window shows it) → MSG_OK | MSG_FAIL
MSG_TELL           :: u8(74) // Tell_Request → MSG_TELL_RESULT Accepted | Rejected (wait: Progress…, Finished later) | MSG_FAIL
MSG_CANCEL         :: u8(75) // u64 request id → MSG_OK | MSG_FAIL
MSG_NEXT           :: u8(76) // u32 worker session + u32 timeout_ms → MSG_REQUEST (when one comes) | MSG_FAIL
MSG_ANSWER         :: u8(79) // Answer_Msg → MSG_OK | MSG_FAIL
MSG_PROGRESS       :: u8(100) // Answer_Msg → MSG_OK | MSG_FAIL
MSG_RESULT         :: u8(101) // Result_Request → MSG_TELL_RESULT Running | Finished (follow: Progress… first) | MSG_FAIL
MSG_ENDPOINT       :: u8(102) // str name + bool owned → MSG_OK + u32 session id | MSG_FAIL
MSG_WATCH          :: u8(77) // Watch_Request → MSG_WATCH_RESULT | MSG_OK | MSG_FAIL

// viewer → core, on an attach channel
MSG_V_INPUT  :: u8(70) // raw bytes typed into the session
MSG_V_RESIZE :: u8(71) // Size_Msg
MSG_V_FOCUS  :: u8(72) // bool
MSG_V_FACTS  :: u8(73) // Facts_Msg
MSG_V_REPLY  :: u8(78) // raw bytes the viewer's Terminal answered a query with (not typed)

// core → viewer/cli
MSG_SESSIONS :: u8(80) // u32 count + Session_Row each
MSG_ATTACHED :: u8(82) // u32 token, u32 id, u32 channel; the first paint follows as DATA
MSG_EVENT    :: u8(83) // Session_Row of a session that changed (added, state, title, exited)
MSG_FAIL     :: u8(84) // u32 token + u8 Fail_Code + reason text
MSG_OK       :: u8(85)
MSG_REMOVED  :: u8(86) // u32 id: the session is gone
MSG_TEXT     :: u8(87) // UTF-8 text (MSG_READ)
MSG_OBSERVE_RESULT :: u8(88) // Observe_Result
MSG_TELL_RESULT    :: u8(89) // Tell_Result
MSG_WATCH_RESULT   :: u8(90) // Watch_Result
MSG_REQUEST        :: u8(91) // Next_Result

Stream_Role :: enum u8 { Core = 1, Holder, Viewer, Cli }

Goodbye :: enum u8 { Handover = 1, Shutdown }

Fail_Code :: enum u8 { Not_Found = 1, Exited, Bad_Request, Spawn_Failed, Busy, Version, Timeout }

Hello_Msg :: struct {
	version: u32,
	role:    Stream_Role,
	caps:    u64,
	build:   string,
}

STREAM_MAX_ARGV :: 64
STREAM_MAX_ENV  :: 256

Spawn_Msg :: struct {
	argv:       [STREAM_MAX_ARGV]string,
	argc:       int,
	env:        [STREAM_MAX_ENV]string,
	envc:       int,
	cwd:        string,
	using size: Size_Msg,
}

Size_Msg :: struct {
	cols, rows, xpixel, ypixel: u16,
}

Exit_Msg :: struct {
	code:     i32,
	signal:   i32,
	signaled: bool,
}

Proc_Info_Msg :: struct {
	pgid: i32,
	name: string,
	cwd:  string,
}

Held_Session :: struct {
	id:           u32,
	pid:          u32,
	started_unix: i64,
	size:         Size_Msg,
	exited:       bool,
	exit:         Exit_Msg,
}

Welcome_Msg :: struct {
	version:  u32,
	instance: u64, // random per holder process
	pid:      u32,
	build:    string,
	previous: u8, // 0 none, 1 handover, 2 crash
	crashes:  u32, // core links that ended in a crash in the last 5 minutes
	count:    u32, // Held_Session records follow in the same payload
}

Attach_Msg :: struct {
	id:      u32,
	size:    Size_Msg,
	history: u32,
	observe: bool,
}

// Facts_Msg: what the size owner's display looks like (queries about pixels are answered with it).
Facts_Msg :: struct {
	cell_w, cell_h: u16,
}

Session_State :: enum u8 { Idle = 1, Busy, Exited }

Session_Row :: struct {
	id:           u32,
	state:        Session_State,
	active:       bool, // a CLI/TUI runs (quit asks before killing it)
	attached:     bool,
	pid:          u32,
	elapsed_s:    u32,
	quiet_s:      u32, // seconds since its program last printed
	endpoint:     bool, // a virtual session: no program, a name, requests only
	exit_code:    i32,
	request:      Row_Request,
	process:      string,
	cwd:          string,
	title:        string,
	status:       string, // OSC 7501 message
}

Prompt_State :: enum u8 { None = 0, Prompt = 1, Input = 2, Executing = 3 }

Observe_Result :: struct {
	row:           Session_Row,
	cols:          u16,
	rows:          u16,
	is_alt:        bool,
	prompt_state:  Prompt_State,
	has_cmd_exit:  bool,
	cmd_exit_code: i32,
	cmd_seq:       u32, // commands finished so far: `watch --since` baseline
	text:          string,
}

Watch_Event :: enum u8 {
	Prompt    = 0,
	Executing = 1,
	Exit      = 2,
}
Watch_Event_Flags :: distinct bit_set[Watch_Event; u8]

Watch_Request :: struct {
	id:             u32,
	events:         Watch_Event_Flags,
	timeout_ms:     u32,
	has_since:      bool, // Prompt: answer at once when cmd_seq > since and the shell is at a prompt
	since:          u32,
}

Watch_Result :: struct {
	id:           u32,
	event:        Watch_Event,
	exit_code:    i32,
	prompt_state: Prompt_State,
	cmd_seq:      u32,
}
