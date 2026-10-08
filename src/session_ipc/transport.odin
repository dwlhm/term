package session_ipc

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System.framework"
	@(default_calling_convention = "c")
	foreign libc {
		getpeereid :: proc(s: posix.FD, euid: ^posix.uid_t, egid: ^posix.gid_t) -> c.int ---
		flock :: proc(fd: c.int, operation: c.int) -> c.int ---
	}
	LOCK_SH :: 1
	LOCK_EX :: 2
	LOCK_NB :: 4
	LOCK_UN :: 8
} else {
	foreign import libc "system:c"
	@(default_calling_convention = "c")
	foreign libc {
		flock :: proc(fd: c.int, operation: c.int) -> c.int ---
	}
	LOCK_SH :: 1
	LOCK_EX :: 2
	LOCK_NB :: 4
	LOCK_UN :: 8

	ucred :: struct {
		pid: posix.pid_t,
		uid: posix.uid_t,
		gid: posix.gid_t,
	}
	SO_PEERCRED :: 17
}

DEFAULT_SOCKET_DIR :: ".term"
DEFAULT_SOCKET_NAME :: "term-host.sock"
MAX_IPC_CLIENTS :: 16

Transport_Error :: enum {
	None,
	Dir_Create_Failed,
	Lock_Failed,
	Socket_Failed,
	Bind_Failed,
	Listen_Failed,
	Connect_Failed,
	Peer_Auth_Failed,
	Buffer_Full,
	Disconnected,
}

Socket_Client :: struct {
	fd:        posix.FD,
	read_buf:  []u8,
	read_len:  int,
	allocator: runtime.Allocator,
}

Server_Client_Slot :: struct {
	active:   bool,
	fd:       posix.FD,
	uid:      u32,
	read_buf: []u8,
	read_len: int,
}

Socket_Server :: struct {
	listen_fd:    posix.FD,
	lock_fd:      posix.FD,
	socket_path:  string,
	lock_path:    string,
	clients:      [MAX_IPC_CLIENTS]Server_Client_Slot,
	client_count: int,
	allocator:    runtime.Allocator,
}

resolve_default_socket_path :: proc(allocator := context.allocator) -> (string, bool) {
	home, ok := os.lookup_env("HOME", context.temp_allocator)
	if !ok || len(home) == 0 {
		return "", false
	}
	dir := fmt.tprintf("%s/%s", home, DEFAULT_SOCKET_DIR)
	c_dir := strings.clone_to_cstring(dir, context.temp_allocator)
	if posix.mkdir(c_dir, posix.S_IRWXU) != .OK {
		if posix.errno() != .EEXIST {
			return "", false
		}
		posix.chmod(c_dir, posix.S_IRWXU)
	}
	path := fmt.aprintf("%s/%s", dir, DEFAULT_SOCKET_NAME, allocator = allocator)
	return path, true
}

validate_peer_uid :: proc(fd: posix.FD) -> bool {
	when ODIN_OS == .Darwin {
		euid: posix.uid_t
		egid: posix.gid_t
		if getpeereid(fd, &euid, &egid) != 0 {
			return false
		}
		return euid == posix.getuid()
	} else {
		cred: ucred
		len := posix.socklen_t(size_of(cred))
		if posix.getsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_PEERCRED), &cred, &len) != .OK {
			return false
		}
		return cred.uid == posix.getuid()
	}
}

@(private = "file")
set_nonblocking_and_cloexec :: proc(fd: posix.FD) -> bool {
	fl := posix.fcntl(fd, .GETFL)
	if fl == -1 do return false
	if posix.fcntl(fd, .SETFL, fl | c.int(posix.O_NONBLOCK)) == -1 do return false

	fd_flags := posix.fcntl(fd, .GETFD)
	if fd_flags == -1 do return false
	if posix.fcntl(fd, .SETFD, fd_flags | c.int(posix.FD_CLOEXEC)) == -1 do return false

	return true
}

@(private = "file")
set_socket_buffer_sizes :: proc(fd: posix.FD) {
	buf_size: c.int = MAX_FRAME_BYTES * 2
	posix.setsockopt(fd, posix.SOL_SOCKET, .SNDBUF, &buf_size, size_of(buf_size))
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVBUF, &buf_size, size_of(buf_size))
}

