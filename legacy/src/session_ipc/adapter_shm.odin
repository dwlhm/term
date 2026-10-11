package session_ipc

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"

SHM_MAGIC :: [4]u8{'T', 'S', 'H', 'M'}
SHM_VERSION :: u32(1)
SLOT_SIZE :: 1024 * 1024 // 1 MiB
SLOT_COUNT :: 2

SHM_Header :: struct #packed {
	magic:         [4]u8,
	version:       u32,
	seq_write:     u64,
	seq_read:      u64,
	slot_size:     u32,
	slot_count:    u32,
	active_slot:   u32,
	payload_bytes: u32,
}

SHM_Slot_Header :: struct #packed {
	stream_id:     u64,
	sequence:      u64,
	payload_bytes: u32,
	_reserved:     u32,
}

TOTAL_SHM_SIZE :: size_of(SHM_Header) + SLOT_COUNT * SLOT_SIZE
MAX_SHM_PAYLOAD :: SLOT_SIZE - size_of(SHM_Slot_Header)

SHM_Host_Adapter :: struct {
	server:    Socket_Server,
	shm_fd:    posix.FD,
	shm_path:  string,
	mmap_ptr:  rawptr,
	mmap_size: int,
	header:    ^SHM_Header,
	sig_pipe:  [2]posix.FD,
	pipe_path: string,
	owns_mmap: bool,
	allocator: runtime.Allocator,
}

SHM_Client_Adapter :: struct {
	client:    Socket_Client,
	shm_fd:    posix.FD,
	shm_path:  string,
	mmap_ptr:  rawptr,
	mmap_size: int,
	header:    ^SHM_Header,
	sig_pipe:  [2]posix.FD,
	pipe_path: string,
	allocator: runtime.Allocator,
}

@(private = "file")
shm_set_nonblocking_and_cloexec :: proc(fd: posix.FD) -> bool {
	fl := posix.fcntl(fd, .GETFL)
	if fl == -1 do return false
	if posix.fcntl(fd, .SETFL, fl | c.int(posix.O_NONBLOCK)) == -1 do return false

	fd_flags := posix.fcntl(fd, .GETFD)
	if fd_flags == -1 do return false
	if posix.fcntl(fd, .SETFD, fd_flags | c.int(posix.FD_CLOEXEC)) == -1 do return false

	return true
}

shm_host_make_port :: proc(a: ^SHM_Host_Adapter) -> Host_Transport_Port {
	if a != nil {
		if a.server.listen_fd == 0 && a.server.lock_fd == 0 && len(a.server.socket_path) == 0 {
			a.server.listen_fd = -1
			a.server.lock_fd = -1
		}
		if a.shm_fd == 0 do a.shm_fd = -1
		if a.sig_pipe[0] == 0 && a.sig_pipe[1] == 0 {
			a.sig_pipe[0] = -1
			a.sig_pipe[1] = -1
		}
	}
	return Host_Transport_Port{
		user_data         = rawptr(a),
		kind              = .SHM,
		listen_endpoint   = shm_host_listen_endpoint,
		accept_client     = shm_host_accept_client,
		send_frame        = shm_host_send_frame,
		recv_frame        = shm_host_recv_frame,
		publish_snapshot  = shm_host_publish_snapshot,
		disconnect_client = shm_host_disconnect_client,
		close_endpoint    = shm_host_close_endpoint,
	}
}

