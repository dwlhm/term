package app_test

import "core:encoding/endian"
import "core:fmt"
import "core:sync"
import posix "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import app ".."
import sh "../../session_host"
import ipc "../../session_ipc"
import rt "../../session_runtime"
import termgrid "../../terminal"

Host_Test_Runner :: struct {
	host:    sh.Session_Host,
	running: bool,
	thread:  ^thread.Thread,
}

_host_test_thread_proc :: proc(t: ^thread.Thread) {
	runner := (^Host_Test_Runner)(t.data)
	for sync.atomic_load(&runner.running) {
		_ = sh.host_step(&runner.host, 10)
	}
}

@(test)
test_host_client_gui_quit_survival :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_gui_quit_survival_%d_%d.sock", pid, now)

	// 1. Initialize a sh.Session_Host on a temp socket.
	runner := new(Host_Test_Runner)
	defer free(runner)

	init_ok := sh.host_init(&runner.host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&runner.host)

	sync.atomic_store(&runner.running, true)
	runner.thread = thread.create(_host_test_thread_proc)
	runner.thread.data = runner
	thread.start(runner.thread)
	defer {
		sync.atomic_store(&runner.running, false)
		thread.join(runner.thread)
		thread.destroy(runner.thread)
	}

	// 2. Initialize App_Host_Client and connect.
	client1: app.App_Host_Client
	c1_ok := app.host_client_ensure_connected(&client1, sock_path)
	testing.expect(t, c1_ok, "client 1 connect must succeed")

	// 3. Call host_client_create_workspace(&client, 24, 80, "/bin/sleep 30").
	ws_id, pane_id, create_ok := app.host_client_create_workspace(&client1, 24, 80, "/bin/sleep 30")
	testing.expect(t, create_ok, "create_workspace must succeed")
	testing.expect(t, ws_id != 0, "ws_id must be non-zero")
	testing.expect(t, pane_id != 0, "pane_id must be non-zero")

	// 4. Verify workspace created, child process PID running.
	child_pid: int = 0
	for &ws in runner.host.workspaces {
		if ws.used && ws.id == rt.Workspace_ID(ws_id) {
			for p in ws.panes {
				if p != nil && p.pane_id == rt.Pane_ID(pane_id) {
					child_pid = p.pty.pid
					break
				}
			}
			break
		}
	}
	testing.expect(t, child_pid > 1, "child PID must be > 1")
	testing.expect_value(t, posix.kill(posix.pid_t(child_pid), posix.Signal(0)), posix.result(0))

	// 5. Send input or verify snapshot.
	term := new(termgrid.Terminal)
	termgrid.terminal_init(term, 24, 80)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}

	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES, context.temp_allocator)
	snap_ok := false
	for _ in 0..<50 {
		updated, n := app.host_client_poll_snapshot(&client1, term, snap_buf, ws_id)
		if updated && n > 0 {
			snap_ok = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, snap_ok, "snapshot poll must succeed")

	// Send resize
	resize_ok := app.host_client_send_resize(&client1, ws_id, pane_id, 30, 100)
	testing.expect(t, resize_ok, "resize must succeed")

	// Send input
	in_ok := app.host_client_send_input(&client1, pane_id, transmute([]u8)string("\n"))
	testing.expect(t, in_ok, "input must succeed")

	// 6. Detach / close App_Host_Client (simulating GUI Quit).
	detach_ok := app.host_client_detach_workspace(&client1, ws_id)
	testing.expect(t, detach_ok, "detach_workspace must succeed")
	app.host_client_close(&client1)

	// 7. Verify child PID is still alive (posix.kill(pid, 0) == 0).
	time.sleep(50 * time.Millisecond)
	testing.expect_value(t, posix.kill(posix.pid_t(child_pid), posix.Signal(0)), posix.result(0))

	// 8. Connect a second App_Host_Client, list metadata, verify workspace exists and is detached (has_active_viewer == false).
	client2: app.App_Host_Client
	c2_ok := app.host_client_ensure_connected(&client2, sock_path)
	testing.expect(t, c2_ok, "client 2 connect must succeed")
	defer app.host_client_close(&client2)

	found_detached := false
	for _ in 0..<50 {
		entries, meta_ok := app.host_client_list_metadata(&client2)
		if meta_ok {
			for entry in entries {
				if entry.id == rt.Workspace_ID(ws_id) && !entry.has_active_viewer {
					found_detached = true
					break
				}
			}
		}
		if found_detached do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, found_detached, "workspace must be listed in metadata with has_active_viewer == false")

	// 9. Attach to the workspace, verify success.
	attach_ok := app.host_client_attach_workspace(&client2, ws_id)
	testing.expect(t, attach_ok, "attach_workspace must succeed")

	// Verify child PID is still running
	testing.expect_value(t, posix.kill(posix.pid_t(child_pid), posix.Signal(0)), posix.result(0))

	// 10. Clean up test host (deferred runners handle thread and host destruction).
	if child_pid > 1 {
		posix.kill(posix.pid_t(-child_pid), .SIGKILL)
		posix.kill(posix.pid_t(child_pid), .SIGKILL)
		posix.waitpid(posix.pid_t(child_pid), nil, {})
	}
}