@(private = "file")
send_frame_to_fd :: proc(fd: posix.FD, frame: Frame) -> (written: int, err: Transport_Error) {
	if len(frame.payload) > MAX_PAYLOAD_BYTES do return 0, .Buffer_Full
	needed := FRAME_HEADER_BYTES + len(frame.payload)
	buf := make([]u8, needed, context.temp_allocator)
	n, enc_status := encode_frame(buf, frame)
	if enc_status != .Ok do return 0, .Buffer_Full

	total_written := 0
	for total_written < n {
		bytes_sent := posix.send(fd, raw_data(buf[total_written:]), c.size_t(n - total_written), {.NOSIGNAL})
		if bytes_sent > 0 {
			total_written += int(bytes_sent)
			continue
		}
		if bytes_sent == 0 {
			return total_written, .Disconnected
		}
		err_no := posix.errno()
		if err_no == .EINTR do continue
		if err_no == .EAGAIN || err_no == .EWOULDBLOCK {
			return total_written, .Buffer_Full
		}
		return total_written, .Disconnected
	}
	return total_written, .None
}

@(private = "file")
recv_frame_from_fd :: proc(
	fd: posix.FD,
	read_buf: []u8,
	read_len: ^int,
	timeout_ms: int = 0,
) -> (frame: Frame, consumed: int, status: Codec_Status, disconnected: bool) {
	if read_len^ >= FRAME_HEADER_BYTES {
		f, cons, stat := decode_frame(read_buf[:read_len^])
		if stat == .Ok {
			rem := read_len^ - cons
			if rem > 0 {
				payload_clone := make([]u8, len(f.payload), context.temp_allocator)
				copy(payload_clone, f.payload)
				f.payload = payload_clone
				copy(read_buf[0:], read_buf[cons:read_len^])
			}
			read_len^ = rem
			return f, cons, .Ok, false
		}
		if stat != .Incomplete {
			return {}, 0, stat, false
		}
	}

	for {
		if read_len^ >= len(read_buf) {
			return {}, 0, .Limit_Exceeded, false
		}

		pfd := posix.pollfd{fd = fd, events = {.IN}}
		pres := posix.poll(&pfd, 1, c.int(timeout_ms))
		if pres <= 0 {
			return {}, 0, .Incomplete, false
		}
		if .HUP in pfd.revents && !(.IN in pfd.revents) {
			return {}, 0, .Incomplete, true
		}

		avail := c.size_t(len(read_buf)) - c.size_t(read_len^)
		nr := posix.recv(fd, raw_data(read_buf[read_len^:]), avail, {})
		if nr > 0 {
			read_len^ += int(nr)
			if read_len^ >= FRAME_HEADER_BYTES {
				f, cons, stat := decode_frame(read_buf[:read_len^])
				if stat == .Ok {
					rem := read_len^ - cons
					if rem > 0 {
						payload_clone := make([]u8, len(f.payload), context.temp_allocator)
						copy(payload_clone, f.payload)
						f.payload = payload_clone
						copy(read_buf[0:], read_buf[cons:read_len^])
					}
					read_len^ = rem
					return f, cons, .Ok, false
				}
				if stat != .Incomplete {
					return {}, 0, stat, false
				}
			}
			continue
		}
		if nr == 0 {
			return {}, 0, .Incomplete, true
		}
		err_no := posix.errno()
		if err_no == .EINTR do continue
		if err_no == .EAGAIN || err_no == .EWOULDBLOCK {
			continue
		}
		return {}, 0, .Incomplete, true
	}
}

client_connect :: proc(client: ^Socket_Client, path: string, allocator := context.allocator) -> Transport_Error {
	if client == nil do return .Connect_Failed
	client.allocator = allocator
	client.read_len = 0

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	when ODIN_OS == .Darwin {
		addr.sun_len = c.uchar(size_of(posix.sockaddr_un))
	}
	if len(path) >= len(addr.sun_path) {
		return .Connect_Failed
	}
	for i in 0..<len(path) {
		addr.sun_path[i] = c.char(path[i])
	}
	addr.sun_path[len(path)] = 0

	client.fd = posix.socket(.UNIX, .STREAM)
	if client.fd == -1 {
		return .Socket_Failed
	}

	set_socket_buffer_sizes(client.fd)

	if posix.connect(client.fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(client.fd)
		client.fd = -1
		return .Connect_Failed
	}

	if !set_nonblocking_and_cloexec(client.fd) {
		posix.close(client.fd)
		client.fd = -1
		return .Connect_Failed
	}

	client.read_buf = make([]u8, MAX_FRAME_BYTES * 2, allocator)
	return .None
}

