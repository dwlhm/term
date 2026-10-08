package session_host_test

import "core:encoding/endian"
import "core:fmt"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"

import ipc "../../session_ipc"
import rt "../../session_runtime"
import termgrid "../../terminal"
import sh "../"

@(private = "file")
_grid_row_to_string :: proc(g: ^termgrid.Grid, row: int, allocator := context.temp_allocator) -> string {
	builder := strings.builder_make(allocator)
	for c in 0..<g.col_count {
		cell := termgrid.grid_get_cell(g, row, c)
		if cell.content != 0 {
			strings.write_rune(&builder, rune(cell.content))
		}
	}
	return strings.to_string(builder)
}

@(test)
test_host_create_and_input_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_roundtrip_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&host)

	client_adapter: ipc.Hybrid_Client_Adapter
	client_port := ipc.hybrid_client_make_port(&client_adapter)
	c_err := client_port.connect_endpoint(client_port.user_data, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	// Step host to accept connection
	_ = sh.host_step(&host, 5)

	// Send Create frame
	create_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Create,
			request_id = 101,
		},
	}
	_, s_err := client_port.send_frame(client_port.user_data, create_frame)
	testing.expect_value(t, s_err, ipc.Transport_Error.None)

	// Step host to process Create and reply
	_ = sh.host_step(&host, 5)

	// Client receives Ack
	ack_frame, _, a_stat := client_port.recv_frame(client_port.user_data)
	testing.expect_value(t, a_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack_frame.header.kind, ipc.Message_Kind.Ack)
	testing.expect_value(t, ack_frame.header.request_id, u64(101))
	testing.expect(t, len(ack_frame.payload) >= 16, "ack payload must contain ws_id and pane_id")

	ws_id := rt.Workspace_ID(endian.unchecked_get_u64le(ack_frame.payload[0:8]))
	pane_id := rt.Pane_ID(endian.unchecked_get_u64le(ack_frame.payload[8:16]))
	testing.expect(t, ws_id != 0, "workspace ID must be non-zero")
	testing.expect(t, pane_id != 0, "pane ID must be non-zero")

	// Host sends initial full snapshot; client verifies receiving snapshot with valid dimensions
	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES, context.temp_allocator)
	snap_n := 0
	read_ok := false
	for _ in 0..<50 {
		snap_n, _, read_ok = client_port.read_snapshot(client_port.user_data, snap_buf)
		if read_ok do break
		_ = sh.host_step(&host, 5)
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, read_ok, "read_snapshot must succeed")
	testing.expect(t, snap_n > 0, "snapshot size must be positive")

	hdr, _, h_err := ipc.decode_snapshot_header(snap_buf[:snap_n])
	testing.expect_value(t, h_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, hdr.kind, ipc.Snapshot_Type.Full)
	testing.expect_value(t, hdr.workspace_id, u64(ws_id))

	client_term := new(termgrid.Terminal)
	termgrid.terminal_init(client_term, sh.DEFAULT_ROWS, sh.DEFAULT_COLS)
	defer {
		termgrid.terminal_destroy(client_term)
		free(client_term)
	}

	_, app_err := ipc.apply_terminal_snapshot(client_term, snap_buf[:snap_n])
	testing.expect_value(t, app_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, client_term.grid.row_count, sh.DEFAULT_ROWS)
	testing.expect_value(t, client_term.grid.col_count, sh.DEFAULT_COLS)

	// Client sends input echo p0_host_ok\n
	input_data := "echo p0_host_ok\n"
	input_frame := ipc.Frame{
		header = {
			major     = ipc.PROTOCOL_MAJOR,
			minor     = ipc.PROTOCOL_MINOR,
			kind      = .Input,
			stream_id = u64(pane_id),
		},
		payload = transmute([]u8)input_data,
	}
	_, in_err := client_port.send_frame(client_port.user_data, input_frame)
	testing.expect_value(t, in_err, ipc.Transport_Error.None)

	// Host steps, shell executes, host sends delta snapshot containing p0_host_ok
	found_text := false
	for _ in 0..<100 {
		_ = sh.host_step(&host, 20)
		for {
			n, _, ok := client_port.read_snapshot(client_port.user_data, snap_buf[:])
			if !ok do break
			_, _ = ipc.apply_terminal_snapshot(client_term, snap_buf[:n])
		}

		for r in 0..<client_term.grid.row_count {
			row_str := _grid_row_to_string(&client_term.grid, r, context.temp_allocator)
			if strings.contains(row_str, "p0_host_ok") {
				found_text = true
				break
			}
		}
		if found_text do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, found_text, "snapshot must contain echo output p0_host_ok")
}

