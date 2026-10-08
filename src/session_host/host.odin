package session_host

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"
import "core:time"

import ipc "../session_ipc"
import rt "../session_runtime"
import pty "../platform/pty"
import termgrid "../terminal"

MAX_WORKSPACES   :: 32
MAX_PANES_PER_WS :: rt.TOPOLOGY_NODE_CAPACITY
DEFAULT_ROWS     :: 24
DEFAULT_COLS     :: 80

Client_Subscription :: struct {
	ws_id:               rt.Workspace_ID,
	pane_id:             rt.Pane_ID,
	viewer_id:           rt.Viewer_ID,
	is_writer:           bool,
	needs_full_snapshot: bool,
	last_snapshot_rev:   u64,
}

Workspace_State :: struct {
	used:              bool,
	id:                rt.Workspace_ID,
	topology:          rt.Workspace_Topology,
	panes:             [MAX_PANES_PER_WS]^rt.Pane_Actor,
	title:             string,
	cwd:               string,
	created_at_ns:     i64,
	active_viewer:     rt.Viewer_ID,
	has_active_viewer: bool,
	client_slot:       int, // -1 if detached
	snapshot_rev:      u64,
}

Session_Host :: struct {
	hybrid_adapter:  ipc.Hybrid_Host_Adapter,
	transport:       ipc.Host_Transport_Port,
	workspaces:      []Workspace_State,
	workspace_count: int,
	next_ws_id:      u64,
	next_pane_id:    u64,
	generation:      rt.Host_Generation,
	running:         bool,
	allocator:       runtime.Allocator,
	client_subs:     [ipc.MAX_IPC_CLIENTS]Client_Subscription,
	snap_buf:        []u8,
}

Workspace_Metadata_Entry :: struct {
	id:                rt.Workspace_ID,
	has_active_viewer: bool,
	active_viewer:     rt.Viewer_ID,
	created_at_ns:     i64,
	snapshot_rev:      u64,
	pane_count:        int,
	title:             string,
}

host_init :: proc(h: ^Session_Host, socket_path: string = "", max_ws: int = 32, allocator := context.allocator) -> bool {
	if h == nil do return false
	h^ = Session_Host{}
	h.allocator = allocator
	h.generation = rt.Host_Generation{u64(posix.getpid()), u64(time.to_unix_nanoseconds(time.now()))}
	h.next_ws_id = 1
	h.next_pane_id = 1
	h.running = true

	capacity := max(1, min(max_ws, 256))
	h.workspaces = make([]Workspace_State, capacity, allocator)
	for &ws in h.workspaces {
		ws.client_slot = -1
	}

	h.snap_buf = make([]u8, ipc.MAX_FRAME_BYTES, allocator)

	h.transport = ipc.hybrid_host_make_port(&h.hybrid_adapter)

	resolved_path := socket_path
	allocated_path := false
	if len(resolved_path) == 0 {
		default_path, ok := ipc.resolve_default_socket_path(allocator)
		if !ok {
			delete(h.snap_buf, allocator)
			h.snap_buf = nil
			delete(h.workspaces, allocator)
			h.workspaces = nil
			return false
		}
		resolved_path = default_path
		allocated_path = true
	}
	defer if allocated_path do delete(resolved_path, allocator)

	if !h.transport.listen_endpoint(h.transport.user_data, resolved_path) {
		delete(h.snap_buf, allocator)
		h.snap_buf = nil
		delete(h.workspaces, allocator)
		h.workspaces = nil
		return false
	}

	return true
}

