package feature_holder

// Session lifecycle: spawn, output reading, input writing, reaping, release.

import "core:c"
import "core:fmt"
import "core:sys/posix"
import ipc "../../platform/ipc"
import pty "../../platform/pty"

_session_find :: proc(h: ^Holder, id: u32) -> ^Session {
	for slot in h.live[:h.count] do if h.sessions[slot].id == id do return &h.sessions[slot]
	return nil
}

// _session_spawn starts m on a new PTY as session id. The two rings are the
// only allocations a session makes.
_session_spawn :: proc(h: ^Holder, id: u32, m: ^ipc.Spawn_Msg) -> (s: ^Session, reason: string) {
	index := -1
	for slot, i in h.sessions {
		if !slot.used {
			index = i
			break
		}
	}
	if index < 0 do return nil, "too many sessions"
	cfg := pty.Pty_Config{
		shell  = m.argv[0],
		argv   = m.argv[1:m.argc],
		cwd    = m.cwd,
		cols   = int(m.cols),
		rows   = int(m.rows),
		xpixel = int(m.xpixel),
		ypixel = int(m.ypixel),
	}
	env := make([]string, m.envc + 1, context.temp_allocator)
	copy(env, m.env[:m.envc])
	env[m.envc] = fmt.tprintf("%s=%d", ipc.SESSION_ID_ENV, id)
	master, pid, err := pty.pty_spawn_raw(cfg, env)
	free_all(context.temp_allocator)
	if err != .None do return nil, fmt.bprintf(h.msg_buf[:], "spawn failed: %v", err)
	s = &h.sessions[index]
	s^ = {
		used         = true,
		id           = id,
		pid          = pid,
		started_unix = _now_unix(),
		master       = master,
		size         = m.size,
		tailed       = h.core_state == .Linked,
	}
	s.tail.buf = make([]u8, HOLDER_TAIL_BYTES)
	s.input.buf = make([]u8, HOLDER_INPUT_BYTES)
	h.live[h.count] = u16(index)
	h.count += 1
	return s, ""
}

// _session_forget releases a session. Output not at EOF (someone still holds
// the tty) or a live child → pty_hangup; an unreaped child becomes an orphan.
_session_forget :: proc(h: ^Holder, s: ^Session) {
	if !s.eof || !s.reaped {
		pty.pty_hangup(s.master, s.pid)
		if !s.reaped do _orphan_add(h, s.pid)
	} else {
		posix.close(posix.FD(s.master))
	}
	delete(s.tail.buf)
	delete(s.input.buf)
	s^ = {}
	for slot, i in h.live[:h.count] {
		if &h.sessions[slot] != s do continue
		h.count -= 1
		h.live[i] = h.live[h.count] // swap-remove: live order is not a contract
		break
	}
	if h.count == 0 do _supervisor_empty(&h.sup, _now())
}

// _forget_all releases every session; backwards, since forget swap-removes.
_forget_all :: proc(h: ^Holder) {
	for i := h.count - 1; i >= 0; i -= 1 do _session_forget(h, &h.sessions[h.live[i]])
}

// _tail_push keeps the newest HOLDER_TAIL_BYTES: the oldest bytes make room.
_tail_push :: proc(r: ^ipc.Byte_Ring, data: []u8) {
	d := data
	if len(d) >= len(r.buf) {
		ipc.ring_clear(r)
		d = d[len(d) - len(r.buf):]
	}
	if room := len(r.buf) - r.len; room < len(d) do ipc.ring_consume(r, len(d) - room)
	ipc.ring_push(r, d)
}

// _session_drain reads the master until it would block, ends, or one frame
// budget is full, then hands the bytes on as a single OUTPUT frame. The budget
// also fits the core's control queue, so a round in which every session floods
// never overflows it (_backlogged leaves HOLDER_CTL_CAP - HOLDER_BACKLOG room).
_session_drain :: proc(h: ^Holder, s: ^Session, now: i64) {
	if _backlogged(h) do return
	send := h.core_state == .Linked && s.tailed
	budget := len(h.read_buf)
	if send do budget = min(budget, len(h.core.ctl.buf) - h.core.ctl.len - ipc.STREAM_HEADER)
	got, ended := 0, false
	for got < budget {
		n := posix.read(posix.FD(s.master), &h.read_buf[got], uint(budget - got))
		if n > 0 {
			got += n
			continue
		}
		if n < 0 && posix.errno() == .EINTR do continue
		ended = n == 0 || posix.errno() != .EAGAIN || (got == 0 && _master_hung_up(s))
		break
	}
	if got > 0 {
		_tail_push(&s.tail, h.read_buf[:got])
		if send do _core_send(h, ipc.MSG_OUTPUT, s.id, h.read_buf[:got])
	}
	if !ended do return
	s.eof = true // EOF / EIO: the reader is done
	ipc.ring_clear(&s.input)
	_session_check_exit(h, s, now)
}

