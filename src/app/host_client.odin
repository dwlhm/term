package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import posix "core:sys/posix"
import "core:time"
import ipc "../session_ipc"
import rt "../session_runtime"
import sh "../session_host"
import termgrid "../terminal"

// App_Host_Client manages the IPC connection between GUI and term-host daemon.
App_Host_Client :: struct {
	hybrid_adapter: ipc.Hybrid_Client_Adapter,
	transport:      ipc.Client_Transport_Port,
	connected:      bool,
	viewer_id:      rt.Viewer_ID,
	request_seq:    u64,
}

// resolve_helper_binary searches candidate locations for a companion helper binary
// in priority order: inside .app bundle (Helpers/), dev directory (bin/), or current directory.
resolve_helper_binary :: proc(name: string, allocator := context.temp_allocator) -> (string, bool) {
	// a. Inside .app bundle: from os.args[0], check ../Helpers/<name> relative to the binary
	if len(os.args) > 0 && len(os.args[0]) > 0 {
		bundle_helper, err := filepath.join({filepath.dir(filepath.dir(os.args[0])), "Helpers", name}, allocator)
		if err == nil && os.exists(bundle_helper) {
			return bundle_helper, true
		}
	}

	// b. In dev directory: bin/<name>
	dev_path, err_dev := filepath.join({"bin", name}, allocator)
	if err_dev == nil && os.exists(dev_path) {
		return dev_path, true
	}

	// c. In current directory: ./<name>
	cur_path := fmt.aprintf("./%s", name, allocator = allocator)
	if os.exists(cur_path) {
		return cur_path, true
	}

	return "", false
}

// monitor_client_ensure_spawned locates and launches the term-monitor companion binary
// if available, using a double-fork daemon spawn.
monitor_client_ensure_spawned :: proc(socket_path: string = "") -> bool {
	monitor_bin, found := resolve_helper_binary("term-monitor")
	if !found do return false

	c_prog := strings.clone_to_cstring(monitor_bin, context.temp_allocator)
	c_argv: [4]cstring
	if len(socket_path) > 0 {
		c_argv[0] = c_prog
		c_argv[1] = strings.clone_to_cstring("--socket", context.temp_allocator)
		c_argv[2] = strings.clone_to_cstring(socket_path, context.temp_allocator)
		c_argv[3] = nil
	} else {
		c_argv[0] = c_prog
		c_argv[1] = nil
	}

	pid := posix.fork()
	if pid == 0 {
		if posix.fork() == 0 {
			posix.close(0)
			posix.close(1)
			posix.close(2)
			posix.execvp(c_prog, raw_data(c_argv[:]))
			posix._exit(1)
		}
		posix._exit(0)
	}
	if pid > 0 {
		posix.waitpid(pid, nil, {})
		return true
	}

	return false
}

// host_client_ensure_connected establishes a connection to term-host, spawning
// the host binary on-demand if the socket is not yet active.
host_client_ensure_connected :: proc(hc: ^App_Host_Client, socket_path: string = "") -> bool {
	if hc == nil do return false
	if hc.connected do return true

	hc.transport = ipc.hybrid_client_make_port(&hc.hybrid_adapter)

	path := socket_path
	if len(path) == 0 {
		default_path, ok := ipc.resolve_default_socket_path(context.temp_allocator)
		if !ok do return false
		path = default_path
	}

	// 1. Attempt direct connection
	err := hc.transport.connect_endpoint(hc.transport.user_data, path)
	if err == .None {
		hc.connected = true
		return true
	}

	// 2. Spawn term-host binary on-demand
	host_bin, found := resolve_helper_binary("term-host")
	if found {
		c_prog := strings.clone_to_cstring(host_bin, context.temp_allocator)
		c_argv := [2]cstring{c_prog, nil}
		pid := posix.fork()
		if pid == 0 {
			if posix.fork() == 0 {
				posix.close(0)
				posix.close(1)
				posix.close(2)
				posix.execvp(c_prog, raw_data(c_argv[:]))
				posix._exit(1)
			}
			posix._exit(0)
		}
		if pid > 0 {
			posix.waitpid(pid, nil, {})
		}

		// Wait up to 500ms, retrying connect
		start := time.now()
		for time.duration_milliseconds(time.since(start)) < 500 {
			time.sleep(25 * time.Millisecond)
			if hc.transport.close_endpoint != nil {
				hc.transport.close_endpoint(hc.transport.user_data)
			}
			err = hc.transport.connect_endpoint(hc.transport.user_data, path)
			if err == .None {
				hc.connected = true
				return true
			}
		}
	}

	return false
}