@(test)
test_host_client_disconnect_survival :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_survival_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&host)

	// Client 1 connects, creates workspace running a shell
	client1_adapter: ipc.Hybrid_Client_Adapter
	client1_port := ipc.hybrid_client_make_port(&client1_adapter)
	c1_err := client1_port.connect_endpoint(client1_port.user_data, sock_path)
	testing.expect_value(t, c1_err, ipc.Transport_Error.None)

	_ = sh.host_step(&host, 5)

	create_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Create,
			request_id = 201,
		},
	}
	_, _ = client1_port.send_frame(client1_port.user_data, create_frame)
	_ = sh.host_step(&host, 5)

	ack1, _, a1_stat := client1_port.recv_frame(client1_port.user_data)
	testing.expect_value(t, a1_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack1.header.kind, ipc.Message_Kind.Ack)

	ws_id := rt.Workspace_ID(endian.unchecked_get_u64le(ack1.payload[0:8]))
	testing.expect(t, ws_id != 0, "workspace ID must be non-zero")

	// Records child PID
	actor := host.workspaces[0].panes[0]
	testing.expect(t, actor != nil, "pane actor must exist")
	child_pid := actor.pty.pid
	testing.expect(t, child_pid > 0, "child pid must be valid")
	testing.expect_value(t, posix.kill(posix.pid_t(child_pid), posix.Signal(0)), posix.result(0))

	// Client 1 closes socket abruptly (simulating Cmd+Q / GUI quit)
	client1_port.close_endpoint(client1_port.user_data)

	// Host steps: detects disconnect, detaches workspace, but child PID is STILL running
	_ = sh.host_step(&host, 10)

	testing.expect_value(t, host.workspaces[0].has_active_viewer, false)
	testing.expect_value(t, host.workspaces[0].client_slot, -1)
	testing.expect_value(t, posix.kill(posix.pid_t(child_pid), posix.Signal(0)), posix.result(0))

	// Client 2 connects, lists metadata, finds the workspace detached
	client2_adapter: ipc.Hybrid_Client_Adapter
	client2_port := ipc.hybrid_client_make_port(&client2_adapter)
	c2_err := client2_port.connect_endpoint(client2_port.user_data, sock_path)
	testing.expect_value(t, c2_err, ipc.Transport_Error.None)
	defer client2_port.close_endpoint(client2_port.user_data)

	_ = sh.host_step(&host, 5)

	list_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .List_Metadata,
			request_id = 202,
		},
	}
	_, _ = client2_port.send_frame(client2_port.user_data, list_frame)
	_ = sh.host_step(&host, 5)

	meta_f, _, m_stat := client2_port.recv_frame(client2_port.user_data)
	testing.expect_value(t, m_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, meta_f.header.kind, ipc.Message_Kind.Metadata)

	entries := sh.decode_metadata_list(meta_f.payload)
	testing.expect(t, len(entries) >= 1, "metadata entries must have at least 1 workspace")
	testing.expect_value(t, entries[0].id, ws_id)
	testing.expect_value(t, entries[0].has_active_viewer, false)

	// Client 2 sends .Attach_Commit, receives snapshot of existing session!
	attach_payload: [16]u8
	endian.unchecked_put_u64le(attach_payload[0:8], u64(ws_id))
	endian.unchecked_put_u64le(attach_payload[8:16], 777) // viewer_id = 777
	attach_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Attach_Commit,
			request_id = 203,
		},
		payload = attach_payload[:],
	}
	_, _ = client2_port.send_frame(client2_port.user_data, attach_frame)
	_ = sh.host_step(&host, 5)

	ack2, _, a2_stat := client2_port.recv_frame(client2_port.user_data)
	testing.expect_value(t, a2_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack2.header.kind, ipc.Message_Kind.Ack)

	// Client 2 receives snapshot of existing session
	snap_buf2 := make([]u8, ipc.MAX_PAYLOAD_BYTES, context.temp_allocator)
	s2_ok := false
	for _ in 0..<50 {
		_, _, s2_ok = client2_port.read_snapshot(client2_port.user_data, snap_buf2)
		if s2_ok do break
		_ = sh.host_step(&host, 5)
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, s2_ok, "client 2 must receive snapshot")

	// Verifies PID did not terminate or restart
	testing.expect_value(t, actor.pty.pid, child_pid)
	testing.expect_value(t, posix.kill(posix.pid_t(child_pid), posix.Signal(0)), posix.result(0))
}

