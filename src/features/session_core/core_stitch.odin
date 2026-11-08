package feature_session_core

import terminal "../../core/terminal"
import ipc "../../platform/ipc"

// Stitch: the history of a full-screen program, read by scrolling it. A
// program in the alternate screen keeps its history itself, so a `term session
// read -n N` of such a session sends mouse-wheel notches the way the program
// asked for mouse reports, waits for the screen to settle and glues the pages
// (core_stitch_merge.odin decides what is trustworthy).
//
// The poll loop drives this state machine: every step has a deadline, so the
// core never sleeps through a stitch and never blocks another session. While a
// stitch runs, its viewers get no live frames and their input is held.
//
// The scan only counts measured distances: how far a page really moved, not
// how many notches were sent. That is what the restore phase needs, because a
// program may answer two notches with one repaint. A stitch is complete only
// after the screen matches the page the read started on; when the wheel cannot
// put it back within the deadline, the answer says so (core_stitch_restore.odin).
// Only then do the viewers get their repaint and their held input back.

STITCH_DEADLINE_MS   :: 4000 // scanning, under the CLI's 5 s answer window
STITCH_QUIET_MS      :: 25 // no output for this long: the screen settled
STITCH_MIN_PACE_MS   :: 8 // never read sooner than this after a notch
STITCH_MAX_PACE_MS   :: 250 // a slow program paces the whole stitch
STITCH_EDGE_MS       :: 300 // silence this long after a notch: the view hit an edge
STITCH_TOP_STEPS     :: 2 // quiet steps in a row before the view is at the top
STITCH_HOLD_BYTES    :: 64 << 10 // typed input held while stitching
STITCH_HISTORY_BYTES :: 512 << 10 // stitched text cap (the payload cap is 1 MiB)
STITCH_PAGE_BYTES    :: 512 << 10 // one page of rows
STITCH_CELL_BYTES    :: 16 // upper bound for one cell's UTF-8
STITCH_WHEEL_BYTES   :: 32 // one encoded notch

CORE_READ_ALT_NOTE :: "\n[term: the program does not report mouse input, so only its visible screen is available]\n"
CORE_READ_RESTORE_NOTE :: "\n[term: the program could not be scrolled back to the screen the read started on]\n"

Stitch_Phase :: enum u8 { Idle, Probe_Down, Probe_Up, Up, Restore }

// Stitch_Page is one read of the visible screen. Rows are byte ranges into
// `text`, so a buffer reallocation cannot dangle them.
Stitch_Page :: struct {
	text:  [dynamic]u8,
	off:   [STITCH_MAX_ROWS]int,
	len:   [STITCH_MAX_ROWS]int,
	count: int,
}

Stitch_State :: struct {
	active:         bool,
	phase:          Stitch_Phase,
	req:            ipc.Request, // the read it answers (nobody, once its peer left)
	want:           int, // history lines asked for
	got:            int, // history lines already glued
	pages:          [3]Stitch_Page, // 0/1 alternate, 2 = the screen the read saw
	cur:            int, // where the next read goes
	prev:           int, // the page the last step read (2 = the original screen)
	was_scrolled:   bool, // the probe found the view above the bottom
	above:          int, // measured lines the view sits above the page the read started on
	above_sent:     int, // where the last burst should have left it (when unmeasurable)
	per_notch:      int, // measured lines per notch, for sizing a restore burst
	notches:        int, // notches sent while scanning
	quiet_steps:    int,
	sent_ns:        i64, // the last notch went out
	due_ns:         i64, // do not read before this
	begin_ns:       i64,
	deadline_ns:    i64,
	last_out_ns:    i64, // the program printed something
	pace_ns:        i64,
	restore_tries:  int, // bursts that still did not reach the start page
	restore_failed: bool, // the answer must say the view was left scrolled
	hist:           [dynamic]u8, // revealed lines, newest first
	hold:           [dynamic]u8, // input held while stitching
}

// Stitch_Start is what `read` should do with a request.
Stitch_Start :: enum u8 { Started, Screen, Screen_Marked, Busy }

// core_stitch_begin starts reading the history of an alternate-screen session,
// or says that the visible screen alone is the answer.
core_stitch_begin :: proc(c: ^Core, s: ^Core_Session, req: ^ipc.Request, history: int) -> (start: Stitch_Start) {
	t := &s.sess.term
	if history <= 0 || !t.parser.in_alt_screen do return .Screen
	if t.parser.mouse_mode == .None do return .Screen_Marked
	st := s.stitch
	if st != nil && st.active do return .Busy
	if st == nil {
		s.stitch = new(Stitch_State)
		st = s.stitch
	}
	if !_stitch_reserve(st, t) do return .Screen_Marked
	clear(&st.hist)
	clear(&st.hold)
	st.active = true
	st.cur, st.prev, st.got, st.was_scrolled = 0, 2, 0, false
	st.above, st.above_sent, st.notches, st.per_notch = 0, 0, 0, 1
	st.quiet_steps, st.sent_ns, st.restore_tries, st.restore_failed = 0, 0, 0, false
	st.req = req^
	st.want = min(history, CORE_PAINT_HISTORY_MAX)
	st.last_out_ns, st.begin_ns = _now(), _now()
	st.deadline_ns = st.last_out_ns + STITCH_DEADLINE_MS * 1_000_000
	st.pace_ns = STITCH_MIN_PACE_MS * 1_000_000
	if !_stitch_read(s, &st.pages[2]) do return _stitch_abort(st)
	st.phase = .Probe_Down
	_stitch_notch(c, s, true, st)
	return .Started
}