shm_host_listen_endpoint :: proc(user_data: rawptr, endpoint: string) -> bool {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil do return false
	if a.allocator.procedure == nil do a.allocator = context.allocator

	// 1. Initialize control socket
	err := server_init(&a.server, endpoint, a.allocator)
	if err != .None do return false

	// 2. Set up shared memory mapped file
	if strings.has_suffix(endpoint, ".sock") {
		a.shm_path = fmt.aprintf("%s.dat", endpoint[:len(endpoint) - 5], allocator = a.allocator)
	} else {
		a.shm_path = fmt.aprintf("%s.dat", endpoint, allocator = a.allocator)
	}
	c_shm := strings.clone_to_cstring(a.shm_path, context.temp_allocator)
	posix.unlink(c_shm)

	a.shm_fd = posix.open(c_shm, {.RDWR, .CREAT}, posix.mode_t{.IRUSR, .IWUSR})
	if a.shm_fd < 0 {
		shm_host_close_endpoint(a)
		return false
	}
	shm_set_nonblocking_and_cloexec(a.shm_fd)

	if posix.ftruncate(a.shm_fd, posix.off_t(TOTAL_SHM_SIZE)) != .OK {
		shm_host_close_endpoint(a)
		return false
	}

	a.mmap_size = TOTAL_SHM_SIZE
	a.mmap_ptr = posix.mmap(nil, c.size_t(TOTAL_SHM_SIZE), {.READ, .WRITE}, {.SHARED}, a.shm_fd, 0)
	if a.mmap_ptr == posix.MAP_FAILED || a.mmap_ptr == nil {
		shm_host_close_endpoint(a)
		return false
	}
	a.owns_mmap = true

	a.header = (^SHM_Header)(a.mmap_ptr)
	a.header.magic = SHM_MAGIC
	a.header.version = SHM_VERSION
	a.header.seq_write = 0
	a.header.seq_read = 0
	a.header.slot_size = SLOT_SIZE
	a.header.slot_count = SLOT_COUNT
	a.header.active_slot = 0
	a.header.payload_bytes = 0

	// 3. Set up event signal pipe (FIFO) unless already pre-initialized
	if a.sig_pipe[1] < 0 {
		a.pipe_path = fmt.aprintf("%s.pipe", endpoint, allocator = a.allocator)
		c_pipe := strings.clone_to_cstring(a.pipe_path, context.temp_allocator)
		posix.unlink(c_pipe)
		if posix.mkfifo(c_pipe, posix.mode_t{.IRUSR, .IWUSR}) != .OK {
			shm_host_close_endpoint(a)
			return false
		}
		// Open RDWR so write won't block waiting for a reader and won't trigger SIGPIPE
		a.sig_pipe[1] = posix.open(c_pipe, {.RDWR, .NONBLOCK})
		if a.sig_pipe[1] < 0 {
			shm_host_close_endpoint(a)
			return false
		}
		shm_set_nonblocking_and_cloexec(a.sig_pipe[1])
	}

	return true
}

shm_host_accept_client :: proc(user_data: rawptr) -> (client_id: int, ok: bool) {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil do return -1, false
	slot, err := server_accept(&a.server)
	if err != .None || slot < 0 do return -1, false
	return slot, true
}

shm_host_send_frame :: proc(user_data: rawptr, client_id: int, frame: Frame) -> (written: int, err: Transport_Error) {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil do return 0, .Socket_Failed
	return server_send_frame(&a.server, client_id, frame)
}

shm_host_recv_frame :: proc(user_data: rawptr, client_id: int) -> (frame: Frame, consumed: int, status: Codec_Status) {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil do return {}, 0, .Incomplete
	return server_recv_frame(&a.server, client_id)
}

shm_host_publish_snapshot :: proc(
	user_data: rawptr,
	client_id: int,
	stream_id: u64,
	seq: u64,
	payload: []u8,
) -> (written: int, err: Transport_Error) {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil || a.header == nil || a.mmap_ptr == nil do return 0, .Socket_Failed
	if len(payload) > MAX_SHM_PAYLOAD do return 0, .Buffer_Full

	// Double buffering: write to inactive slot
	active := a.header.active_slot
	next_slot := (active + 1) % a.header.slot_count

	slot_offset := size_of(SHM_Header) + int(next_slot) * SLOT_SIZE
	slot_hdr := (^SHM_Slot_Header)(uintptr(a.mmap_ptr) + uintptr(slot_offset))
	slot_hdr.stream_id = stream_id
	slot_hdr.sequence = seq
	slot_hdr.payload_bytes = u32(len(payload))

	payload_dst := rawptr(uintptr(slot_hdr) + size_of(SHM_Slot_Header))
	if len(payload) > 0 {
		copy(slice.from_ptr((^u8)(payload_dst), len(payload)), payload)
	}

	// Atomic seqlock: odd during update, even when committed
	_ = sync.atomic_add(&a.header.seq_write, 1)
	sync.atomic_thread_fence(.Release)

	a.header.active_slot = next_slot
	a.header.payload_bytes = u32(len(payload))

	sync.atomic_thread_fence(.Release)
	_ = sync.atomic_add(&a.header.seq_write, 1)

	// Notification signaling: write 1 byte to signal pipe
	if a.sig_pipe[1] >= 0 {
		sig_b: u8 = 1
		_ = posix.write(a.sig_pipe[1], &sig_b, 1)
	}

	return len(payload), .None
}