@(test)
test_host_lease_conflict_rejection :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_lease_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&host)

	// Client 1 connects, creates and attaches to workspace A
	client1_adapter: ipc.Hybrid_Client_Adapter
	client1_port := ipc.hybrid_client_make_port(&client1_adapter)
	_ = client1_port.connect_endpoint(client1_port.user_data, sock_path)
	defer client1_port.close_endpoint(client1_port.user_data)
	_ = sh.host_step(&host, 5)

	create_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Create,
			request_id = 301,
			stream_id  = 100, // viewer_id = 100
		},
	}
	_, _ = client1_port.send_frame(client1_port.user_data, create_frame)
	_ = sh.host_step(&host, 5)

	ack1, _, _ := client1_port.recv_frame(client1_port.user_data)
	ws_id := rt.Workspace_ID(endian.unchecked_get_u64le(ack1.payload[0:8]))

	// Client 2 connects
	client2_adapter: ipc.Hybrid_Client_Adapter
	client2_port := ipc.hybrid_client_make_port(&client2_adapter)
	_ = client2_port.connect_endpoint(client2_port.user_data, sock_path)
	defer client2_port.close_endpoint(client2_port.user_data)
	_ = sh.host_step(&host, 5)

	// Client 2 tries to attach to workspace A without client 1 detaching
	attach_payload: [16]u8
	endian.unchecked_put_u64le(attach_payload[0:8], u64(ws_id))
	endian.unchecked_put_u64le(attach_payload[8:16], 200) // viewer_id = 200 != 100
	attach_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Attach_Commit,
			request_id = 302,
		},
		payload = attach_payload[:],
	}
	_, _ = client2_port.send_frame(client2_port.user_data, attach_frame)
	_ = sh.host_step(&host, 5)

	// Host rejects client 2 with .Error
	err_f, _, e_stat := client2_port.recv_frame(client2_port.user_data)
	testing.expect_value(t, e_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, err_f.header.kind, ipc.Message_Kind.Error)

	// Client 1 detaches
	detach_payload: [8]u8
	endian.unchecked_put_u64le(detach_payload[0:8], u64(ws_id))
	detach_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Detach,
			request_id = 303,
		},
		payload = detach_payload[:],
	}
	_, _ = client1_port.send_frame(client1_port.user_data, detach_frame)
	_ = sh.host_step(&host, 5)

	ack_det: ipc.Frame
	d_stat: ipc.Codec_Status = .Incomplete
	for _ in 0..<10 {
		f, _, stat := client1_port.recv_frame(client1_port.user_data)
		if stat == .Ok && f.header.kind == .Ack {
			ack_det = f
			d_stat = stat
			break
		}
	}
	testing.expect_value(t, d_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack_det.header.kind, ipc.Message_Kind.Ack)

	// Client 2 attaches -> succeeds
	_, _ = client2_port.send_frame(client2_port.user_data, attach_frame)
	_ = sh.host_step(&host, 5)

	ack2: ipc.Frame
	a2_stat: ipc.Codec_Status = .Incomplete
	for _ in 0..<10 {
		f, _, stat := client2_port.recv_frame(client2_port.user_data)
		if stat == .Ok && f.header.kind == .Ack {
			ack2 = f
			a2_stat = stat
			break
		}
	}
	testing.expect_value(t, a2_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack2.header.kind, ipc.Message_Kind.Ack)
}

@(test)
test_host_split_and_close_pane :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_split_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&host)

	ws_id, pane1, ok1 := sh.host_create_workspace(&host, 24, 80)
	testing.expect(t, ok1, "host_create_workspace must succeed")
	testing.expect(t, ws_id != 0, "workspace ID must be valid")
	testing.expect(t, pane1 != 0, "pane 1 must be valid")

	pane2, ok2 := sh.host_split_pane(&host, ws_id, pane1, .Vertical, 24, 40)
	testing.expect(t, ok2, "host_split_pane must succeed")
	testing.expect(t, pane2 != 0, "pane 2 must be valid")
	testing.expect(t, pane2 != pane1, "pane 2 must differ from pane 1")

	close_ok := sh.host_close_pane(&host, ws_id, pane2)
	testing.expect(t, close_ok, "host_close_pane must succeed")
}

