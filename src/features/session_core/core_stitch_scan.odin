package feature_session_core

// The scanning half of a stitch: the probe, one upward page per notch and the
// decision to keep going. Every observation is a measured distance; a page that
// did not move is only believed after the program had a chance to answer, so a
// slow program is never mistaken for the top of its history.

// _stitch_probe_down reads the screen one notch below the start: a moved page
// means the view was already scrolled, so its matching notch only returns.
@(private)
_stitch_probe_down :: proc(c: ^Core, s: ^Core_Session, a, b: []string) {
	st := s.stitch
	col := stitch_scrollbar_col(a, b)
	st.was_scrolled = !stitch_same(a, b, col)
	if st.was_scrolled {
		if d, ok := stitch_delta(a, b, col); ok do st.above += d
	}
	st.quiet_steps = 0
	st.phase = .Probe_Up
	_stitch_notch(c, s, false, st)
}

// _stitch_scan glues one upward page and decides whether to keep scanning.
@(private)
_stitch_scan :: proc(c: ^Core, s: ^Core_Session, a, b: []string, now: i64) {
	st := s.stitch
	col := stitch_scrollbar_col(a, b)
	if stitch_same(a, b, col) {
		// Silence right after a notch is not proof of the top: the program may
		// not have looked at the wheel yet.
		if !_stitch_answered(st) && now - st.sent_ns < STITCH_EDGE_MS * 1_000_000 {
			st.due_ns = now + STITCH_MIN_PACE_MS * 1_000_000
			return
		}
		st.quiet_steps += 1
	} else if d, ok := stitch_shift(a, b, col); ok {
		st.quiet_steps = 0
		st.above += d
		if st.phase == .Up || !st.was_scrolled do _stitch_glue(st, a, b, col, d)
	} else {
		_stitch_restore_begin(c, s) // unaligned: keep only what we have
		return
	}
	if st.quiet_steps >= STITCH_TOP_STEPS || st.got >= st.want || len(st.hist) >= STITCH_HISTORY_BYTES {
		_stitch_restore_begin(c, s)
		return
	}
	st.phase = .Up
	_stitch_notch(c, s, false, st)
}

// _stitch_answered: the program printed after the last notch went out.
@(private)
_stitch_answered :: proc(st: ^Stitch_State) -> bool {
	return st.last_out_ns > st.sent_ns
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
@(private)
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
	st.notches += 1
	st.sent_ns, st.due_ns = now, now + st.pace_ns
	_stitch_input(c, s, buf[:n])
}