_host_client_recv_frame_timeout :: proc(hc: ^App_Host_Client, timeout_ms: int = 150) -> (frame: ipc.Frame, consumed: int, status: ipc.Codec_Status) {
	if hc == nil || !hc.connected || hc.transport.recv_frame == nil do return {}, 0, .Limit_Exceeded
	start := time.now()
	for {
		f, rem, stat := hc.transport.recv_frame(hc.transport.user_data)
		if stat == .Ok {
			if f.header.kind == .Snapshot_Section || f.header.kind == .Snapshot_Begin || f.header.kind == .Snapshot_End {
				if int(time.duration_milliseconds(time.since(start))) >= timeout_ms {
					return f, rem, .Incomplete
				}
				continue
			}
			return f, rem, stat
		}
		if stat != .Incomplete do return f, rem, stat
		if int(time.duration_milliseconds(time.since(start))) >= timeout_ms {
			return f, rem, stat
		}
		time.sleep(1 * time.Millisecond)
	}
}

// host_client_detach_workspace encodes and sends a .Detach frame to term-host.
host_client_detach_workspace :: proc(hc: ^App_Host_Client, ws_id: u64) -> bool {
	if hc == nil || !hc.connected || hc.transport.send_frame == nil do return false
	hc.request_seq += 1

	detach_payload: [8]u8
	endian.unchecked_put_u64le(detach_payload[0:8], ws_id)
	frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Detach,
			request_id = hc.request_seq,
			stream_id  = ws_id,
		},
		payload = detach_payload[:],
	}
	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	if err != .None do return false

	ack_frame, _, a_stat := _host_client_recv_frame_timeout(hc)
	return a_stat == .Ok && ack_frame.header.kind == .Ack
}

// host_client_close disconnects the client without terminating sessions on term-host.
host_client_close :: proc(hc: ^App_Host_Client) {
	if hc == nil do return
	if hc.transport.close_endpoint != nil {
		hc.transport.close_endpoint(hc.transport.user_data)
	}
	hc.connected = false
}

// host_client_create_workspace requests the host to create a new workspace and initial pane.
host_client_create_workspace :: proc(hc: ^App_Host_Client, rows, cols: int, prog: string = "", cwd: string = "") -> (ws_id: u64, pane_id: u64, ok: bool) {
	if hc == nil || !hc.connected || hc.transport.send_frame == nil || hc.transport.recv_frame == nil do return 0, 0, false

	payload := make([]u8, 4 + len(prog), context.temp_allocator)
	endian.unchecked_put_u16le(payload[0:2], u16(max(0, rows)))
	endian.unchecked_put_u16le(payload[2:4], u16(max(0, cols)))
	if len(prog) > 0 {
		copy(payload[4:], transmute([]u8)prog)
	}

	hc.request_seq += 1
	frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Create,
			request_id = hc.request_seq,
			stream_id  = u64(hc.viewer_id),
		},
		payload = payload,
	}

	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	if err != .None do return 0, 0, false

	ack, _, a_stat := _host_client_recv_frame_timeout(hc)
	if a_stat != .Ok do return 0, 0, false

	if ack.header.kind == .Ack && len(ack.payload) >= 16 {
		ws_id = endian.unchecked_get_u64le(ack.payload[0:8])
		pane_id = endian.unchecked_get_u64le(ack.payload[8:16])
		return ws_id, pane_id, true
	}

	return 0, 0, false
}

// host_client_split_pane requests the host to split a workspace and spawn a new pane.
host_client_split_pane :: proc(hc: ^App_Host_Client, ws_id: u64, rows, cols: int, prog: string = "", cwd: string = "") -> (pane_id: u64, ok: bool) {
	if hc == nil || !hc.connected || hc.transport.send_frame == nil || hc.transport.recv_frame == nil do return 0, false

	payload_len := 12 + len(prog)
	payload := make([]u8, payload_len, context.temp_allocator)
	endian.unchecked_put_u64le(payload[0:8], ws_id)
	endian.unchecked_put_u16le(payload[8:10], u16(max(0, rows)))
	endian.unchecked_put_u16le(payload[10:12], u16(max(0, cols)))
	if len(prog) > 0 {
		copy(payload[12:], transmute([]u8)prog)
	}

	hc.request_seq += 1
	frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Topology_Command,
			request_id = hc.request_seq,
			stream_id  = ws_id,
		},
		payload = payload,
	}

	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	if err != .None do return 0, false

	ack, _, a_stat := _host_client_recv_frame_timeout(hc)
	if a_stat != .Ok do return 0, false

	if ack.header.kind == .Ack && len(ack.payload) >= 8 {
		pane_id = endian.unchecked_get_u64le(ack.payload[0:8])
		return pane_id, true
	}

	return 0, false
}

