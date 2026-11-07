package term

// `term session wait <id> --listening [--quiet s]`: until a worker of the
// session waits in `next` (a free slot). It ends at once on what settles it:
// the session exiting or being removed (4). --quiet s gives up (3) once the
// session has neither listened nor printed anything for s seconds: a worker
// still starting or working prints, one stuck at a prompt does not.

import "core:fmt"
import "core:time"
import client_feat "../../features/session_client"
import plat_ipc "../../platform/ipc"

LISTEN_POLL_MS :: 500 // LIST refreshes quiet_s, which no EVENT reports

app_wait_listening :: proc(conn: ^plat_ipc.Stream_Conn, id: u32, deadline_ns: i64, quiet_s: f64) -> int {
	plat_ipc.stream_send(conn, plat_ipc.MSG_LIST, 0)
	for time.tick_now()._nsec < deadline_ns {
		f, got := client_feat.client_wait_frame(conn, LISTEN_POLL_MS)
		if !got {
			if conn.err != .None do return 1
			plat_ipc.stream_send(conn, plat_ipc.MSG_LIST, 0)
			continue
		}
		if f.kind == plat_ipc.MSG_REMOVED && _removed_id(f.payload) == id {
			fmt.println("removed")
			return 4
		}
		if f.kind != plat_ipc.MSG_SESSIONS && f.kind != plat_ipc.MSG_EVENT do continue
		row: plat_ipc.Session_Row
		found: bool
		if f.kind == plat_ipc.MSG_SESSIONS do row, found = _find_row(f.payload, id)
		else do row, found = _event_row(f.payload, id)
		if !found {
			if f.kind == plat_ipc.MSG_EVENT do continue
			fmt.eprintln("term: no such session")
			return 1
		}
		switch {
		case row.request.listening > 0:
			fmt.printfln("listening %d", row.request.listening)
			return 0
		case row.state == .Exited:
			fmt.printfln("exited %d", row.exit_code)
			return 4
		case quiet_s > 0 && f64(row.quiet_s) >= quiet_s:
			fmt.eprintfln("term: session %d is quiet for %ds and not listening", id, row.quiet_s)
			return AGENT_EXIT_TIMEOUT
		}
	}
	fmt.eprintln("term: wait timed out")
	return AGENT_EXIT_TIMEOUT
}

// _event_row decodes an EVENT (one row) when it is about id.
@(private = "file")
_event_row :: proc(payload: []u8, id: u32) -> (row: plat_ipc.Session_Row, found: bool) {
	r := plat_ipc.wire_reader(payload)
	row = plat_ipc.dec_row(&r)
	return row, r.ok && row.id == id
}