host_create_workspace :: proc(
	h: ^Session_Host,
	rows: int = DEFAULT_ROWS,
	cols: int = DEFAULT_COLS,
	prog: string = "",
	argv: []string = {},
	cwd: string = "",
) -> (ws_id: rt.Workspace_ID, pane_id: rt.Pane_ID, ok: bool) {
	if h == nil || h.workspace_count >= len(h.workspaces) do return 0, 0, false

	ws_slot := -1
	for &ws, i in h.workspaces {
		if !ws.used {
			ws_slot = i
			break
		}
	}
	if ws_slot == -1 do return 0, 0, false

	ws_id = rt.Workspace_ID(h.next_ws_id)
	h.next_ws_id += 1
	pane_id = rt.Pane_ID(h.next_pane_id)
	h.next_pane_id += 1
	incarnation := rt.Pane_Incarnation(1)

	ws := &h.workspaces[ws_slot]
	ws^ = Workspace_State{
		used          = true,
		id            = ws_id,
		client_slot   = -1,
		created_at_ns = time.to_unix_nanoseconds(time.now()),
		title         = strings.clone("Workspace", h.allocator),
		cwd           = strings.clone(cwd, h.allocator) if len(cwd) > 0 else "",
	}

	top_res := rt.topology_create_leaf(&ws.topology, ws_id, pane_id, incarnation)
	if top_res != .Applied {
		if len(ws.title) > 0 do delete(ws.title, h.allocator)
		if len(ws.cwd) > 0 do delete(ws.cwd, h.allocator)
		ws^ = {}
		return 0, 0, false
	}

	effective_rows := rows if rows > 0 else DEFAULT_ROWS
	effective_cols := cols if cols > 0 else DEFAULT_COLS

	actor := new(rt.Pane_Actor, h.allocator)
	rt.actor_init(actor, pane_id, incarnation, ws_id, effective_rows, effective_cols, h.allocator)

	effective_prog := prog
	effective_argv := argv
	split_argv: [dynamic]string
	defer delete(split_argv)
	if len(argv) == 0 && strings.contains(prog, " ") {
		parts := strings.split(prog, " ", context.temp_allocator)
		if len(parts) > 0 {
			effective_prog = parts[0]
			for p in parts[1:] {
				if len(p) > 0 {
					append(&split_argv, p)
				}
			}
			effective_argv = split_argv[:]
		}
	}
	if len(effective_prog) == 0 {
		if env_shell, has_shell := os.lookup_env("SHELL", context.temp_allocator); has_shell && len(env_shell) > 0 {
			effective_prog = env_shell
		} else if os.exists("/bin/zsh") {
			effective_prog = "/bin/zsh"
		} else {
			effective_prog = "/bin/sh"
		}
		if len(effective_argv) == 0 {
			if strings.contains(effective_prog, "zsh") {
				effective_argv = []string{"--no-rcs"}
			} else if strings.contains(effective_prog, "bash") {
				effective_argv = []string{"--norc", "--noprofile"}
			}
		}
	}

	spawn_ok := rt.actor_spawn(actor, effective_prog, effective_argv, ws.cwd)
	if !spawn_ok {
		rt.actor_destroy(actor)
		free(actor, h.allocator)
		if len(ws.title) > 0 do delete(ws.title, h.allocator)
		if len(ws.cwd) > 0 do delete(ws.cwd, h.allocator)
		ws^ = {}
		return 0, 0, false
	}

	ws.panes[0] = actor
	h.workspace_count += 1
	return ws_id, pane_id, true
}

host_split_pane :: proc(
	h: ^Session_Host,
	ws_id: rt.Workspace_ID,
	target_pane: rt.Pane_ID,
	orientation: rt.Orientation,
	rows: int,
	cols: int,
	prog: string = "",
) -> (new_pane_id: rt.Pane_ID, ok: bool) {
	if h == nil do return 0, false

	ws_idx := -1
	for &ws, i in h.workspaces {
		if ws.used && ws.id == ws_id {
			ws_idx = i
			break
		}
	}
	if ws_idx == -1 do return 0, false
	ws := &h.workspaces[ws_idx]

	pane_slot := -1
	for p, i in ws.panes {
		if p == nil {
			pane_slot = i
			break
		}
	}
	if pane_slot == -1 do return 0, false

	new_pane_id = rt.Pane_ID(h.next_pane_id)
	h.next_pane_id += 1
	incarnation := rt.Pane_Incarnation(1)

	res := rt.topology_split(&ws.topology, target_pane, new_pane_id, incarnation, orientation)
	if res != .Applied do return 0, false

	effective_rows := rows if rows > 0 else DEFAULT_ROWS
	effective_cols := cols if cols > 0 else DEFAULT_COLS

	actor := new(rt.Pane_Actor, h.allocator)
	rt.actor_init(actor, new_pane_id, incarnation, ws_id, effective_rows, effective_cols, h.allocator)

	effective_prog := prog
	argv: []string = {}
	if len(effective_prog) == 0 {
		if env_shell, has_shell := os.lookup_env("SHELL", context.temp_allocator); has_shell && len(env_shell) > 0 {
			effective_prog = env_shell
		} else if os.exists("/bin/zsh") {
			effective_prog = "/bin/zsh"
		} else {
			effective_prog = "/bin/sh"
		}
	}
	if len(argv) == 0 {
		argv = pty.shell_resolve_argv(effective_prog, .Interactive)
	}

	if !rt.actor_spawn(actor, effective_prog, argv, ws.cwd) {
		rt.actor_destroy(actor)
		free(actor, h.allocator)
		_ = rt.topology_remove(&ws.topology, new_pane_id)
		return 0, false
	}

	ws.panes[pane_slot] = actor
	return new_pane_id, true
}

