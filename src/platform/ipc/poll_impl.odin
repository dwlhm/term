package platform_ipc

// What a Poll_Set holds behind its handle: a fixed table of sources (fds
// with the interests they want now and who to tell), the wake pipe in slot
// 0, and the backend. Watches (poll_set_watch) are sources; Servers and
// Links register theirs the same way. Everything is allocated in
// poll_set_init; a round only fills the preallocated pollfd list.

import "base:runtime"
import "core:sys/posix"

@(private)
_Source :: struct {
	fd:    posix.FD,
	want:  posix.Poll_Event,
	on:    proc(data: rawptr, rev: posix.Poll_Event), // package sources
	watch: proc(data: rawptr, ev: Fd_Event),         // poll_set_watch
	data:  rawptr,
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
	if s := _poll_source(p, id); s != nil do s.used, s.fd, s.on, s.watch, s.data = false, -1, nil, nil, nil
}

// _poll_round waits once and dispatches; timeout_ms -1 = no deadline.
@(private)
_poll_round :: proc(p: ^_Poll, timeout_ms: int) {
	n := 0
	for &s, i in p.sources {
		if !s.used || s.want == {} do continue
		p.pfds[n] = {fd = s.fd, events = s.want}
		p.refs[n] = {i, s.gen}
		n += 1
	}
	if _backend_poll(&p.backend, p.pfds[:n], timeout_ms) <= 0 do return
	for f, i in p.pfds[:n] {
		s := &p.sources[p.refs[i].slot]
		if f.revents == {} || !s.used || s.gen != p.refs[i].gen do continue // gone during this round
		if s.watch != nil do _watch_ready(p, s, f.revents)
		else do s.on(s.data, f.revents)
	}
}

// _watch_ready: Readable while there is input, then Ended (and forgotten) on NVAL/ERR/HUP.
@(private = "file")
_watch_ready :: proc(p: ^_Poll, s: ^_Source, rev: posix.Poll_Event) {
	cb, data, gen := s.watch, s.data, s.gen
	ended := rev & {.NVAL, .ERR, .HUP} != {}
	if .IN in rev && .NVAL not_in rev do cb(data, .Readable)
	if !ended || !s.used || s.gen != gen do return // unwatched (or replaced) in its callback
	s.used, s.fd, s.watch, s.data = false, -1, nil, nil
	cb(data, .Ended)
}

@(private)
_wake_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	p := (^_Poll)(data)
	buf: [64]u8
	for posix.read(p.wake[0], raw_data(buf[:]), len(buf)) > 0 {}
	p.woken = true
}