client_send_frame :: proc(client: ^Socket_Client, frame: Frame) -> (written: int, err: Transport_Error) {
	if client == nil || client.fd < 0 do return 0, .Disconnected
	w, send_err := send_frame_to_fd(client.fd, frame)
	if send_err != .None {
		client_close(client)
	}
	return w, send_err
}

client_recv_frame :: proc(client: ^Socket_Client, timeout_ms: int = 0) -> (frame: Frame, consumed: int, status: Codec_Status) {
	if client == nil || client.fd < 0 || client.read_buf == nil do return {}, 0, .Incomplete
	f, cons, stat, disc := recv_frame_from_fd(client.fd, client.read_buf, &client.read_len, timeout_ms)
	if disc {
		posix.close(client.fd)
		client.fd = -1
	}
	return f, cons, stat
}

client_close :: proc(client: ^Socket_Client) {
	if client == nil do return
	if client.fd >= 0 {
		posix.close(client.fd)
		client.fd = -1
	}
	if client.read_buf != nil {
		delete(client.read_buf, client.allocator)
		client.read_buf = nil
	}
	client.read_len = 0
}

server_init :: proc(s: ^Socket_Server, socket_path: string = "", allocator := context.allocator) -> Transport_Error {
	if s == nil do return .Socket_Failed
	s.allocator = allocator
	s.listen_fd = -1
	s.lock_fd = -1
	s.client_count = 0
	for i in 0..<MAX_IPC_CLIENTS {
		s.clients[i] = {}
	}

	resolved_path: string
	if len(socket_path) == 0 {
		p, ok := resolve_default_socket_path(allocator)
		if !ok do return .Dir_Create_Failed
		resolved_path = p
	} else {
		resolved_path = strings.clone(socket_path, allocator)
	}
	s.socket_path = resolved_path

	s.lock_path = fmt.aprintf("%s.lock", resolved_path, allocator = allocator)
	c_lock_path := strings.clone_to_cstring(s.lock_path, context.temp_allocator)

	s.lock_fd = posix.open(c_lock_path, {.RDWR, .CREAT}, posix.mode_t{.IRUSR, .IWUSR})
	if s.lock_fd == -1 {
		delete(s.lock_path, s.allocator)
		s.lock_path = ""
		delete(s.socket_path, s.allocator)
		s.socket_path = ""
		return .Lock_Failed
	}
	posix.fchmod(s.lock_fd, posix.mode_t{.IRUSR, .IWUSR})
	posix.fcntl(s.lock_fd, .SETFD, c.int(posix.FD_CLOEXEC))

	if flock(c.int(s.lock_fd), LOCK_EX | LOCK_NB) != 0 {
		posix.close(s.lock_fd)
		s.lock_fd = -1
		delete(s.lock_path, s.allocator)
		s.lock_path = ""
		delete(s.socket_path, s.allocator)
		s.socket_path = ""
		return .Lock_Failed
	}

	c_sock_path := strings.clone_to_cstring(s.socket_path, context.temp_allocator)
	posix.unlink(c_sock_path)

	s.listen_fd = posix.socket(.UNIX, .STREAM)
	if s.listen_fd == -1 {
		server_close(s)
		return .Socket_Failed
	}

	if !set_nonblocking_and_cloexec(s.listen_fd) {
		server_close(s)
		return .Socket_Failed
	}

	set_socket_buffer_sizes(s.listen_fd)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	when ODIN_OS == .Darwin {
		addr.sun_len = c.uchar(size_of(posix.sockaddr_un))
	}
	if len(s.socket_path) >= len(addr.sun_path) {
		server_close(s)
		return .Bind_Failed
	}
	for i in 0..<len(s.socket_path) {
		addr.sun_path[i] = c.char(s.socket_path[i])
	}
	addr.sun_path[len(s.socket_path)] = 0

	if posix.bind(s.listen_fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		server_close(s)
		return .Bind_Failed
	}

	if posix.chmod(c_sock_path, posix.mode_t{.IRUSR, .IWUSR}) != .OK {
		server_close(s)
		return .Bind_Failed
	}

	if posix.listen(s.listen_fd, 16) != .OK {
		server_close(s)
		return .Listen_Failed
	}

	return .None
}