host_split_workspace :: proc(
	h: ^Session_Host,
	ws_id: rt.Workspace_ID,
	rows, cols: int,
	prog: string = "",
	cwd: string = "",
) -> (pane_id: rt.Pane_ID, ok: bool) {
	if h == nil do return 0, false

	ws_idx := -1
	for &ws, i in h.workspaces {
		if ws.used && ws.id == ws_id {
			ws_idx = i
			break
		}
	}
	if ws_idx == -1 do return 0, false
	ws := &h.workspaces[ws_idx]

	pane_count := 0
	for p in ws.panes {
		if p != nil do pane_count += 1
	}
	if pane_count >= MAX_PANES_PER_WS do return 0, false

	p_id := rt.Pane_ID(h.next_pane_id)
	h.next_pane_id += 1

	shell_prog := prog
	if len(shell_prog) == 0 {
		if len(h.workspaces[ws_idx].cwd) > 0 && !os.is_dir(h.workspaces[ws_idx].cwd) {
			shell_prog = h.workspaces[ws_idx].cwd
		} else if env_shell, has_shell := os.lookup_env("SHELL", context.temp_allocator); has_shell && len(env_shell) > 0 {
			shell_prog = env_shell
		} else if os.exists("/bin/zsh") {
			shell_prog = "/bin/zsh"
		} else {
			shell_prog = "/bin/sh"
		}
	}

	actor := new(rt.Pane_Actor, h.allocator)
	actor.pane_id = p_id
	actor.workspace_id = ws_id
	actor.allocator = h.allocator
	actor.liveness = .VerifiedLive

	effective_cwd := cwd if len(cwd) > 0 else h.workspaces[ws_idx].cwd
	spawn_ok := rt.actor_start(actor, rows, cols, shell_prog, nil, effective_cwd, .Interactive)
	if !spawn_ok {
		rt.actor_destroy(actor)
		free(actor, h.allocator)
		return 0, false
	}

	for &p in ws.panes {
		if p == nil {
			p = actor
			break
		}
	}
	return p_id, true
}

host_close_pane :: proc(h: ^Session_Host, ws_id: rt.Workspace_ID, target_pane: rt.Pane_ID) -> bool {
	if h == nil do return false

	ws_idx := -1
	for &ws, i in h.workspaces {
		if ws.used && ws.id == ws_id {
			ws_idx = i
			break
		}
	}
	if ws_idx == -1 do return false
	ws := &h.workspaces[ws_idx]

	pane_slot := -1
	for p, i in ws.panes {
		if p != nil && p.pane_id == target_pane {
			pane_slot = i
			break
		}
	}
	if pane_slot == -1 do return false

	actor := ws.panes[pane_slot]
	rt.actor_destroy(actor)
	free(actor, h.allocator)
	ws.panes[pane_slot] = nil

	_ = rt.topology_remove(&ws.topology, target_pane)

	active_panes := 0
	for p in ws.panes {
		if p != nil do active_panes += 1
	}
	if active_panes == 0 {
		if len(ws.title) > 0 do delete(ws.title, h.allocator)
		if len(ws.cwd) > 0 do delete(ws.cwd, h.allocator)
		ws^ = {}
		h.workspace_count -= 1
	}

	return true
}

host_detach_workspace :: proc(h: ^Session_Host, ws_id: rt.Workspace_ID) -> bool {
	if h == nil do return false

	ws_idx := -1
	for &ws, i in h.workspaces {
		if ws.used && ws.id == ws_id {
			ws_idx = i
			break
		}
	}
	if ws_idx == -1 do return false
	ws := &h.workspaces[ws_idx]

	ws.has_active_viewer = false
	ws.active_viewer = 0
	ws.client_slot = -1

	for &sub in h.client_subs {
		if sub.ws_id == ws_id {
			sub = {}
		}
	}

	return true
}