@(test)
test_host_client_session_switcher_reattach :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_switcher_reattach_%d_%d.sock", pid, now)

	// 1. Start host runner.
	runner := new(Host_Test_Runner)
	defer free(runner)

	init_ok := sh.host_init(&runner.host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&runner.host)

	sync.atomic_store(&runner.running, true)
	runner.thread = thread.create(_host_test_thread_proc)
	runner.thread.data = runner
	thread.start(runner.thread)
	defer {
		sync.atomic_store(&runner.running, false)
		thread.join(runner.thread)
		thread.destroy(runner.thread)
	}

	// 2. Connect client and create workspace on host.
	client: app.App_Host_Client
	c_ok := app.host_client_ensure_connected(&client, sock_path)
	testing.expect(t, c_ok, "client connect must succeed")
	defer app.host_client_close(&client)

	ws_id, pane_id, create_ok := app.host_client_create_workspace(&client, 24, 80, "/bin/sleep 30")
	testing.expect(t, create_ok, "create_workspace must succeed")
	testing.expect(t, ws_id != 0, "ws_id must be non-zero")
	testing.expect(t, pane_id != 0, "pane_id must be non-zero")

	// Get child PID to clean up at end
	child_pid: int = 0
	for &ws in runner.host.workspaces {
		if ws.used && ws.id == rt.Workspace_ID(ws_id) {
			for p in ws.panes {
				if p != nil && p.pane_id == rt.Pane_ID(pane_id) {
					child_pid = p.pty.pid
					break
				}
			}
			break
		}
	}

	defer if child_pid > 1 {
		posix.kill(posix.pid_t(-child_pid), .SIGKILL)
		posix.kill(posix.pid_t(child_pid), .SIGKILL)
		posix.waitpid(posix.pid_t(child_pid), nil, {})
	}

	// 3. Detach workspace.
	detach_ok := app.host_client_detach_workspace(&client, ws_id)
	testing.expect(t, detach_ok, "detach_workspace must succeed")

	// 4. Session Switcher simulation: call host_client_list_metadata and verify detached workspace appears.
	found_detached := false
	for _ in 0..<50 {
		entries, meta_ok := app.host_client_list_metadata(&client)
		if meta_ok {
			for entry in entries {
				if entry.id == rt.Workspace_ID(ws_id) && !entry.has_active_viewer {
					found_detached = true
					break
				}
			}
		}
		if found_detached do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, found_detached, "detached workspace must appear in metadata with has_active_viewer == false")

	// 5. Attach via host_client_attach_workspace.
	attach_ok := app.host_client_attach_workspace(&client, ws_id)
	testing.expect(t, attach_ok, "host_client_attach_workspace must succeed")

	// 6. Verify has_active_viewer == true via host_client_list_metadata.
	found_active := false
	for _ in 0..<50 {
		entries, meta_ok := app.host_client_list_metadata(&client)
		if meta_ok {
			for entry in entries {
				if entry.id == rt.Workspace_ID(ws_id) && entry.has_active_viewer {
					found_active = true
					break
				}
			}
		}
		if found_active do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, found_active, "workspace must have has_active_viewer == true after attach")

	// 7. Verify session_spawn_host_backed and session_poll_all.
	sm: app.Session_Manager
	sm.max_tabs = 8
	defer app.session_manager_destroy(&sm)

	idx, spawn_ok := app.session_spawn_host_backed(&sm, &client, ws_id, pane_id, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawn_ok, "session_spawn_host_backed must succeed")
	testing.expect(t, idx == 0, "tab idx must be 0")
	testing.expect(t, sm.tabs[0].is_host_backed, "tab must be host-backed")
	testing.expect(t, sm.tabs[0].backend.host_client == &client, "tab backend host_client must be set")
	testing.expect(t, sm.tabs[0].backend.host_pane_id == pane_id, "tab backend host_pane_id must match")

	// Verify input routing via backend_write_pty
	in_ok := app.backend_write_pty(&sm.tabs[0].backend, transmute([]u8)string("\n"))
	testing.expect(t, in_ok, "backend_write_pty must succeed for host-backed backend")

	// Verify polling snapshots
	_ = app.session_poll_all(&sm)
}

