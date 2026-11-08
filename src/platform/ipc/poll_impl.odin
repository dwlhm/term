package platform_ipc

// What a Poll_Set holds behind its handle: a fixed table of sources (fds
// with the interests they want now and who to tell), the wake pipe in slot
// 0, and the backend. Watches (poll_set_watch) are sources; Servers and
// Links register theirs the same way. A source may also carry a deadline
// (due, time.tick_now()._nsec): a wait never sleeps past it, and on_due runs
// once it passes (fd -1 = a pure timer). Everything is allocated in
// poll_set_init; a round only fills the preallocated pollfd list.

import "base:runtime"
import "core:sys/posix"
import "core:time"

@(private)
_Source :: struct {
	fd:    posix.FD,
	want:  posix.Poll_Event,
	on:    proc(data: rawptr, rev: posix.Poll_Event), // package sources
	watch: proc(data: rawptr, ev: Fd_Event),         // poll_set_watch
	data:  rawptr,
	due:    i64,              // 0 = none; cleared before on_due runs
	on_due: proc(data: rawptr),
	gen:   u16,
	used:  bool,
}

@(private)
_Ref :: struct {
	slot: int,
	gen:  u16,
}

@(private)
_Poll :: struct {
	backend:   _Backend,
	sources:   []_Source,
	top:       int, // sources[top:] are all free: a round looks at sources[:top] only
	pfds:      []posix.pollfd,
	refs:      []_Ref, // refs[i] owns pfds[i] this round
	wake:      [2]posix.FD,
	woken:     bool,
	allocator: runtime.Allocator,
}

@(private)
_poll :: proc "contextless" (set: ^Poll_Set) -> ^_Poll {
	return (^_Poll)(set._impl) if set != nil else nil
}

// _poll_add registers fd; the id is gen<<16 | slot (never 0: slot 0 is the wake pipe).
@(private)
_poll_add :: proc(p: ^_Poll, src: _Source) -> (id: u32, ok: bool) {
	for &s, i in p.sources[1:] {
		if s.used do continue
		gen := s.gen + 1
		s = src
		s.gen, s.used = gen, true
		p.top = max(p.top, i + 2)
		return u32(gen) << 16 | u32(i + 1), true
	}
	return 0, false
}

@(private)
_poll_source :: proc(p: ^_Poll, id: u32) -> ^_Source {
	slot := int(id & 0xffff)
	if p == nil || slot == 0 || slot >= len(p.sources) do return nil
	s := &p.sources[slot]
	return s if s.used && s.gen == u16(id >> 16) else nil
}

@(private)
_poll_remove :: proc(p: ^_Poll, id: u32) {
	if s := _poll_source(p, id); s != nil do _poll_free_source(p, s)
}

// _poll_free_source frees a slot and lowers top past the free tail.
@(private)
_poll_free_source :: proc(p: ^_Poll, s: ^_Source) {
	s^ = {fd = -1, gen = s.gen}
	for p.top > 1 && !p.sources[p.top - 1].used do p.top -= 1
}

// _poll_round waits once (until due_ns, or the earliest source deadline;
// -1 = none), dispatches readiness, then runs the deadlines that passed.
@(private)
_poll_round :: proc(p: ^_Poll, due_ns: i64) {
	n, due := 0, due_ns
	for &s, i in p.sources[:p.top] {
		if !s.used do continue
		if s.due > 0 && (due < 0 || s.due < due) do due = s.due
		if s.fd < 0 || s.want == {} do continue
		p.pfds[n] = {fd = s.fd, events = s.want}
		p.refs[n] = {i, s.gen}
		n += 1
	}
	timeout_ms := -1
	if due >= 0 do timeout_ms = int(max(0, (due - time.tick_now()._nsec + 999_999) / 1_000_000))
	if _backend_poll(&p.backend, p.pfds[:n], timeout_ms) > 0 do _poll_dispatch(p, n)
	_poll_deadlines(p)
}

@(private = "file")
_poll_dispatch :: proc(p: ^_Poll, n: int) {
	for f, i in p.pfds[:n] {
		s := &p.sources[p.refs[i].slot]
		if f.revents == {} || !s.used || s.gen != p.refs[i].gen do continue // gone during this round
		if s.watch != nil do _watch_ready(p, s, f.revents)
		else do s.on(s.data, f.revents)
	}
}

@(private = "file")
_poll_deadlines :: proc(p: ^_Poll) {
	now := time.tick_now()._nsec
	for &s in p.sources[:p.top] {
		if !s.used || s.due <= 0 || s.due > now do continue
		s.due = 0
		s.on_due(s.data)
	}
}

// _watch_ready: Readable while there is input, Writable while there is room,
// then Ended (and forgotten) on NVAL/ERR/HUP.
@(private = "file")
_watch_ready :: proc(p: ^_Poll, s: ^_Source, rev: posix.Poll_Event) {
	cb, data, gen := s.watch, s.data, s.gen
	ended := rev & {.NVAL, .ERR, .HUP} != {}
	if .IN in rev && .NVAL not_in rev do cb(data, .Readable)
	if .OUT in rev && !ended && s.used && s.gen == gen do cb(data, .Writable)
	if !ended || !s.used || s.gen != gen do return // unwatched (or replaced) in its callback
	_poll_free_source(p, s)
	cb(data, .Ended)
}

@(private)
_wake_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	p := (^_Poll)(data)
	buf: [64]u8
	for posix.read(p.wake[0], raw_data(buf[:]), len(buf)) > 0 {}
	p.woken = true
}