host_attach_workspace :: proc(h: ^Session_Host, ws_id: rt.Workspace_ID, client_slot: int, viewer_id: rt.Viewer_ID) -> bool {
	if h == nil || client_slot < 0 || client_slot >= ipc.MAX_IPC_CLIENTS do return false

	ws_idx := -1
	for &ws, i in h.workspaces {
		if ws.used && ws.id == ws_id {
			ws_idx = i
			break
		}
	}
	if ws_idx == -1 do return false
	ws := &h.workspaces[ws_idx]

	if ws.has_active_viewer && ws.active_viewer != viewer_id {
		return false
	}

	ws.has_active_viewer = true
	ws.active_viewer = viewer_id
	ws.client_slot = client_slot

	target_pane := ws.topology.focused
	if target_pane == 0 {
		for p in ws.panes {
			if p != nil {
				target_pane = p.pane_id
				break
			}
		}
	}

	h.client_subs[client_slot] = Client_Subscription{
		ws_id               = ws_id,
		pane_id             = target_pane,
		viewer_id           = viewer_id,
		is_writer           = true,
		needs_full_snapshot = true,
		last_snapshot_rev   = ws.snapshot_rev,
	}

	return true
}

decode_metadata_list :: proc(payload: []u8, allocator := context.temp_allocator) -> []Workspace_Metadata_Entry {
	if len(payload) < 2 do return nil
	count := int(endian.unchecked_get_u16le(payload[0:2]))
	if count == 0 do return nil

	entries := make([]Workspace_Metadata_Entry, count, allocator)
	offset := 2
	for i in 0..<count {
		if offset + 37 > len(payload) do break
		entries[i].id = rt.Workspace_ID(endian.unchecked_get_u64le(payload[offset:offset+8]))
		offset += 8
		entries[i].has_active_viewer = payload[offset] != 0
		offset += 1
		entries[i].active_viewer = rt.Viewer_ID(endian.unchecked_get_u64le(payload[offset:offset+8]))
		offset += 8
		entries[i].created_at_ns = i64(endian.unchecked_get_u64le(payload[offset:offset+8]))
		offset += 8
		entries[i].snapshot_rev = endian.unchecked_get_u64le(payload[offset:offset+8])
		offset += 8
		entries[i].pane_count = int(endian.unchecked_get_u16le(payload[offset:offset+2]))
		offset += 2
		t_len := int(endian.unchecked_get_u16le(payload[offset:offset+2]))
		offset += 2
		if t_len > 0 && offset + t_len <= len(payload) {
			entries[i].title = strings.clone(string(payload[offset:offset+t_len]), allocator)
			offset += t_len
		}
	}
	return entries
}