shm_host_disconnect_client :: proc(user_data: rawptr, client_id: int) {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil do return
	server_disconnect_client(&a.server, client_id)
}

shm_host_close_endpoint :: proc(user_data: rawptr) {
	a := (^SHM_Host_Adapter)(user_data)
	if a == nil do return

	server_close(&a.server)

	if a.mmap_ptr != nil && a.mmap_ptr != posix.MAP_FAILED {
		_ = posix.munmap(a.mmap_ptr, c.size_t(a.mmap_size))
		a.mmap_ptr = nil
	}
	if a.shm_fd >= 0 {
		posix.close(a.shm_fd)
		a.shm_fd = -1
	}
	if len(a.shm_path) > 0 {
		c_path := strings.clone_to_cstring(a.shm_path, context.temp_allocator)
		posix.unlink(c_path)
		delete(a.shm_path, a.allocator)
		a.shm_path = ""
	}
	if a.sig_pipe[1] >= 0 {
		posix.close(a.sig_pipe[1])
		a.sig_pipe[1] = -1
	}
	if a.sig_pipe[0] >= 0 {
		posix.close(a.sig_pipe[0])
		a.sig_pipe[0] = -1
	}
	if len(a.pipe_path) > 0 {
		c_pipe := strings.clone_to_cstring(a.pipe_path, context.temp_allocator)
		posix.unlink(c_pipe)
		delete(a.pipe_path, a.allocator)
		a.pipe_path = ""
	}
}

shm_client_make_port :: proc(a: ^SHM_Client_Adapter) -> Client_Transport_Port {
	if a != nil {
		if a.client.fd == 0 && a.client.read_buf == nil {
			a.client.fd = -1
		}
		if a.shm_fd == 0 do a.shm_fd = -1
		if a.sig_pipe[0] == 0 && a.sig_pipe[1] == 0 {
			a.sig_pipe[0] = -1
			a.sig_pipe[1] = -1
		}
	}
	return Client_Transport_Port{
		user_data        = rawptr(a),
		kind             = .SHM,
		connect_endpoint = shm_client_connect_endpoint,
		send_frame       = shm_client_send_frame,
		recv_frame       = shm_client_recv_frame,
		read_snapshot    = shm_client_read_snapshot,
		close_endpoint   = shm_client_close_endpoint,
	}
}

shm_client_connect_endpoint :: proc(user_data: rawptr, endpoint: string) -> Transport_Error {
	a := (^SHM_Client_Adapter)(user_data)
	if a == nil do return .Connect_Failed
	if a.allocator.procedure == nil do a.allocator = context.allocator

	// 1. Connect control socket
	c_err := client_connect(&a.client, endpoint, a.allocator)
	if c_err != .None do return c_err

	// 2. Open and map shared memory file
	if strings.has_suffix(endpoint, ".sock") {
		a.shm_path = fmt.aprintf("%s.dat", endpoint[:len(endpoint) - 5], allocator = a.allocator)
	} else {
		a.shm_path = fmt.aprintf("%s.dat", endpoint, allocator = a.allocator)
	}
	c_shm := strings.clone_to_cstring(a.shm_path, context.temp_allocator)
	a.shm_fd = posix.open(c_shm, {.RDWR}, posix.mode_t{.IRUSR, .IWUSR})
	if a.shm_fd < 0 {
		shm_client_close_endpoint(a)
		return .Connect_Failed
	}
	shm_set_nonblocking_and_cloexec(a.shm_fd)

	a.mmap_size = TOTAL_SHM_SIZE
	a.mmap_ptr = posix.mmap(nil, c.size_t(TOTAL_SHM_SIZE), {.READ, .WRITE}, {.SHARED}, a.shm_fd, 0)
	if a.mmap_ptr == posix.MAP_FAILED || a.mmap_ptr == nil {
		shm_client_close_endpoint(a)
		return .Connect_Failed
	}
	a.header = (^SHM_Header)(a.mmap_ptr)

	// 3. Open event signal pipe (FIFO) unless already pre-initialized
	if a.sig_pipe[0] < 0 {
		a.pipe_path = fmt.aprintf("%s.pipe", endpoint, allocator = a.allocator)
		c_pipe := strings.clone_to_cstring(a.pipe_path, context.temp_allocator)
		a.sig_pipe[0] = posix.open(c_pipe, {.NONBLOCK})
		if a.sig_pipe[0] < 0 {
			shm_client_close_endpoint(a)
			return .Connect_Failed
		}
		shm_set_nonblocking_and_cloexec(a.sig_pipe[0])
	}

	return .None
}

