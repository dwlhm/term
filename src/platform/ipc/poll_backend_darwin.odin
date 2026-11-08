package platform_ipc

// Poll_Set backend on Darwin (from platform/poller, which goes away in M2):
// one kqueue kept across rounds. Every round re-adds its interests, so an fd
// closed under the set comes back as NVAL (EBADF), like poll(2).
// Linux: poll_backend_linux.odin.

import "base:runtime"
import "core:c"
import "core:sys/kqueue"
import "core:sys/posix"

// _Fd_State: what the kqueue holds for one fd, and the round that last named it.
@(private = "file")
_POLL_MAX_FD :: 1 << 16 // table bound when RLIMIT_NOFILE is unlimited

@(private = "file")
_Fd_State :: struct {
	regs:  posix.Poll_Event, // {.IN, .OUT} registered
	round: u32,
}

@(private)
_Backend :: struct {
	kq:        kqueue.KQ,
	ok:        bool,
	round:     u32,
	table:     []_Fd_State, // by fd, below RLIMIT_NOFILE
	capacity:  int,
	active:    []posix.FD, // fds with registrations: active[:active_n]
	active_n:  int,
	next:      []posix.FD, // the next round's list (swapped in): this round's fds + the previous ones to sweep
	changes:   []kqueue.KEvent,
	events:    []kqueue.KEvent,
	allocator: runtime.Allocator,
}

@(private)
_backend_init :: proc(p: ^_Backend, capacity: int, allocator := context.allocator) -> bool {
	p^ = {allocator = allocator}
	kq, err := kqueue.kqueue()
	if err != nil do return false
	p.kq, p.ok = kq, true
	rl: posix.rlimit
	limit := _POLL_MAX_FD
	if posix.getrlimit(.NOFILE, &rl) == .OK && rl.rlim_cur < posix.rlim_t(_POLL_MAX_FD) do limit = int(rl.rlim_cur)
	p.table = make([]_Fd_State, limit, allocator)
	p.capacity = capacity
	p.active = make([]posix.FD, 2 * capacity, allocator)
	p.next = make([]posix.FD, 2 * capacity, allocator)
	// Per fd: up to two adds and two deletes; errors come back as events.
	p.changes = make([]kqueue.KEvent, 4 * capacity, allocator)
	p.events = make([]kqueue.KEvent, 4 * capacity, allocator)
	return true
}

@(private)
_backend_destroy :: proc(p: ^_Backend) {
	if p.ok do posix.close(posix.FD(p.kq))
	delete(p.table, p.allocator)
	delete(p.active, p.allocator)
	delete(p.next, p.allocator)
	delete(p.changes, p.allocator)
	delete(p.events, p.allocator)
	p^ = {}
}

// _backend_poll waits like posix.poll(raw_data(fds), len(fds), timeout_ms):
// the number of fds with revents, 0 on timeout, -1 with errno set (EINTR).
@(private)
_backend_poll :: proc(p: ^_Backend, fds: []posix.pollfd, timeout_ms: int) -> int {
	if len(fds) > p.capacity do return -1
	p.round += 1
	ch, nval := _register(p, fds)
	ch = _unregister_gone(p, ch)
	ts: posix.timespec
	tsp: ^posix.timespec
	if timeout_ms >= 0 && nval == 0 {
		ts = {tv_sec = posix.time_t(timeout_ms / 1000), tv_nsec = c.long(timeout_ms % 1000) * 1_000_000}
	}
	if timeout_ms >= 0 || nval > 0 do tsp = &ts // an invalid fd answers at once, as poll does
	n, err := kqueue.kevent(p.kq, p.changes[:ch], p.events[:], tsp)
	if err != nil do return -1
	return nval + _deliver(p, fds, p.events[:n])
}

// _register queues this round's adds (and deletes of interests an fd
// dropped), marks the fds, and builds the next active list.
@(private = "file")
_register :: proc(p: ^_Backend, fds: []posix.pollfd) -> (ch, nval: int) {
	n := 0
	for &f, i in fds {
		f.revents = {}
		if f.fd < 0 do continue
		if int(f.fd) >= len(p.table) {
			f.revents = {.NVAL}
			nval += 1
			continue
		}
		st := &p.table[f.fd]
		want := f.events & {.IN, .OUT}
		udata := rawptr(uintptr(i + 1))
		if .IN in want do ch = _change(p, ch, f.fd, .Read, {.Add}, udata)
		if .OUT in want do ch = _change(p, ch, f.fd, .Write, {.Add}, udata)
		ch = _delete(p, ch, f.fd, st.regs - want)
		if st.round != p.round && want != {} {
			p.next[n] = f.fd
			n += 1
		}
		st.regs, st.round = want, p.round
	}
	// Fds named this round keep their slot; the ones that were not are swept next.
	for fd in p.active[:p.active_n] {
		if p.table[fd].round == p.round do continue
		p.next[n] = fd
		n += 1
	}
	p.active, p.next = p.next, p.active
	p.active_n = n
	return
}

// _unregister_gone deletes every registration of an fd this round did not
// name, and drops it (and fds left without interest) from the active list.
@(private = "file")
_unregister_gone :: proc(p: ^_Backend, ch_in: int) -> int {
	ch, kept := ch_in, 0
	for fd in p.active[:p.active_n] {
		st := &p.table[fd]
		if st.round != p.round {
			ch = _delete(p, ch, fd, st.regs)
			st.regs = {}
		}
		if st.regs == {} do continue
		p.active[kept] = fd
		kept += 1
	}
	p.active_n = kept
	return ch
}

@(private = "file")
_delete :: proc(p: ^_Backend, ch: int, fd: posix.FD, gone: posix.Poll_Event) -> int {
	ch := ch
	if .IN in gone do ch = _change(p, ch, fd, .Read, {.Delete}, nil)
	if .OUT in gone do ch = _change(p, ch, fd, .Write, {.Delete}, nil)
	return ch
}

@(private = "file")
_change :: proc(p: ^_Backend, ch: int, fd: posix.FD, filter: kqueue.Filter, flags: kqueue.Flags, udata: rawptr) -> int {
	p.changes[ch] = {ident = uintptr(fd), filter = filter, flags = flags, udata = udata}
	return ch + 1
}

// _deliver maps events back to revents (udata = index + 1; deletes carry
// none, and their errors, for fds already closed, are ignored).
@(private = "file")
_deliver :: proc(p: ^_Backend, fds: []posix.pollfd, events: []kqueue.KEvent) -> int {
	ready := 0
	for e in events {
		i := int(uintptr(e.udata)) - 1
		if i < 0 || i >= len(fds) do continue
		f := &fds[i]
		if f.revents == {} do ready += 1
		switch {
		case .Error in e.flags && e.data == c.long(posix.Errno.EBADF):
			// The kernel holds nothing for a closed fd: forget its interests too,
			// or next round's delete fails at once and wakes an idle wait.
			f.revents += {.NVAL}
			p.table[f.fd].regs = {}
		case .Error in e.flags:
			f.revents += {.ERR}
		case e.filter == .Read:
			f.revents += {.IN}
		case e.filter == .Write:
			f.revents += {.OUT}
		}
		if .EOF in e.flags && .Error not_in e.flags do f.revents += {.HUP}
	}
	return ready
}