host_handle_frame :: proc(h: ^Session_Host, slot: int, frame: ipc.Frame) {
	if h == nil || slot < 0 || slot >= ipc.MAX_IPC_CLIENTS do return

	#partial switch frame.header.kind {
	case .Hello:
		payload: [20]u8
		endian.unchecked_put_u64le(payload[0:8], h.generation[0])
		endian.unchecked_put_u64le(payload[8:16], h.generation[1])
		endian.unchecked_put_u16le(payload[16:18], ipc.PROTOCOL_MAJOR)
		endian.unchecked_put_u16le(payload[18:20], ipc.PROTOCOL_MINOR)

		ack_frame := ipc.Frame{
			header = {
				major      = ipc.PROTOCOL_MAJOR,
				minor      = ipc.PROTOCOL_MINOR,
				kind       = .Ack,
				request_id = frame.header.request_id,
				stream_id  = frame.header.stream_id,
			},
			payload = payload[:],
		}
		_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)

	case .List_Metadata:
		meta_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES, context.temp_allocator)
		offset := 2
		used_count := u16(0)

		for &ws in h.workspaces {
			if !ws.used do continue
			used_count += 1
			pane_count := u16(0)
			for p in ws.panes {
				if p != nil do pane_count += 1
			}

			if offset + 37 > len(meta_buf) do break

			endian.unchecked_put_u64le(meta_buf[offset:offset+8], u64(ws.id))
			offset += 8
			meta_buf[offset] = 1 if ws.has_active_viewer else 0
			offset += 1
			endian.unchecked_put_u64le(meta_buf[offset:offset+8], u64(ws.active_viewer))
			offset += 8
			endian.unchecked_put_u64le(meta_buf[offset:offset+8], u64(ws.created_at_ns))
			offset += 8
			endian.unchecked_put_u64le(meta_buf[offset:offset+8], ws.snapshot_rev)
			offset += 8
			endian.unchecked_put_u16le(meta_buf[offset:offset+2], pane_count)
			offset += 2

			title_bytes := transmute([]u8)ws.title
			t_len := min(len(title_bytes), 255)
			endian.unchecked_put_u16le(meta_buf[offset:offset+2], u16(t_len))
			offset += 2
			if t_len > 0 && offset + t_len <= len(meta_buf) {
				copy(meta_buf[offset:offset+t_len], title_bytes[:t_len])
				offset += t_len
			}
		}
		endian.unchecked_put_u16le(meta_buf[0:2], used_count)

		meta_frame := ipc.Frame{
			header = {
				major      = ipc.PROTOCOL_MAJOR,
				minor      = ipc.PROTOCOL_MINOR,
				kind       = .Metadata,
				request_id = frame.header.request_id,
				stream_id  = frame.header.stream_id,
			},
			payload = meta_buf[:offset],
		}
		_, _ = h.transport.send_frame(h.transport.user_data, slot, meta_frame)

	case .Create:
		rows := DEFAULT_ROWS
		cols := DEFAULT_COLS
		prog := ""
		if len(frame.payload) >= 4 {
			r := int(endian.unchecked_get_u16le(frame.payload[0:2]))
			c := int(endian.unchecked_get_u16le(frame.payload[2:4]))
			if r > 0 do rows = r
			if c > 0 do cols = c
			if len(frame.payload) > 4 {
				prog = string(frame.payload[4:])
			}
		}

		ws_id, pane_id, ok := host_create_workspace(h, rows, cols, prog)
		if !ok {
			err_frame := ipc.Frame{
				header = {
					major      = ipc.PROTOCOL_MAJOR,
					minor      = ipc.PROTOCOL_MINOR,
					kind       = .Error,
					request_id = frame.header.request_id,
					stream_id  = frame.header.stream_id,
				},
				payload = transmute([]u8)string("Failed to create workspace"),
			}
			_, _ = h.transport.send_frame(h.transport.user_data, slot, err_frame)
			return
		}

		viewer_id := rt.Viewer_ID(frame.header.stream_id if frame.header.stream_id != 0 else u64(slot + 1))
		_ = host_attach_workspace(h, ws_id, slot, viewer_id)

		ack_payload: [16]u8
		endian.unchecked_put_u64le(ack_payload[0:8], u64(ws_id))
		endian.unchecked_put_u64le(ack_payload[8:16], u64(pane_id))
		ack_frame := ipc.Frame{
			header = {
				major      = ipc.PROTOCOL_MAJOR,
				minor      = ipc.PROTOCOL_MINOR,
				kind       = .Ack,
				request_id = frame.header.request_id,
				stream_id  = u64(ws_id),
			},
			payload = ack_payload[:],
		}
		_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)

	case .Attach_Reserve, .Attach_Commit:
		ws_id: rt.Workspace_ID = 0
		viewer_id: rt.Viewer_ID = 0
		if len(frame.payload) >= 16 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
			viewer_id = rt.Viewer_ID(endian.unchecked_get_u64le(frame.payload[8:16]))
		} else if len(frame.payload) >= 8 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
			viewer_id = rt.Viewer_ID(frame.header.stream_id if frame.header.stream_id != 0 else u64(slot + 1))
		} else if frame.header.stream_id != 0 {
			ws_id = rt.Workspace_ID(frame.header.stream_id)
			viewer_id = rt.Viewer_ID(u64(slot + 1))
		}
		if viewer_id == 0 {
			viewer_id = rt.Viewer_ID(u64(slot + 1))
		}

		if host_attach_workspace(h, ws_id, slot, viewer_id) {
			ack_payload: [16]u8
			endian.unchecked_put_u64le(ack_payload[0:8], u64(ws_id))
			endian.unchecked_put_u64le(ack_payload[8:16], u64(viewer_id))
			ack_frame := ipc.Frame{
				header = {
					major      = ipc.PROTOCOL_MAJOR,
					minor      = ipc.PROTOCOL_MINOR,
					kind       = .Ack,
					request_id = frame.header.request_id,
					stream_id  = u64(ws_id),
				},
				payload = ack_payload[:],
			}
			_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)
		} else {
			err_frame := ipc.Frame{
				header = {
					major      = ipc.PROTOCOL_MAJOR,
					minor      = ipc.PROTOCOL_MINOR,
					kind       = .Error,
					request_id = frame.header.request_id,
					stream_id  = u64(ws_id),
				},
				payload = transmute([]u8)string("Attach failed: lease conflict or invalid workspace"),
			}
			_, _ = h.transport.send_frame(h.transport.user_data, slot, err_frame)
		}

	case .Detach:
		ws_id: rt.Workspace_ID = 0
		if len(frame.payload) >= 8 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
		} else if h.client_subs[slot].ws_id != 0 {
			ws_id = h.client_subs[slot].ws_id
		} else {
			ws_id = rt.Workspace_ID(frame.header.stream_id)
		}

		_ = host_detach_workspace(h, ws_id)
		ack_frame := ipc.Frame{
			header = {
				major      = ipc.PROTOCOL_MAJOR,
				minor      = ipc.PROTOCOL_MINOR,
				kind       = .Ack,
				request_id = frame.header.request_id,
				stream_id  = u64(ws_id),
			},
			payload = transmute([]u8)string("detached"),
		}
		_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)

	case .Input:
		sub := &h.client_subs[slot]
		if sub.ws_id == 0 || !sub.is_writer do return

		ws_idx := -1
		for &ws, i in h.workspaces {
			if ws.used && ws.id == sub.ws_id {
				ws_idx = i
				break
			}
		}
		if ws_idx == -1 do return
		ws := &h.workspaces[ws_idx]
		if !ws.has_active_viewer || ws.client_slot != slot || ws.active_viewer != sub.viewer_id {
			return
		}

		target_pane := sub.pane_id
		if frame.header.stream_id != 0 {
			target_pane = rt.Pane_ID(frame.header.stream_id)
		}

		var_actor: ^rt.Pane_Actor = nil
		for a in ws.panes {
			if a != nil && a.pane_id == target_pane {
				var_actor = a
				break
			}
		}
		if var_actor == nil {
			for a in ws.panes {
				if a != nil {
					var_actor = a
					break
				}
			}
		}
		if var_actor != nil && len(frame.payload) > 0 {
			_ = rt.actor_write_input(var_actor, frame.payload)
		}

	case .Resize:
		ws_id := h.client_subs[slot].ws_id
		pane_id := h.client_subs[slot].pane_id
		rows := 0
		cols := 0

		if len(frame.payload) >= 24 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
			pane_id = rt.Pane_ID(endian.unchecked_get_u64le(frame.payload[8:16]))
			rows = int(endian.unchecked_get_u32le(frame.payload[16:20]))
			cols = int(endian.unchecked_get_u32le(frame.payload[20:24]))
		} else if len(frame.payload) >= 20 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
			pane_id = rt.Pane_ID(endian.unchecked_get_u64le(frame.payload[8:16]))
			rows = int(endian.unchecked_get_u16le(frame.payload[16:18]))
			cols = int(endian.unchecked_get_u16le(frame.payload[18:20]))
		} else if len(frame.payload) >= 4 {
			rows = int(endian.unchecked_get_u16le(frame.payload[0:2]))
			cols = int(endian.unchecked_get_u16le(frame.payload[2:4]))
		}

		if rows > 0 && cols > 0 && ws_id != 0 {
			for &ws in h.workspaces {
				if ws.used && ws.id == ws_id {
					for a in ws.panes {
						if a != nil && (pane_id == 0 || a.pane_id == pane_id) {
							termgrid.terminal_resize(&a.terminal, rows, cols, a.allocator)
							pty.pty_set_winsize(&a.pty, rows, cols, 0, 0)
						}
					}
					h.client_subs[slot].needs_full_snapshot = true
					break
				}
			}
		}

		ack_frame := ipc.Frame{
			header = {
				major      = ipc.PROTOCOL_MAJOR,
				minor      = ipc.PROTOCOL_MINOR,
				kind       = .Ack,
				request_id = frame.header.request_id,
				stream_id  = u64(ws_id),
			},
			payload = transmute([]u8)string("resized"),
		}
		_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)

	case .Close_Commit:
		ws_id := h.client_subs[slot].ws_id
		pane_id := rt.Pane_ID(0)
		if len(frame.payload) >= 16 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
			pane_id = rt.Pane_ID(endian.unchecked_get_u64le(frame.payload[8:16]))
		} else if len(frame.payload) >= 8 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
		}

		if pane_id != 0 {
			_ = host_close_pane(h, ws_id, pane_id)
		} else if ws_id != 0 {
			for &ws in h.workspaces {
				if ws.used && ws.id == ws_id {
					for &a in ws.panes {
						if a != nil {
							rt.actor_destroy(a)
							free(a, h.allocator)
							a = nil
						}
					}
					if len(ws.title) > 0 do delete(ws.title, h.allocator)
					if len(ws.cwd) > 0 do delete(ws.cwd, h.allocator)
					ws = {}
					h.workspace_count -= 1
					break
				}
			}
		}

		ack_frame := ipc.Frame{
			header = {
				major      = ipc.PROTOCOL_MAJOR,
				minor      = ipc.PROTOCOL_MINOR,
				kind       = .Ack,
				request_id = frame.header.request_id,
				stream_id  = u64(ws_id),
			},
			payload = transmute([]u8)string("closed"),
		}
		_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)

	case .Topology_Command:
		ws_id: rt.Workspace_ID = 0
		rows: u16 = 0
		cols: u16 = 0
		prog := ""
		if len(frame.payload) >= 12 {
			ws_id = rt.Workspace_ID(endian.unchecked_get_u64le(frame.payload[0:8]))
			rows = endian.unchecked_get_u16le(frame.payload[8:10])
			cols = endian.unchecked_get_u16le(frame.payload[10:12])
			if len(frame.payload) > 12 {
				prog = string(frame.payload[12:])
			}
		} else if frame.header.stream_id != 0 {
			ws_id = rt.Workspace_ID(frame.header.stream_id)
		}

		pane_id, ok := host_split_workspace(h, ws_id, int(rows), int(cols), prog)
		if ok {
			ack_payload: [8]u8
			endian.unchecked_put_u64le(ack_payload[0:8], u64(pane_id))
			ack_frame := ipc.Frame{
				header = {
					major      = ipc.PROTOCOL_MAJOR,
					minor      = ipc.PROTOCOL_MINOR,
					kind       = .Ack,
					request_id = frame.header.request_id,
					stream_id  = u64(ws_id),
				},
				payload = ack_payload[:],
			}
			_, _ = h.transport.send_frame(h.transport.user_data, slot, ack_frame)
		} else {
			err_frame := ipc.Frame{
				header = {
					major      = ipc.PROTOCOL_MAJOR,
					minor      = ipc.PROTOCOL_MINOR,
					kind       = .Error,
					request_id = frame.header.request_id,
					stream_id  = u64(ws_id),
				},
				payload = transmute([]u8)string("Failed to split workspace"),
			}
			_, _ = h.transport.send_frame(h.transport.user_data, slot, err_frame)
		}

	case .Resync:
		h.client_subs[slot].needs_full_snapshot = true

	case:
		// Unknown or unhandled message kind
	}
}

