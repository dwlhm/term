package feature_session_core_tests

// A viewer for tests: a session_client.Client driven from the test thread
// (it plays the UI thread), its events logged, its sessions drained.

import "core:strings"
import "core:time"
import client "../../session_client"
import session "../../session"
import ipc "../../../platform/ipc"

Logged :: struct {
	kind:      client.Client_Event_Kind,
	id:        u32,
	link_sess: ^session.Terminal_Session,
	state:     ipc.Session_State,
	attached:  bool,
	active:    bool,
	pid:       u32,
	exit_code: i32,
}

View :: struct {
	c:      client.Client,
	log:    [dynamic]Logged,
	drain:  bool, // false: a stalled UI that stops reading its sessions
	lost:   bool,
}

view_open :: proc() -> ^View {
	v := new(View)
	v.drain = true
	if !client.client_connect(&v.c, nil, nil) {
		free(v)
		return nil
	}
	return v
}

view_close :: proc(v: ^View) {
	client.client_disconnect(&v.c)
	delete(v.log)
	free(v)
}

view_spawn :: proc(v: ^View, argv: []string, cols: u16 = 80, rows: u16 = 24) -> ^session.Terminal_Session {
	spec: ipc.Spawn_Msg
	for a, i in argv do spec.argv[i] = a
	spec.argc = len(argv)
	spec.cols, spec.rows = cols, rows
	return client.client_create(&v.c, &spec)
}

view_sh :: proc(v: ^View, script: string, cols: u16 = 80, rows: u16 = 24) -> ^session.Terminal_Session {
	return view_spawn(v, {"/bin/sh", "-c", script}, cols, rows)
}

// view_pump handles events and drains sessions for up to ms.
view_pump :: proc(v: ^View, ms: int) {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for {
		_pump_once(v)
		if time.tick_now()._nsec >= deadline do return
		time.sleep(2 * time.Millisecond)
	}
}

@(private = "file")
_pump_once :: proc(v: ^View) {
	ev: client.Client_Event
	for client.client_poll(&v.c, &ev) {
		e := Logged{kind = ev.kind, id = ev.id}
		if ev.link != nil do e.link_sess = ev.link.sess
		if ev.kind == .Row {
			e.id, e.state, e.attached, e.active = ev.row.id, ev.row.state, ev.row.attached, ev.row.active
			e.pid, e.exit_code = ev.row.pid, ev.row.exit_code
		}
		if ev.kind == .Core_Lost do v.lost = true
		append(&v.log, e)
	}
	if !v.drain do return
	for &l in v.c.links do if l.state == .Attached && l.sess != nil do session.session_drain(l.sess)
}

view_find :: proc(v: ^View, kind: client.Client_Event_Kind, id: u32 = 0, from := 0) -> int {
	for i in from..<len(v.log) {
		e := v.log[i]
		if e.kind == kind && (id == 0 || e.id == id) do return i
	}
	return -1
}

view_wait :: proc(v: ^View, kind: client.Client_Event_Kind, id: u32 = 0, ms := 3000, from := 0) -> int {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for {
		if i := view_find(v, kind, id, from); i >= 0 do return i
		if time.tick_now()._nsec >= deadline do return -1
		view_pump(v, 5)
	}
}

// view_wait_row waits for a Row event of id matching state (and attached when given).
view_wait_row :: proc(v: ^View, id: u32, state: ipc.Session_State, attached: Maybe(bool) = nil, ms := 3000) -> int {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for {
		for e, i in v.log {
			if e.kind != .Row || e.id != id || e.state != state do continue
			if want, has := attached.?; has && e.attached != want do continue
			return i
		}
		if time.tick_now()._nsec >= deadline do return -1
		view_pump(v, 5)
	}
}

view_wait_screen :: proc(v: ^View, sess: ^session.Terminal_Session, want: string, ms := 3000) -> bool {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for {
		if contains(screen_text(sess), want) do return true
		if time.tick_now()._nsec >= deadline do return false
		view_pump(v, 5)
	}
}

view_id :: proc(v: ^View, sess: ^session.Terminal_Session) -> u32 {
	return client.client_session_id(&v.c, sess)
}

// screen_text is the visible grid, rows joined by '\n', trailing blanks cut
// (temp allocator).
screen_text :: proc(sess: ^session.Terminal_Session) -> string {
	if sess == nil do return ""
	b := strings.builder_make(context.temp_allocator)
	for row in 0..<sess.term.rows {
		line := strings.builder_make(context.temp_allocator)
		for col in 0..<sess.term.cols {
			ch := session.session_get_cell(sess, row, col).char
			strings.write_rune(&line, ch if ch >= ' ' else ' ')
		}
		strings.write_string(&b, strings.trim_right_space(strings.to_string(line)))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