// _stitch_reserve sizes the page and hold buffers for this terminal.
@(private = "file")
_stitch_reserve :: proc(st: ^Stitch_State, t: ^terminal.Terminal) -> bool {
	need := min(t.rows, STITCH_MAX_ROWS) * (t.cols * STITCH_CELL_BYTES + 1)
	if need > STITCH_PAGE_BYTES do return false
	for &p in st.pages do if cap(p.text) < need do reserve(&p.text, need)
	if cap(st.hist) == 0 do reserve(&st.hist, 8192)
	if cap(st.hold) < STITCH_HOLD_BYTES do reserve(&st.hold, STITCH_HOLD_BYTES)
	return true
}

@(private = "file")
_stitch_abort :: proc(st: ^Stitch_State) -> Stitch_Start {
	st.active, st.phase = false, .Idle
	return .Screen_Marked
}

// core_stitch_tick advances every running stitch whose deadline is due.
core_stitch_tick :: proc(c: ^Core) {
	now := _now()
	for &s in c.sessions do if s.used && s.stitch != nil && s.stitch.active do _stitch_step(c, &s, now)
}

// core_stitch_due_ns is when the stitch must be looked at again (-1: not
// running). The loop's poll timeout uses it, so nothing here ever sleeps.
core_stitch_due_ns :: proc(s: ^Core_Session) -> i64 {
	st := s.stitch
	if st == nil || !st.active do return -1
	due := max(st.due_ns, st.last_out_ns + STITCH_QUIET_MS * 1_000_000)
	return (due if due < st.deadline_ns else st.deadline_ns)
}

// core_stitch_hold takes viewer input while a stitch runs. false = not
// stitching (the caller forwards the bytes).
core_stitch_hold :: proc(s: ^Core_Session, bytes: []u8) -> bool {
	st := s.stitch
	if st == nil || !st.active do return false
	room := STITCH_HOLD_BYTES - len(st.hold)
	if room > 0 do append(&st.hold, ..bytes[:min(len(bytes), room)])
	return true
}

// core_stitch_abort ends a running stitch without an answer (its session is
// gone and will not produce the pages it waits for).
core_stitch_abort :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	if st == nil || !st.active do return
	st.active, st.phase = false, .Idle
	core_viewer_fail(c, &st.req, .Exited, "the session ended while its history was read")
}

@(private)
_stitch_step :: proc(c: ^Core, s: ^Core_Session, now: i64) {
	st := s.stitch
	if s.exited {
		_stitch_finish(c, s) // the program is gone: its last screen is the answer
		return
	}
	if now >= st.deadline_ns {
		_stitch_timeout(c, s)
		return
	}
	if now < st.due_ns do return
	if now - st.last_out_ns < STITCH_QUIET_MS * 1_000_000 do return
	cur, prev := &st.pages[st.cur], &st.pages[st.prev]
	if !_stitch_read(s, cur) {
		_stitch_finish(c, s)
		return
	}
	rows_cur, rows_prev: [STITCH_MAX_ROWS]string
	a := _stitch_rows(cur, rows_cur[:])
	b := _stitch_rows(prev, rows_prev[:])
	st.prev, st.cur = st.cur, 1 - st.cur
	switch st.phase {
	case .Probe_Down:
		_stitch_probe_down(c, s, a, b)
	case .Probe_Up, .Up:
		_stitch_scan(c, s, a, b, now)
	case .Restore:
		_stitch_restore_read(c, s, a, b, now)
	case .Idle:
	}
}

// _stitch_timeout: the scan is out of time. The view still has to go back; only
// a restore that runs out of time is answered with a warning.
@(private = "file")
_stitch_timeout :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	if st.phase != .Restore {
		_stitch_restore_begin(c, s)
		return
	}
	st.restore_failed = true
	_stitch_finish(c, s)
}

// _stitch_finish answers a stitch whose restore already ran (or that cannot be
// restored at all): the reply first, then the input its viewers typed, then one
// repaint of the verified screen.
@(private)
_stitch_finish :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	if !st.active do return
	st.active, st.phase = false, .Idle
	_stitch_reply(c, s)
	if len(st.hold) > 0 && !s.exited do _stitch_input(c, s, st.hold[:])
	clear(&st.hold)
	core_attach_repaint(c, s)
}