server_accept :: proc(s: ^Socket_Server) -> (slot_idx: int, err: Transport_Error) {
	if s == nil || s.listen_fd < 0 do return -1, .Socket_Failed

	free_idx := -1
	for i in 0..<MAX_IPC_CLIENTS {
		if !s.clients[i].active {
			free_idx = i
			break
		}
	}
	if free_idx == -1 do return -1, .Buffer_Full

	client_fd := posix.accept(s.listen_fd, nil, nil)
	if client_fd == -1 {
		err_no := posix.errno()
		if err_no == .EAGAIN || err_no == .EWOULDBLOCK {
			return -1, .None
		}
		return -1, .Socket_Failed
	}

	if !set_nonblocking_and_cloexec(client_fd) {
		posix.close(client_fd)
		return -1, .Socket_Failed
	}
	set_socket_buffer_sizes(client_fd)

	if !validate_peer_uid(client_fd) {
		posix.close(client_fd)
		return -1, .Peer_Auth_Failed
	}

	slot := &s.clients[free_idx]
	slot.active = true
	slot.fd = client_fd
	slot.uid = u32(posix.getuid())
	if slot.read_buf == nil {
		slot.read_buf = make([]u8, MAX_FRAME_BYTES * 2, s.allocator)
	}
	slot.read_len = 0
	s.client_count += 1

	return free_idx, .None
}

server_send_frame :: proc(s: ^Socket_Server, slot_idx: int, frame: Frame) -> (written: int, err: Transport_Error) {
	if s == nil || slot_idx < 0 || slot_idx >= MAX_IPC_CLIENTS do return 0, .Socket_Failed
	slot := &s.clients[slot_idx]
	if !slot.active || slot.fd < 0 do return 0, .Disconnected
	w, send_err := send_frame_to_fd(slot.fd, frame)
	if send_err != .None {
		server_disconnect_client(s, slot_idx)
	}
	return w, send_err
}

server_recv_frame :: proc(s: ^Socket_Server, slot_idx: int, timeout_ms: int = 0) -> (frame: Frame, consumed: int, status: Codec_Status) {
	if s == nil || slot_idx < 0 || slot_idx >= MAX_IPC_CLIENTS do return {}, 0, .Incomplete
	slot := &s.clients[slot_idx]
	if !slot.active || slot.fd < 0 || slot.read_buf == nil do return {}, 0, .Incomplete
	f, cons, stat, disc := recv_frame_from_fd(slot.fd, slot.read_buf, &slot.read_len, timeout_ms)
	if disc {
		server_disconnect_client(s, slot_idx)
	}
	return f, cons, stat
}

server_disconnect_client :: proc(s: ^Socket_Server, slot_idx: int) {
	if s == nil || slot_idx < 0 || slot_idx >= MAX_IPC_CLIENTS do return
	slot := &s.clients[slot_idx]
	if !slot.active do return
	if slot.fd >= 0 {
		posix.close(slot.fd)
		slot.fd = -1
	}
	slot.active = false
	slot.read_len = 0
	if slot.read_buf != nil {
		slice.zero(slot.read_buf)
	}
	s.client_count -= 1
}

server_close :: proc(s: ^Socket_Server) {
	if s == nil do return

	for i in 0..<MAX_IPC_CLIENTS {
		if s.clients[i].active {
			server_disconnect_client(s, i)
		}
		if s.clients[i].read_buf != nil {
			delete(s.clients[i].read_buf, s.allocator)
			s.clients[i].read_buf = nil
		}
		s.clients[i].read_len = 0
	}
	s.client_count = 0

	if s.listen_fd >= 0 {
		posix.close(s.listen_fd)
		s.listen_fd = -1
	}

	if len(s.socket_path) > 0 {
		c_sock := strings.clone_to_cstring(s.socket_path, context.temp_allocator)
		posix.unlink(c_sock)
		delete(s.socket_path, s.allocator)
		s.socket_path = ""
	}

	if s.lock_fd >= 0 {
		flock(c.int(s.lock_fd), LOCK_UN)
		posix.close(s.lock_fd)
		s.lock_fd = -1
	}

	if len(s.lock_path) > 0 {
		c_lock := strings.clone_to_cstring(s.lock_path, context.temp_allocator)
		posix.unlink(c_lock)
		delete(s.lock_path, s.allocator)
		s.lock_path = ""
	}
}
