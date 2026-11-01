package feature_session_core

// Putting the view back after a scan. A stitch is complete only when the
// screen matches the page the read started on, so the remaining distance is
// measured instead of assumed from a notch count: a slow program can answer two
// notches with one repaint, and a clamped wheel moves fewer lines than asked.
// A burst the program has not answered yet is retried, never re-sent. When the
// wheel cannot put the view back within the bounded budget, the answer says so
// instead of claiming success; the viewers' held input and repaint follow.

STITCH_RESTORE_MS    :: 900 // the view goes back even when the scan used its deadline
STITCH_TOTAL_MS      :: 4800 // ... and the whole answer stays under the CLI's 5 s window
STITCH_RESTORE_TRIES :: 4 // bursts that still did not reach the start page
STITCH_RESTORE_BURST :: 512 // notches in one burst (the holder queues them, nothing is lost)

// _stitch_restore_begin turns scanning into restoring: it gives the restore its
// own bounded time and sends the first burst back towards the start page.
@(private)
_stitch_restore_begin :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	now := _now()
	st.phase = .Restore
	st.per_notch, st.restore_tries, st.restore_failed = _stitch_per_notch(st), 0, false
	limit := st.begin_ns + STITCH_TOTAL_MS * 1_000_000
	want := min(now + STITCH_RESTORE_MS * 1_000_000, limit)
	if want > st.deadline_ns do st.deadline_ns = want
	_stitch_restore_burst(c, s)
}

// _stitch_restore_read compares the screen with the page the read started on.
// Same screen = verified, done. Otherwise the distance still to go is measured
// against that page (or against the previous read when they no longer overlap)
// and one bounded burst is sent.
@(private)
_stitch_restore_read :: proc(c: ^Core, s: ^Core_Session, a, b: []string, now: i64) {
	st := s.stitch
	rows_start: [STITCH_MAX_ROWS]string
	o := _stitch_rows(&st.pages[2], rows_start[:])
	col := stitch_scrollbar_col(a, o, b)
	if stitch_same(a, o, col) {
		_stitch_finish(c, s) // verified: the view is where the read found it
		return
	}
	if !_stitch_answered(st) {
		if now - st.sent_ns < STITCH_EDGE_MS * 1_000_000 {
			st.due_ns = now + STITCH_MIN_PACE_MS * 1_000_000
			return // the program has not looked at the wheel yet
		}
		_stitch_restore_give_up(c, s) // silent and still not there: do not claim success
		return
	}
	if d, ok := stitch_delta(a, o, col); ok {
		st.above = d // still above (or, below) the start page: exact
	} else if d, ok := stitch_delta(a, b, col); ok {
		st.above += d // too far to overlap: use how far this burst moved
	} else {
		st.above = st.above_sent
	}
	st.restore_tries += 1
	if st.restore_tries > STITCH_RESTORE_TRIES {
		_stitch_restore_give_up(c, s)
		return
	}
	_stitch_restore_burst(c, s)
}

// _stitch_restore_burst sends the notches the measured distance asks for, in
// the direction that closes it, and schedules the verifying read.
@(private = "file")
_stitch_restore_burst :: proc(c: ^Core, s: ^Core_Session) {
	st := s.stitch
	down := st.above > 0
	lines := abs(st.above)
	notches := 0
	if lines > 0 do notches = clamp((lines + st.per_notch - 1) / st.per_notch, 1, STITCH_RESTORE_BURST)
	move := notches * st.per_notch
	st.above_sent = st.above - move
	if !down do st.above_sent = st.above + move
	if notches > 0 && !_stitch_send_notches(c, s, down, notches, st) {
		_stitch_restore_give_up(c, s) // the program stopped reporting the mouse
		return
	}
	st.due_ns = _now() + st.pace_ns
}

// _stitch_send_notches queues `count` notches in one write: they stay ordered
// through the holder's input queue, so the program sees every one.
@(private)
_stitch_send_notches :: proc(c: ^Core, s: ^Core_Session, down: bool, count: int, st: ^Stitch_State) -> bool {
	buf: [STITCH_RESTORE_BURST * STITCH_WHEEL_BYTES]u8
	n := 0
	for _ in 0..<count {
		k := _stitch_wheel(&s.sess.term, down, buf[n:])
		if k == 0 do return false
		n += k
	}
	now := _now()
	if st.sent_ns != 0 {
		response := max(st.last_out_ns - st.sent_ns, 0)
		pace := response * 2 + STITCH_MIN_PACE_MS * 1_000_000
		st.pace_ns = clamp(pace, STITCH_MIN_PACE_MS * 1_000_000, STITCH_MAX_PACE_MS * 1_000_000)
	}
	st.sent_ns = now
	_stitch_input(c, s, buf[:n])
	return true
}

@(private = "file")
_stitch_restore_give_up :: proc(c: ^Core, s: ^Core_Session) {
	s.stitch.restore_failed = true
	_stitch_finish(c, s)
}

// _stitch_per_notch is the measured lines a notch moved while scanning. Clamped
// notches only make it smaller, which lands the burst short instead of past the
// start page, and the next measuring read corrects it.
@(private = "file")
_stitch_per_notch :: proc(st: ^Stitch_State) -> int {
	if st.notches <= 0 || st.above <= 0 do return 1
	return clamp((st.above + st.notches - 1) / st.notches, 1, STITCH_SHIFT_MAX)
}
