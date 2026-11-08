package term

// `term session wait <id> --listening [--quiet s]`: until a worker of the
// session waits in `next` (a free slot). It ends at once on what settles it:
// the session exiting or being removed (4). --quiet s gives up (3) once the
// session has neither listened nor printed anything for s seconds: a worker
// still starting or working prints, one stuck at a prompt does not.

import "core:fmt"
import "core:time"
import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"

LISTEN_POLL_MS :: 500 // LIST refreshes quiet_s, which no EVENT reports

app_wait_listening :: proc(c: ^plat_ipc.Client, t: ^Row_Track, deadline_ns: i64, quiet_s: f64) -> int {
	for time.tick_now()._nsec < deadline_ns {
		row, code := app_track_list(c, t)
		for !t.removed && code == 0 {
			switch {
			case row.request.listening > 0:
				fmt.printfln("listening %d", row.request.listening)
				return 0
			case row.state == .Exited:
				fmt.printfln("exited %d", row.exit_code)
				return 4
			case quiet_s > 0 && f64(row.quiet_s) >= quiet_s:
				fmt.eprintfln("term: session %d is quiet for %ds and not listening", t.id, row.quiet_s)
				return AGENT_EXIT_TIMEOUT
			}
			// An EVENT about the session is looked at as it comes; LIST again after LISTEN_POLL_MS.
			t.changed = false
			if !app_track_for(c, t, time.tick_now()._nsec + LISTEN_POLL_MS * 1_000_000) do return app_fail({kind = .Closed})
			if !t.changed do break
			row = t.row
		}
		if t.removed {
			fmt.println("removed")
			return 4
		}
		if code != 0 do return code
	}
	fmt.eprintln("term: wait timed out")
	return AGENT_EXIT_TIMEOUT
}

// Row_Track follows one session's notices (EVENT rows, REMOVED) while a
// wait verb asks the core. Only the row's scalar fields stay valid.
Row_Track :: struct {
	id:      u32,
	removed: bool,
	changed: bool, // an EVENT row came
	row:     proto.Session_Row,
}

// app_track is a Call_Opts.on_event: it stops the call once the session is removed.
app_track :: proc(data: rawptr, ev: plat_ipc.Client_Event) -> plat_ipc.Event_Action {
	t := (^Row_Track)(data)
	n, is_notice := ev.(plat_ipc.Notice)
	if !is_notice do return .Continue
	r := plat_ipc.wire_reader(n.body)
	switch n.kind {
	case proto.MSG_REMOVED:
		t.removed ||= plat_ipc.wr_u32(&r) == t.id
	case proto.MSG_EVENT:
		if row := proto.dec_row(&r); r.ok && row.id == t.id do t.row, t.changed = row, true
	}
	return .Stop if t.removed else .Continue
}

// app_track_for takes notices until until_ns or the session is removed;
// false = the connection is gone.
app_track_for :: proc(c: ^plat_ipc.Client, t: ^Row_Track, until_ns: i64) -> bool {
	for !t.removed {
		left := until_ns - time.tick_now()._nsec
		if left <= 0 do return true
		ev, err := plat_ipc.client_poll(c, time.Duration(left))
		if err.kind == .Timeout do return true
		if err.kind != .None do return false
		app_track(t, ev)
	}
	return true
}

// app_track_list: the session's row from a LIST. code != 0: printed (also
// "no such session"); t.removed when REMOVED came meanwhile.
app_track_list :: proc(c: ^plat_ipc.Client, t: ^Row_Track) -> (row: proto.Session_Row, code: int) {
	a, err := plat_ipc.client_call(c, proto.MSG_LIST, nil, {on_event = app_track, data = t})
	if t.removed do return {}, 0
	if err.kind != .None do return {}, app_fail(err)
	found: bool
	if row, found = _find_row(a.body, t.id); !found {
		fmt.eprintln("term: no such session")
		return {}, 1
	}
	return row, 0
}
