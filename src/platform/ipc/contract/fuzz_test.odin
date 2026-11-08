package platform_ipc_contract

// P24: 10 000 random frames (fixed seed) from peers that passed HELLO. The
// server drops them and reconnects are allowed; a real client keeps getting
// answers throughout, and every byte the package allocated is freed.

import "core:mem"
import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

FUZZ_FRAMES :: 10_000
FUZZ_SEED   :: u64(0x5eed_0024)

// xorshift64: the same seed sends the same frames on every run.
@(private = "file")
_next :: proc(s: ^u64) -> u64 {
	s^ ~= s^ << 13
	s^ ~= s^ >> 7
	s^ ~= s^ << 17
	return s^
}

// _send_random writes one random frame: any kind, mostly channel 0 with a
// small req up front, sometimes a length far past max_payload with no body.
@(private = "file")
_send_random :: proc(fd: posix.FD, s: ^u64) -> bool {
	body: [72]u8
	for &b in body do b = u8(_next(s))
	n := int(_next(s) % 64)
	channel := u32(0) if _next(s) % 4 != 0 else u32(_next(s))
	if channel == 0 && n >= 4 {
		req := u32le_bytes(u32(_next(s) % 4))
		copy(body[:4], req[:])
	}
	declared := u32(n)
	if _next(s) % 8 == 0 do declared = 0xffff_fff0
	head: [FRAME_HEAD]u8
	return raw_write(fd, frame_head(head[:], u8(_next(s)), channel, int(declared))) && raw_write(fd, body[:n])
}

// _gone drains what the server sent; true once it has closed fd.
@(private = "file")
_gone :: proc(fd: posix.FD) -> bool {
	scratch: [4096]u8
	for raw_wait(fd, 0) {
		if posix.recv(fd, raw_data(scratch[:]), len(scratch), {}) <= 0 do return true
	}
	return false
}

@(test)
test_P24_fuzzed_frames_hurt_only_their_peer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 120 * time.Second)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	dir := test_dir()
	defer test_dir_remove(dir)
	drops := _fuzz(t, ipc.Endpoint{dir, "s"}, mem.tracking_allocator(&track))
	testing.expect(t, drops > 0, "no fuzzed peer was ever dropped")
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations left after close", len(track.allocation_map))
}

// _fuzz runs owner, client and fuzzer on allocator and closes them all.
@(private = "file")
_fuzz :: proc(t: ^testing.T, at: ipc.Endpoint, allocator: mem.Allocator) -> (drops: int) {
	context.allocator = allocator
	o: Owner
	if !owner_open(t, &o, at) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, at) do return
	defer ipc.client_close(&c)
	seed := FUZZ_SEED
	fd := posix.FD(-1)
	defer if fd >= 0 do posix.close(fd)
	for sent := 1; sent <= FUZZ_FRAMES; sent += 1 {
		if fd < 0 {
			fd = raw_dial(at)
			if !testing.expect(t, fd >= 0 && raw_hello(fd, settle_ms = 0), "the fuzzer cannot get in") do return
		}
		if !_send_random(fd, &seed) || _gone(fd) {
			posix.close(fd)
			fd, drops = -1, drops + 1
		}
		if sent % 500 == 0 && !ping(t, &c, u32(sent), {timeout = 2 * time.Second}) do return
	}
	return
}