shm_client_send_frame :: proc(user_data: rawptr, frame: Frame) -> (written: int, err: Transport_Error) {
	a := (^SHM_Client_Adapter)(user_data)
	if a == nil do return 0, .Disconnected
	return client_send_frame(&a.client, frame)
}

shm_client_recv_frame :: proc(user_data: rawptr) -> (frame: Frame, consumed: int, status: Codec_Status) {
	a := (^SHM_Client_Adapter)(user_data)
	if a == nil do return {}, 0, .Incomplete
	return client_recv_frame(&a.client)
}

shm_client_read_snapshot_memory :: proc(a: ^SHM_Client_Adapter, out_buf: []u8) -> (n: int, seq: u64, ok: bool) {
	if a == nil || a.header == nil || a.mmap_ptr == nil do return 0, 0, false

	for _ in 0..<20 {
		s1 := sync.atomic_load(&a.header.seq_write)
		if (s1 & 1) != 0 {
			sync.cpu_relax()
			continue
		}
		sync.atomic_thread_fence(.Acquire)

		active := a.header.active_slot
		if active >= a.header.slot_count do return 0, 0, false

		slot_offset := size_of(SHM_Header) + int(active) * SLOT_SIZE
		slot_hdr := (^SHM_Slot_Header)(uintptr(a.mmap_ptr) + uintptr(slot_offset))
		payload_len := int(slot_hdr.payload_bytes)
		if payload_len > len(out_buf) do return 0, 0, false

		if payload_len > 0 {
			payload_src := rawptr(uintptr(slot_hdr) + size_of(SHM_Slot_Header))
			copy(out_buf[:payload_len], slice.from_ptr((^u8)(payload_src), payload_len))
		}

		sync.atomic_thread_fence(.Acquire)
		s2 := sync.atomic_load(&a.header.seq_write)
		if s1 == s2 {
			sync.atomic_store(&a.header.seq_read, s2)
			return payload_len, slot_hdr.sequence, true
		}
		sync.cpu_relax()
	}
	return 0, 0, false
}

shm_client_read_snapshot :: proc(user_data: rawptr, out_buf: []u8) -> (n: int, seq: u64, ok: bool) {
	a := (^SHM_Client_Adapter)(user_data)
	if a == nil do return 0, 0, false

	// If sig_pipe[0] is valid, wait for signal notification
	if a.sig_pipe[0] >= 0 {
		pfd := posix.pollfd{fd = a.sig_pipe[0], events = {.IN}}
		res := posix.poll(&pfd, 1, 0)
		if res > 0 && (.IN in pfd.revents) {
			dummy: [64]u8
			_ = posix.read(a.sig_pipe[0], &dummy[0], size_of(dummy))
		} else if res <= 0 {
			return 0, 0, false
		}
	}

	return shm_client_read_snapshot_memory(a, out_buf)
}

shm_client_close_endpoint :: proc(user_data: rawptr) {
	a := (^SHM_Client_Adapter)(user_data)
	if a == nil do return

	client_close(&a.client)

	if a.mmap_ptr != nil && a.mmap_ptr != posix.MAP_FAILED {
		_ = posix.munmap(a.mmap_ptr, c.size_t(a.mmap_size))
		a.mmap_ptr = nil
	}
	if a.shm_fd >= 0 {
		posix.close(a.shm_fd)
		a.shm_fd = -1
	}
	if len(a.shm_path) > 0 {
		delete(a.shm_path, a.allocator)
		a.shm_path = ""
	}
	if a.sig_pipe[0] >= 0 {
		posix.close(a.sig_pipe[0])
		a.sig_pipe[0] = -1
	}
	if a.sig_pipe[1] >= 0 {
		posix.close(a.sig_pipe[1])
		a.sig_pipe[1] = -1
	}
	if len(a.pipe_path) > 0 {
		delete(a.pipe_path, a.allocator)
		a.pipe_path = ""
	}
}