@(test)
test_host_client_split_pane :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_split_pane_%d_%d.sock", pid, now)

	runner := new(Host_Test_Runner)
	defer free(runner)

	init_ok := sh.host_init(&runner.host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&runner.host)

	sync.atomic_store(&runner.running, true)
	runner.thread = thread.create(_host_test_thread_proc)
	runner.thread.data = runner
	thread.start(runner.thread)
	defer {
		sync.atomic_store(&runner.running, false)
		thread.join(runner.thread)
		thread.destroy(runner.thread)
	}

	client: app.App_Host_Client
	c_ok := app.host_client_ensure_connected(&client, sock_path)
	testing.expect(t, c_ok, "client connect must succeed")
	defer app.host_client_close(&client)

	ws_id, pane_id, create_ok := app.host_client_create_workspace(&client, 24, 80, "/bin/sleep 30")
	testing.expect(t, create_ok, "create_workspace must succeed")
	testing.expect(t, ws_id != 0, "ws_id must be non-zero")
	testing.expect(t, pane_id != 0, "pane_id must be non-zero")

	split_pane_id, split_ok := app.host_client_split_pane(&client, ws_id, 24, 80, "/bin/sleep 30")
	testing.expect(t, split_ok, "host_client_split_pane must succeed")
	testing.expect(t, split_pane_id != 0, "split_pane_id must be non-zero")
	testing.expect(t, split_pane_id != pane_id, "split_pane_id must differ from initial pane_id")

	// Verify host has two active panes in the workspace
	pane_count := 0
	pids: [dynamic]int
	defer delete(pids)
	for &ws in runner.host.workspaces {
		if ws.used && ws.id == rt.Workspace_ID(ws_id) {
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

	// Verify input delivery to split pane
	in_ok := app.host_client_send_input(&client, split_pane_id, transmute([]u8)string("\n"))
	testing.expect(t, in_ok, "input to split pane must succeed")

	// Verify metadata shows 2 panes for this workspace
	found_meta := false
	for _ in 0..<50 {
		entries, meta_ok := app.host_client_list_metadata(&client)
		if meta_ok {
			for entry in entries {
				if entry.id == rt.Workspace_ID(ws_id) {
					testing.expect_value(t, entry.pane_count, 2)
					found_meta = true
					break
				}
			}
		}
		if found_meta do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, found_meta, "metadata with pane_count == 2 must be found")

	// Test host-backed pane tree split integration
	sm: app.Session_Manager
	sm.max_tabs = 8
	defer app.session_manager_destroy(&sm)

	idx, spawn_ok := app.session_spawn_host_backed(&sm, &client, ws_id, pane_id, 24, 80, nil, termgrid.Theme{})
	testing.expect(t, spawn_ok, "session_spawn_host_backed must succeed")
	testing.expect(t, idx == 0, "tab idx must be 0")

	b2 := new(app.Backend)
	b2_ok := app.backend_init_host_backed(b2, 24, 80, &client, ws_id, split_pane_id, nil, termgrid.Theme{})
	testing.expect(t, b2_ok, "backend_init_host_backed must succeed")

	_, tree_split_ok := app.pane_tree_split(&sm.tabs[0].tree, sm.tabs[0].tree.root.id, .Vertical, b2)
	testing.expect(t, tree_split_ok, "pane_tree_split with host-backed backend must succeed")
	testing.expect_value(t, sm.tabs[0].tree.node_count, 3)
}

@(test)
test_host_client_multi_tab_switching_no_freeze :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_multi_tab_%d_%d.sock", pid, now)

	runner := new(Host_Test_Runner)
	defer free(runner)

	init_ok := sh.host_init(&runner.host, sock_path)
	testing.expect(t, init_ok, "host_init must succeed")
	defer sh.host_destroy(&runner.host)

	sync.atomic_store(&runner.running, true)
	runner.thread = thread.create(_host_test_thread_proc)
	runner.thread.data = runner
	thread.start(runner.thread)
	defer {
		sync.atomic_store(&runner.running, false)
		thread.join(runner.thread)
		thread.destroy(runner.thread)
	}

	client: app.App_Host_Client
	c_ok := app.host_client_ensure_connected(&client, sock_path)
	testing.expect(t, c_ok, "client connect must succeed")
	defer app.host_client_close(&client)

	// 1. Create workspace 1 and workspace 2 on a single client
	ws1_id, p1_id, ok1 := app.host_client_create_workspace(&client, 24, 80, "/bin/sleep 30")
	testing.expect(t, ok1, "create workspace 1 must succeed")
	testing.expect(t, ws1_id != 0, "ws1_id != 0")

	ws2_id, p2_id, ok2 := app.host_client_create_workspace(&client, 24, 80, "/bin/sleep 30")
	testing.expect(t, ok2, "create workspace 2 must succeed")
	testing.expect(t, ws2_id != 0, "ws2_id != 0")

	defer {
		for &ws in runner.host.workspaces {
			if ws.used && (ws.id == rt.Workspace_ID(ws1_id) || ws.id == rt.Workspace_ID(ws2_id)) {
				for p in ws.panes {
					if p != nil && p.pty.pid > 1 {
						posix.kill(posix.pid_t(-p.pty.pid), .SIGKILL)
						posix.kill(posix.pid_t(p.pty.pid), .SIGKILL)
						posix.waitpid(posix.pid_t(p.pty.pid), nil, {})
					}
				}
			}
		}
	}

	term1 := new(termgrid.Terminal)
	termgrid.terminal_init(term1, 24, 80)
	defer {
		termgrid.terminal_destroy(term1)
		free(term1)
	}

	term2 := new(termgrid.Terminal)
	termgrid.terminal_init(term2, 24, 80)
	defer {
		termgrid.terminal_destroy(term2)
		free(term2)
	}

	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES, context.temp_allocator)

	// Drain initial snapshots so client is idle
	for _ in 0..<50 {
		updated, _ := app.host_client_poll_snapshot(&client, term2, snap_buf, ws2_id)
		if !updated do break
		time.sleep(5 * time.Millisecond)
	}

	// 2. Switching attach between workspace 1 and workspace 2
	att1 := app.host_client_attach_workspace(&client, ws1_id)
	testing.expect(t, att1, "attach workspace 1 must succeed")

	att2 := app.host_client_attach_workspace(&client, ws2_id)
	testing.expect(t, att2, "attach workspace 2 must succeed")

	// Drain again until idle
	for _ in 0..<50 {
		updated, _ := app.host_client_poll_snapshot(&client, term2, snap_buf, ws2_id)
		if !updated do break
		time.sleep(5 * time.Millisecond)
	}

	// 3. Verifying host_client_poll_snapshot on an idle client returns immediately (< 10ms) without blocking
	start := time.now()
	updated, _ := app.host_client_poll_snapshot(&client, term2, snap_buf, ws2_id)
	elapsed := time.since(start)
	testing.expect(t, !updated, "idle poll should not update")
	testing.expect(t, elapsed < 10 * time.Millisecond, "idle poll must return in < 10ms without blocking")

	// 4. Verifying workspace ID filtering works
	fake_buf := make([]u8, ipc.SNAPSHOT_HEADER_BYTES + 32, context.temp_allocator)
	endian.unchecked_put_u64le(fake_buf[0:8], ws1_id)

	mock_state := struct {
		buf:    []u8,
		called: bool,
	}{
		buf    = fake_buf,
		called = false,
	}

	mock_read :: proc(user_data: rawptr, out: []u8) -> (int, u64, bool) {
		s := (^struct { buf: []u8, called: bool })(user_data)
		if s.called do return 0, 0, false
		s.called = true
		copy(out, s.buf)
		return len(s.buf), 1, true
	}

	mock_client := app.App_Host_Client{
		connected = true,
		transport = {
			user_data     = &mock_state,
			read_snapshot = mock_read,
		},
	}

	filtered_updated, _ := app.host_client_poll_snapshot(&mock_client, term2, snap_buf, ws2_id)
	testing.expect(t, !filtered_updated, "workspace ID filter must reject mismatched snapshot ws_id")
}