@(private = "file")
_host_handle_client_disconnect :: proc(h: ^Session_Host, slot: int) {
	if h.transport.disconnect_client != nil {
		h.transport.disconnect_client(h.transport.user_data, slot)
	}
	sub := &h.client_subs[slot]
	if sub.ws_id != 0 {
		_ = host_detach_workspace(h, sub.ws_id)
	}
	sub^ = {}
	for &ws in h.workspaces {
		if ws.used && ws.client_slot == slot {
			_ = host_detach_workspace(h, ws.id)
		}
	}
}

@(private="file")
_actor_has_pending_damage :: proc(a: ^rt.Pane_Actor) -> bool {
	if a == nil do return false
	// Cursor movement, visibility toggle, style change, or keypad mode changes
	// must be reported even if no grid cells were dirtied (e.g. arrow keys, backspace).
	if a.terminal.cursor.row != a.last_cursor_row ||
	   a.terminal.cursor.col != a.last_cursor_col ||
	   a.terminal.cursor.visible != a.last_cursor_visible ||
	   a.terminal.cursor.style != a.last_cursor_style ||
	   a.terminal.app_cursor_keys != a.last_app_cursor_keys {
		return true
	}
	for r in 0 ..< a.terminal.damage.row_count {
		if r < len(a.terminal.damage.dirty_rows) {
			dr := a.terminal.damage.dirty_rows[r]
			if dr.full || dr.span_count > 0 do return true
		}
	}
	return len(a.terminal.damage.scroll_ops) > 0
}