@(test)
test_host_max_workspaces :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_max_ws_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path, max_ws = 3)
	testing.expect(t, init_ok, "host_init with max_ws=3 must succeed")
	defer sh.host_destroy(&host)

	testing.expect_value(t, len(host.workspaces), 3)

	ws1, _, ok1 := sh.host_create_workspace(&host, 24, 80)
	testing.expect(t, ok1)
	testing.expect(t, ws1 != 0)

	ws2, _, ok2 := sh.host_create_workspace(&host, 24, 80)
	testing.expect(t, ok2)
	testing.expect(t, ws2 != 0)

	ws3, _, ok3 := sh.host_create_workspace(&host, 24, 80)
	testing.expect(t, ok3)
	testing.expect(t, ws3 != 0)

	// 4th workspace should fail because capacity is 3
	_, _, ok4 := sh.host_create_workspace(&host, 24, 80)
	testing.expect(t, !ok4, "creating 4th workspace when max_ws=3 must fail")
}

@(test)
test_host_split_workspace_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_split_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&host)

	client_adapter: ipc.Hybrid_Client_Adapter
	client_port := ipc.hybrid_client_make_port(&client_adapter)
	c_err := client_port.connect_endpoint(client_port.user_data, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	// Step host to accept connection
	_ = sh.host_step(&host, 5)

	// Send Create frame
	create_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Create,
			request_id = 201,
		},
		payload = transmute([]u8)string("\x18\x00\x50\x00/bin/sleep 30"),
	}
	_, s_err := client_port.send_frame(client_port.user_data, create_frame)
	testing.expect_value(t, s_err, ipc.Transport_Error.None)

	_ = sh.host_step(&host, 5)

	ack_frame, _, a_stat := client_port.recv_frame(client_port.user_data)
	testing.expect_value(t, a_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack_frame.header.kind, ipc.Message_Kind.Ack)
	testing.expect(t, len(ack_frame.payload) >= 16)

	ws_id := rt.Workspace_ID(endian.unchecked_get_u64le(ack_frame.payload[0:8]))
	pane_id := rt.Pane_ID(endian.unchecked_get_u64le(ack_frame.payload[8:16]))
	testing.expect(t, ws_id != 0)
	testing.expect(t, pane_id != 0)

	// Send Topology_Command frame to split workspace
	top_payload := make([]u8, 12 + len("/bin/sleep 30"), context.temp_allocator)
	endian.unchecked_put_u64le(top_payload[0:8], u64(ws_id))
	endian.unchecked_put_u16le(top_payload[8:10], 24)
	endian.unchecked_put_u16le(top_payload[10:12], 80)
	copy(top_payload[12:], transmute([]u8)string("/bin/sleep 30"))

	top_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Topology_Command,
			request_id = 202,
			stream_id  = u64(ws_id),
		},
		payload = top_payload,
	}
	_, top_err := client_port.send_frame(client_port.user_data, top_frame)
	testing.expect_value(t, top_err, ipc.Transport_Error.None)

	_ = sh.host_step(&host, 5)

	split_ack: ipc.Frame
	s_stat: ipc.Codec_Status = .Incomplete
	for _ in 0..<20 {
		f, _, stat := client_port.recv_frame(client_port.user_data)
		if stat == .Ok && f.header.kind == .Ack {
			split_ack = f
			s_stat = stat
			break
		}
		_ = sh.host_step(&host, 5)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, s_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, split_ack.header.kind, ipc.Message_Kind.Ack)
	testing.expect(t, len(split_ack.payload) >= 8)

	new_pane_id := rt.Pane_ID(endian.unchecked_get_u64le(split_ack.payload[0:8]))
	testing.expect(t, new_pane_id != 0)
	testing.expect(t, new_pane_id != pane_id)

	// Verify workspace on host has 2 panes
	pids: [dynamic]int
	defer delete(pids)
	pane_count := 0
	for &ws in host.workspaces {
		if ws.used && ws.id == ws_id {
			for p in ws.panes {
				if p != nil {
					pane_count += 1
					append(&pids, p.pty.pid)
				}
			}
			break
		}
	}
	testing.expect_value(t, pane_count, 2)

	defer {
		for p in pids {
			if p > 1 {
				posix.kill(posix.pid_t(-p), .SIGKILL)
				posix.kill(posix.pid_t(p), .SIGKILL)
				posix.waitpid(posix.pid_t(p), nil, {})
			}
		}
	}
}

