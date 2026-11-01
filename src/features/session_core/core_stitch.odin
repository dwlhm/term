package feature_session_core

// Stitch: the history of a full-screen program, read by scrolling it. A
// program in the alternate screen keeps its history itself, so a `term session
// read -n N` of such a session sends mouse-wheel notches the way the program
// asked for mouse reports, waits for the screen to settle and glues the pages
// (core_stitch_merge.odin decides what is trustworthy).
//
// The poll loop drives this state machine: every step has a deadline, so the
// core never sleeps through a stitch and never blocks another session. While a
// stitch runs, its viewers get no live frames (one repaint at the end) and
// their input is held in a bounded buffer, delivered afterwards.

STITCH_DEADLINE_MS   :: 4000 // whole stitch, under the CLI's 5 s answer window
STITCH_QUIET_MS      :: 25 // no output for this long: the screen settled
STITCH_MIN_PACE_MS   :: 8 // never read sooner than this after a notch
STITCH_MAX_PACE_MS   :: 250 // a slow program paces the whole stitch
STITCH_TOP_STEPS     :: 2 // quiet steps in a row before the view is at the top
STITCH_HOLD_BYTES    :: 64 << 10 // typed input held while stitching
STITCH_HISTORY_BYTES :: 512 << 10 // stitched text cap (the payload cap is 1 MiB)
STITCH_PAGE_BYTES    :: 512 << 10 // one page of rows
STITCH_CELL_BYTES    :: 16 // upper bound for one cell's UTF-8
STITCH_WHEEL_BYTES   :: 32 // one encoded notch

CORE_READ_ALT_NOTE :: "\n[term: the program does not report mouse input, so only its visible screen is available]\n"

Stitch_Phase :: enum u8 { Idle, Probe_Down, Probe_Up, Up }

// Stitch_Page is one read of the visible screen. Rows are byte ranges into
// `text`, so a buffer reallocation cannot dangle them.
Stitch_Page :: struct {
	text:  [dynamic]u8,
	off:   [STITCH_MAX_ROWS]int,
	len:   [STITCH_MAX_ROWS]int,
	count: int,
}

Stitch_State :: struct {
	active:       bool,
	phase:        Stitch_Phase,
	viewer:       int, // who asked (with seq, in case the slot was reused)
	seq:          u32,
	want:         int, // history lines asked for
	got:          int, // history lines already glued
	pages:        [3]Stitch_Page, // 0/1 alternate, 2 = the screen the read saw
	cur:          int, // where the next read goes
	prev:         int, // the page the last step read (2 = the original screen)
	was_scrolled: bool, // the probe found the view above the bottom
	moved_up:     int, // notches that really moved the view
	moved_down:   int,
	quiet_steps:  int,
	sent_ns:      i64, // the last notch went out
	due_ns:       i64, // do not read before this
	deadline_ns:  i64,
	last_out_ns:  i64, // the program printed something
	pace_ns:      i64,
	hist:         [dynamic]u8, // revealed lines, newest first
	hold:         [dynamic]u8, // input held while stitching
}

// Stitch_Start is what `read` should do with a request.
Stitch_Start :: enum u8 { Started, Screen, Screen_Marked, Busy }

// core_stitch_begin starts reading the history of an alternate-screen session,
// or says that the visible screen alone is the answer.
core_stitch_begin :: proc(c: ^Core, s: ^Core_Session, vi: int, history: int) -> (start: Stitch_Start) {
	t := &s.sess.term
	if history <= 0 || !t.parser.in_alt_screen do return .Screen
	if t.parser.mouse_mode == .None do return .Screen_Marked
	st := s.stitch
	if st != nil && st.active do return .Busy
	if st == nil {
		s.stitch = new(Stitch_State)
		st = s.stitch
	}
	need := min(t.rows, STITCH_MAX_ROWS) * (t.cols * STITCH_CELL_BYTES + 1)
	if need > STITCH_PAGE_BYTES do return .Screen_Marked
	for &p in st.pages {
		if cap(p.text) < need do reserve(&p.text, need)
	}
	if cap(st.hist) == 0 do reserve(&st.hist, 8192)
	if cap(st.hold) < STITCH_HOLD_BYTES do reserve(&st.hold, STITCH_HOLD_BYTES)
	clear(&st.hist)
	clear(&st.hold)
	st.active = true
	st.cur, st.prev, st.got, st.was_scrolled = 0, 2, 0, false
	st.moved_up, st.moved_down, st.quiet_steps, st.sent_ns = 0, 0, 0, 0
	st.viewer, st.seq = vi, c.viewers[vi].seq
	st.want = min(history, CORE_PAINT_HISTORY_MAX)
	st.last_out_ns = _now()
	st.deadline_ns = st.last_out_ns + STITCH_DEADLINE_MS * 1_000_000
	st.pace_ns = STITCH_MIN_PACE_MS * 1_000_000
	if !_stitch_read(s, &st.pages[2]) do return _stitch_abort(st)
	st.phase = .Probe_Down
	_stitch_notch(c, s, true, st)
	return .Started
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
	core_viewer_fail_seq(c, st.viewer, st.seq, .Exited, "the session ended while its history was read")
}