// host_client_attach_workspace attaches the client to an existing host workspace.
host_client_attach_workspace :: proc(hc: ^App_Host_Client, ws_id: u64, viewer_id: u64 = 0) -> bool {
	if hc == nil || !hc.connected || hc.transport.send_frame == nil || hc.transport.recv_frame == nil do return false
	hc.request_seq += 1

	v_id := viewer_id if viewer_id != 0 else u64(hc.viewer_id)
	payload: [16]u8
	endian.unchecked_put_u64le(payload[0:8], ws_id)
	endian.unchecked_put_u64le(payload[8:16], v_id)

	frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Attach_Commit,
			request_id = hc.request_seq,
			stream_id  = ws_id,
		},
		payload = payload[:],
	}

	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	if err != .None do return false

	ack_frame, _, status := _host_client_recv_frame_timeout(hc)
	return status == .Ok && ack_frame.header.kind == .Ack
}

// host_client_send_input delivers keyboard / user data to a target pane.
host_client_send_input :: proc(hc: ^App_Host_Client, pane_id: u64, data: []u8) -> bool {
	if hc == nil || !hc.connected || len(data) == 0 || hc.transport.send_frame == nil do return false

	frame := ipc.Frame{
		header = {
			major     = ipc.PROTOCOL_MAJOR,
			minor     = ipc.PROTOCOL_MINOR,
			kind      = .Input,
			stream_id = pane_id,
		},
		payload = data,
	}

	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	return err == .None
}

// host_client_send_resize informs the host that the terminal dimensions have changed.
host_client_send_resize :: proc(hc: ^App_Host_Client, ws_id: u64, pane_id: u64, rows, cols: int) -> bool {
	if hc == nil || !hc.connected || hc.transport.send_frame == nil do return false

	payload: [24]u8
	endian.unchecked_put_u64le(payload[0:8], ws_id)
	endian.unchecked_put_u64le(payload[8:16], pane_id)
	endian.unchecked_put_u32le(payload[16:20], u32(max(0, rows)))
	endian.unchecked_put_u32le(payload[20:24], u32(max(0, cols)))

	frame := ipc.Frame{
		header = {
			major     = ipc.PROTOCOL_MAJOR,
			minor     = ipc.PROTOCOL_MINOR,
			kind      = .Resize,
			stream_id = ws_id,
		},
		payload = payload[:],
	}

	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	return err == .None
}

// host_client_poll_snapshot reads and applies terminal snapshot deltas from the host.
host_client_poll_snapshot :: proc(hc: ^App_Host_Client, target_term: ^termgrid.Terminal, snap_buf: []u8, expected_ws_id: u64 = 0) -> (updated: bool, n_bytes: int) {
	if hc == nil || !hc.connected || target_term == nil || len(snap_buf) == 0 || hc.transport.read_snapshot == nil do return false, 0

	n, _, ok := hc.transport.read_snapshot(hc.transport.user_data, snap_buf)
	if !ok || n == 0 do return false, 0

	if expected_ws_id != 0 && n >= ipc.SNAPSHOT_HEADER_BYTES {
		snap_ws_id := endian.unchecked_get_u64le(snap_buf[0:8])
		if snap_ws_id != expected_ws_id {
			return false, 0
		}
	}

	_, snap_err := ipc.apply_terminal_snapshot(target_term, snap_buf[:n])
	return snap_err == .None, n
}

// host_client_list_metadata queries the host for all active workspace descriptors.
host_client_list_metadata :: proc(hc: ^App_Host_Client, allocator := context.temp_allocator) -> (entries: []sh.Workspace_Metadata_Entry, ok: bool) {
	if hc == nil || !hc.connected || hc.transport.send_frame == nil || hc.transport.recv_frame == nil do return nil, false

	hc.request_seq += 1
	frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .List_Metadata,
			request_id = hc.request_seq,
		},
	}

	_, err := hc.transport.send_frame(hc.transport.user_data, frame)
	if err != .None do return nil, false

	recv, _, r_stat := _host_client_recv_frame_timeout(hc)
	if r_stat != .Ok || recv.header.kind != .Metadata do return nil, false

	entries = sh.decode_metadata_list(recv.payload, allocator)
	return entries, true
}