host_step :: proc(h: ^Session_Host, timeout_ms: int = 10) -> bool {
	if h == nil || !h.running do return false

	// 1. Accept new client connections
	if h.transport.accept_client != nil {
		for {
			slot, a_ok := h.transport.accept_client(h.transport.user_data)
			if !a_ok || slot < 0 do break
			h.client_subs[slot] = {}
		}
	}

	// 2. Poll & receive frames from active client slots
	if h.transport.recv_frame != nil {
		for slot in 0..<ipc.MAX_IPC_CLIENTS {
			if !h.hybrid_adapter.uds.server.clients[slot].active do continue

			for h.hybrid_adapter.uds.server.clients[slot].active {
				if h.hybrid_adapter.uds.server.clients[slot].read_len < ipc.FRAME_HEADER_BYTES {
					pfd := posix.pollfd{fd = h.hybrid_adapter.uds.server.clients[slot].fd, events = {.IN, .HUP, .ERR}}
					pres := posix.poll(&pfd, 1, 0)
					if pres <= 0 do break
					if (.HUP in pfd.revents || .ERR in pfd.revents) && !(.IN in pfd.revents) {
						_host_handle_client_disconnect(h, slot)
						break
					}
				}

				frame, _, status := h.transport.recv_frame(h.transport.user_data, slot)
				if status == .Ok {
					host_handle_frame(h, slot, frame)
				} else if !h.hybrid_adapter.uds.server.clients[slot].active {
					_host_handle_client_disconnect(h, slot)
					break
				} else {
					break
				}
			}
		}
	}

	// 3. Drain PTY for all active pane actors
	drain_buf: [16384]u8
	for &ws in h.workspaces {
		if !ws.used do continue
		for actor in ws.panes {
			if actor == nil do continue
			for {
				n, eof := rt.actor_drain_pty(actor, drain_buf[:])
				if n <= 0 || eof do break
			}
		}
	}

	// 4. Snapshot streaming to attached clients
	if h.transport.publish_snapshot != nil {
		for slot in 0..<ipc.MAX_IPC_CLIENTS {
			if !h.hybrid_adapter.uds.server.clients[slot].active do continue
			sub := &h.client_subs[slot]
			if sub.ws_id == 0 do continue

			ws_idx := -1
			for &ws, i in h.workspaces {
				if ws.used && ws.id == sub.ws_id {
					ws_idx = i
					break
				}
			}
			if ws_idx == -1 do continue
			ws := &h.workspaces[ws_idx]
			if !ws.has_active_viewer || ws.client_slot != slot do continue

			for var_actor in ws.panes {
				if var_actor == nil do continue
				has_damage := _actor_has_pending_damage(var_actor)
				if !sub.needs_full_snapshot && !has_damage do continue
				snap_type: ipc.Snapshot_Type = .Full if sub.needs_full_snapshot else .Delta
				ws.snapshot_rev += 1
				hdr := ipc.Snapshot_Header{
					workspace_id = u64(ws.id),
					pane_id      = u64(var_actor.pane_id),
					snapshot_rev = ws.snapshot_rev,
					topology_rev = u64(ws.topology.revision),
					kind         = snap_type,
				}
				written, enc_err := ipc.encode_terminal_snapshot(h.snap_buf, &var_actor.terminal, hdr)
				if enc_err == .None && written > 0 {
					_, send_err := h.transport.publish_snapshot(
						h.transport.user_data,
						slot,
						u64(var_actor.pane_id),
						ws.snapshot_rev,
						h.snap_buf[:written],
					)
					if send_err == .None {
						sub.needs_full_snapshot = false
						sub.last_snapshot_rev = ws.snapshot_rev
						termgrid.terminal_clear_damage(&var_actor.terminal)
						var_actor.last_cursor_row = var_actor.terminal.cursor.row
						var_actor.last_cursor_col = var_actor.terminal.cursor.col
						var_actor.last_cursor_visible = var_actor.terminal.cursor.visible
						var_actor.last_cursor_style = var_actor.terminal.cursor.style
						var_actor.last_app_cursor_keys = var_actor.terminal.app_cursor_keys
					}
				}
			}
			sub.needs_full_snapshot = false
			sub.last_snapshot_rev = ws.snapshot_rev
		}
	}

	// 5. Brief sleep / listen poll
	if timeout_ms > 0 && h.hybrid_adapter.uds.server.listen_fd >= 0 {
		pfd := posix.pollfd{fd = h.hybrid_adapter.uds.server.listen_fd, events = {.IN}}
		_ = posix.poll(&pfd, 1, c.int(timeout_ms))
	}

	return h.running
}

host_destroy :: proc(h: ^Session_Host) {
	if h == nil do return
	h.running = false
	for &ws in h.workspaces {
		if !ws.used do continue
		for &actor in ws.panes {
			if actor != nil {
				rt.actor_destroy(actor)
				free(actor, h.allocator)
				actor = nil
			}
		}
		if len(ws.title) > 0 do delete(ws.title, h.allocator)
		if len(ws.cwd) > 0 do delete(ws.cwd, h.allocator)
		ws = {}
	}
	h.workspace_count = 0
	if h.snap_buf != nil {
		delete(h.snap_buf, h.allocator)
		h.snap_buf = nil
	}
	if h.transport.close_endpoint != nil {
		h.transport.close_endpoint(h.transport.user_data)
	}
	if h.workspaces != nil {
		delete(h.workspaces, h.allocator)
		h.workspaces = nil
	}
}