@(private)
_stitch_step :: proc(c: ^Core, s: ^Core_Session, now: i64) {
	st := s.stitch
	if s.exited || now >= st.deadline_ns {
		_stitch_finish(c, s)
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
	col := stitch_scrollbar_col(a, b)
	same := stitch_same(a, b, col)
	st.prev = st.cur
	st.cur = 1 - st.cur
	switch st.phase {
	case .Probe_Down:
		// A notch down moved the view: it was already scrolled up, so the
		// matching notch up only returns to the start page (no new lines).
		st.was_scrolled = !same
		if !same do st.moved_down += 1
		st.quiet_steps = 0
		st.phase = .Probe_Up
		_stitch_notch(c, s, false, st)
	case .Probe_Up, .Up:
		if same {
			st.quiet_steps += 1
		} else if d, ok := stitch_shift(a, b, col); ok {
			st.quiet_steps = 0
			st.moved_up += 1
			if st.phase == .Up || !st.was_scrolled do _stitch_glue(st, a, b, col, d)
		} else {
			_stitch_finish(c, s) // unaligned: keep only what we have
			return
		}
		if st.quiet_steps >= STITCH_TOP_STEPS || st.got >= st.want || len(st.hist) >= STITCH_HISTORY_BYTES {
			_stitch_finish(c, s)
			return
		}
		st.phase = .Up
		_stitch_notch(c, s, false, st)
	case .Idle:
	}
}

// _stitch_glue prepends the lines the new page revealed above the old one: the
// buffer is kept newest-first, which is what the reply walks backwards.
@(private = "file")
_stitch_glue :: proc(st: ^Stitch_State, a, b: []string, col: int, d: int) {
	from, to := stitch_glue_range(a, b, col, d)
	for i := to - 1; i >= from; i -= 1 {
		append(&st.hist, ..transmute([]u8)stitch_key(a[i], col))
		append(&st.hist, '\n')
		st.got += 1
	}
}

// _stitch_notch sends one wheel notch and schedules the next read. The pace
// adapts to how fast the program answered the previous one.
@(private = "file")
_stitch_notch :: proc(c: ^Core, s: ^Core_Session, down: bool, st: ^Stitch_State) {
	buf: [STITCH_WHEEL_BYTES]u8
	n := _stitch_wheel(&s.sess.term, down, buf[:])
	if n == 0 {
		_stitch_finish(c, s) // the program stopped reporting the mouse
		return
	}
	now := _now()
	if st.sent_ns != 0 {
		response := max(st.last_out_ns - st.sent_ns, 0)
		pace := response * 2 + STITCH_MIN_PACE_MS * 1_000_000
		st.pace_ns = clamp(pace, STITCH_MIN_PACE_MS * 1_000_000, STITCH_MAX_PACE_MS * 1_000_000)
	}
	st.sent_ns, st.due_ns = now, now + st.pace_ns
	_stitch_input(c, s, buf[:n])
}

@(private = "file")
_stitch_finish :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	if !st.active do return
	st.active, st.phase = false, .Idle
	_stitch_return(c, s, st.moved_up - st.moved_down)
	_stitch_reply(c, s)
	if len(st.hold) > 0 && !s.exited do _stitch_input(c, s, st.hold[:])
	clear(&st.hold)
	// One repaint replaces the frames the viewers did not get.
	core_attach_repaint(c, s)
}

// _stitch_return puts the view back where it was: as many notches down as it
// really moved up (and the other way when a probe overshot).
@(private = "file")
_stitch_return :: proc(c: ^Core, s: ^Core_Session, net_up: int) {
	buf: [STITCH_WHEEL_BYTES * 32]u8
	n := 0
	for _ in 0..<abs(net_up) {
		if n + STITCH_WHEEL_BYTES > len(buf) {
			_stitch_input(c, s, buf[:n])
			n = 0
		}
		n += _stitch_wheel(&s.sess.term, net_up > 0, buf[n:])
	}
	if n > 0 do _stitch_input(c, s, buf[:n])
}