@(test)
test_host_cursor_movement_produces_snapshot :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_host_test_cursor_%d_%d.sock", pid, now)

	host: sh.Session_Host
	init_ok := sh.host_init(&host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&host)

	client_adapter: ipc.Hybrid_Client_Adapter
	client_port := ipc.hybrid_client_make_port(&client_adapter)
	c_err := client_port.connect_endpoint(client_port.user_data, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	// Step host to accept connection
	_ = sh.host_step(&host, 5)

	// Send Create frame with /bin/sleep 30 so no shell prompt interferes with cursor state
	create_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Create,
			request_id = 301,
		},
		payload = transmute([]u8)string("\x18\x00\x50\x00/bin/sleep 30"),
	}
	_, s_err := client_port.send_frame(client_port.user_data, create_frame)
	testing.expect_value(t, s_err, ipc.Transport_Error.None)

	_ = sh.host_step(&host, 5)

	ack_frame, _, a_stat := client_port.recv_frame(client_port.user_data)
	testing.expect_value(t, a_stat, ipc.Codec_Status.Ok)
	testing.expect_value(t, ack_frame.header.kind, ipc.Message_Kind.Ack)
	testing.expect(t, len(ack_frame.payload) >= 16)

	ws_id := rt.Workspace_ID(endian.unchecked_get_u64le(ack_frame.payload[0:8]))
	pane_id := rt.Pane_ID(endian.unchecked_get_u64le(ack_frame.payload[8:16]))

	// Read initial full snapshot
	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES, context.temp_allocator)
	snap_n := 0
	read_ok := false
	for _ in 0..<50 {
		snap_n, _, read_ok = client_port.read_snapshot(client_port.user_data, snap_buf)
		if read_ok do break
		_ = sh.host_step(&host, 5)
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, read_ok, "read initial snapshot must succeed")

	client_term := new(termgrid.Terminal)
	termgrid.terminal_init(client_term, sh.DEFAULT_ROWS, sh.DEFAULT_COLS)
	defer {
		termgrid.terminal_destroy(client_term)
		free(client_term)
	}

	_, app_init_err := ipc.apply_terminal_snapshot(client_term, snap_buf[:snap_n])
	testing.expect_value(t, app_init_err, ipc.Snapshot_Error.None)

	// Locate actor on host
	target_actor: ^rt.Pane_Actor = nil
	for &ws in host.workspaces {
		if ws.used && ws.id == ws_id {
			for a in ws.panes {
				if a != nil && a.pane_id == pane_id {
					target_actor = a
					break
				}
			}
			break
		}
	}
	testing.expect(t, target_actor != nil, "target actor must exist")

	defer {
		if target_actor != nil && target_actor.pty.pid > 1 {
			posix.kill(posix.pid_t(target_actor.pty.pid), .SIGKILL)
			posix.waitpid(posix.pid_t(target_actor.pty.pid), nil, {})
		}
	}

	// Drain any remaining snapshot frames
	for {
		_, _, ok := client_port.read_snapshot(client_port.user_data, snap_buf)
		if !ok do break
	}

	// Ensure actor damage is cleared and cursor is at default
	termgrid.terminal_clear_damage(&target_actor.terminal)

	// Move cursor purely without cell damage
	target_actor.terminal.cursor.col = 42

	// Step host - damage check must recognize cursor move and produce a delta snapshot
	_ = sh.host_step(&host, 5)

	snap_n = 0
	read_ok = false
	for _ in 0..<50 {
		snap_n, _, read_ok = client_port.read_snapshot(client_port.user_data, snap_buf)
		if read_ok do break
		_ = sh.host_step(&host, 5)
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, read_ok, "pure cursor movement must produce a published snapshot")
	testing.expect(t, snap_n > 0)

	_, app_err := ipc.apply_terminal_snapshot(client_term, snap_buf[:snap_n])
	testing.expect_value(t, app_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, client_term.cursor.col, 42)
}


