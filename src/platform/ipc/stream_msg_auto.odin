package platform_ipc

// Payloads of the session automation primitives (MSG_SNAPSHOT, MSG_SETTLE;
// docs/PROTOCOL.md). A snapshot is the parsed screen, never raw PTY bytes: the
// core's parser is the only one.

MSG_SNAPSHOT        :: u8(103) // Snapshot_Request → MSG_SNAPSHOT_RESULT | MSG_FAIL
MSG_SETTLE          :: u8(104) // Settle_Request → MSG_SETTLE_RESULT | MSG_FAIL (Timeout, Not_Found)
MSG_ACT             :: u8(105) // u32 session + u8 Act_Kind + its body → MSG_ACT_RESULT | MSG_FAIL
MSG_SNAPSHOT_RESULT :: u8(92)  // Snapshot
MSG_SETTLE_RESULT   :: u8(93)  // Settle_Result
MSG_ACT_RESULT      :: u8(94)  // u32 session + u64 gen: the screen generation the input went in at

SNAPSHOT_HISTORY_MAX :: 10_000 // history lines one snapshot may carry

// Snapshot_Request: history = at most that many scrollback lines above the
// screen; since >= 0 limits them to lines >= since (a line number is
// grid.scrolled + row, see Snapshot.top_line), so a caller gets only what
// scrolled off after its last snapshot.
Snapshot_Request :: struct {
	id:      u32,
	history: u32,
	since:   i64, // < 0: no lower bound
}

// Snap_Style: one cell's attributes. fg/bg are palette indices (7/0 are also
// the defaults: the grid does not tell them apart); rgb wins when has_*_rgb.
// style is the cell.Style_Flag bit set: 0 bold, 1 dim, 2 italic, 3 underline,
// 4 inverse, 5 strike, 6 blink, 7 hidden.
Snap_Style :: struct {
	fg, bg:             u8,
	has_fg_rgb:         bool,
	has_bg_rgb:         bool,
	fg_rgb, bg_rgb:     [3]u8,
	style:              u8,
	underline:          u8, // cell.Underline_Style: 0 none … 5 dashed
	link:               u16, // OSC 8 id, a key of Snapshot.links (0 = none)
}

// Snap_Run: cells with one style; a wide character counts 2 cells.
Snap_Run :: struct {
	cells: u16,
	style: Snap_Style,
	text:  string,
}

// Snap_Row: a grid row up to its last cell with content or attributes.
Snap_Row :: struct {
	line:   i64,  // grid line number
	wrap:   bool, // soft-wrapped into the next row
	prompt: bool, // drawn while the shell printed its prompt (OSC 133)
	runs:   []Snap_Run,
}

Snap_Link :: struct {
	id:  u16,
	uri: string,
}

Snapshot :: struct {
	id:           u32,
	gen:          u64, // screen generation: grows with every output or resize
	cols, rows:   u16,
	top_line:     i64, // line number of screen row 0
	cursor_row:   u16,
	cursor_col:   u16,
	cursor_shape: u8, // 0 block, 1 beam, 2 underline
	cursor_visible:  bool,
	cursor_blinking: bool,
	alt_screen:      bool,
	app_cursor:      bool, // DECCKM
	bracketed_paste: bool, // ?2004
	report_focus:    bool, // ?1004
	sync_output:     bool, // ?2026 held
	kitty_flags:     u8,
	mouse_mode:      u8, // 0 none, 1 ?9, 2 ?1000, 3 ?1002, 4 ?1003
	mouse_format:    u8, // 0 X10, 1 SGR ?1006, 2 SGR-pixel ?1016
	prompt_state:    Prompt_State,
	has_cmd_exit:    bool,
	cmd_exit_code:   i32,
	cmd_seq:         u32,
	exited:          bool,
	exit_code:       i32,
	status_state:    u8, // OSC 7501: 0 clear, 1 idle, 2 working, 3 blocked, 4 done, 5 error
	status_app:      string,
	status_kind:     string,
	status_msg:      string,
	title:           string,
	process:         string,
	history_truncated: bool, // more history matched than fit
	history:         []Snap_Row, // oldest first, ending right above the screen
	screen:          []Snap_Row, // rows 0..rows-1
	links:           []Snap_Link, // every link a run refers to
}

// Settle_Request: answer once the screen generation passed since and the
// program printed nothing for quiet_ms, or at once when the session exited.
Settle_Request :: struct {
	id:         u32,
	since:      u64,
	quiet_ms:   u32,
	timeout_ms: u32, // 0 = no deadline
}

Settle_Result :: struct {
	id:        u32,
	gen:       u64,
	exited:    bool,
	exit_code: i32,
}

// MSG_ACT: input encoded by the core for the modes the program has asked for
// at that moment. Keys are taps (press, then release when the program reports
// releases). Values mirror core/terminal/input_encode: Act_Key.key is its Key,
// mods its Mods bits (1 Shift, 2 Alt, 4 Ctrl, 8 Super).
Act_Kind :: enum u8 {
	Keys  = 1, // u32 n + n Act_Key
	Text  = 2, // bool paste + str. Typed: every character is a key tap (\n Enter, \t Tab);
	           // paste: one bracketed paste when the program enabled ?2004, else typed
	Mouse = 3, // Act_Mouse
}

ACT_KEYS_MAX :: 64
ACT_TEXT_MAX :: 64 * 1024

Act_Key :: struct {
	key:  u8,
	char: u32, // Key.Char only: printable ASCII
	mods: u8,
}

Act_Mouse :: struct {
	kind:   u8, // input_encode.Mouse_Kind: 0 press, 1 release, 2 motion, 3 wheel up, 4 wheel down
	button: u8, // 0 left, 1 middle, 2 right, 3 none
	mods:   u8,
	col:    u16, // 1-based cell
	row:    u16,
}