// _master_hung_up: an EAGAIN with nothing read is a spurious wakeup unless the
// master reports a hangup with nothing left to read.
@(private = "file")
_master_hung_up :: proc(s: ^Session) -> bool {
	pfd := posix.pollfd{fd = posix.FD(s.master), events = {.IN}}
	return posix.poll(&pfd, 1, 0) > 0 && pfd.revents & {.HUP, .ERR} != {} && .IN not_in pfd.revents
}

_session_write :: proc(s: ^Session) {
	for s.input.len > 0 {
		run := ipc.ring_front(&s.input)
		n := posix.write(posix.FD(s.master), raw_data(run), uint(len(run)))
		if n > 0 {
			ipc.ring_consume(&s.input, int(n))
			continue
		}
		if n < 0 && posix.errno() == .EINTR do continue
		if n < 0 && posix.errno() == .EAGAIN do return
		ipc.ring_clear(&s.input) // EIO: nobody reads the tty any more
		return
	}
}

// _session_input queues bytes for the program; a full queue drops them.
_session_input :: proc(s: ^Session, data: []u8) {
	if s.eof do return
	if !ipc.ring_push(&s.input, data) {
		fmt.eprintfln("holder: session %d input queue full, dropped %d bytes", s.id, len(data))
		return
	}
	_session_write(s)
}

// _session_check_exit makes the exit reportable once output is drained, or
// HOLDER_EXIT_FLOW_MS after the reap while output could flow.
_session_check_exit :: proc(h: ^Holder, s: ^Session, now: i64) {
	if !s.reaped || s.exit_final do return
	if !s.eof && (h.paused || now < s.exit_deadline) do return
	s.exit_final = true
	_session_report_exit(h, s)
}

_session_report_exit :: proc(h: ^Holder, s: ^Session) {
	if !s.exit_final || s.exit_sent || !s.tailed || h.core_state != .Linked do return
	w := ipc.wire_writer(h.msg_buf[:])
	ipc.enc_exit(&w, s.exit)
	if _core_send(h, ipc.MSG_EXITED, s.id, ipc.wire_bytes_written(&w)) do s.exit_sent = true
}

// _reap_all collects every exited child (sessions and orphans).
_reap_all :: proc(h: ^Holder, now: i64) {
	for slot in h.live[:h.count] {
		s := &h.sessions[slot]
		if s.reaped do continue
		status: c.int
		if posix.waitpid(posix.pid_t(s.pid), &status, {.NOHANG}) != posix.pid_t(s.pid) do continue
		s.reaped = true
		s.exit = _exit_from_status(status)
		s.exit_deadline = now + _ms(HOLDER_EXIT_FLOW_MS)
		_session_check_exit(h, s, now)
	}
	for &pid in h.orphans {
		if pid <= 0 do continue
		status: c.int
		r := posix.waitpid(posix.pid_t(pid), &status, {.NOHANG})
		if r == posix.pid_t(pid) || (r < 0 && posix.errno() == .ECHILD) do pid = 0
	}
}

@(private = "file")
_exit_from_status :: proc(status: c.int) -> (e: ipc.Exit_Msg) {
	if posix.WIFEXITED(status) do e.code = i32(posix.WEXITSTATUS(status))
	if posix.WIFSIGNALED(status) {
		e.signaled = true
		e.signal = i32(posix.WTERMSIG(status))
		e.code = 128 + e.signal
	}
	return
}

_orphan_add :: proc(h: ^Holder, pid: i32) {
	for &o in h.orphans {
		if o <= 0 {
			o = pid
			return
		}
	}
}

// _orphans_reap_wait reaps hung-up children at exit (≤ 1 s, they were SIGKILLed).
_orphans_reap_wait :: proc(h: ^Holder) {
	deadline := _now() + _ms(1000)
	for _now() < deadline {
		left := false
		_reap_all(h, _now())
		for o in h.orphans do left ||= o > 0
		if !left do return
		posix.poll(nil, 0, 10)
	}
}
