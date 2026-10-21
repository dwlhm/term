package platform_pty_tests

import "core:strings"
import "core:testing"
import "core:time"
import pty "../"

@test
test_ring_buffer :: proc(t: ^testing.T) {
	ring := new(pty.Pty_Ring_Buffer)
	defer free(ring)
	pty.ring_init(ring)
	defer pty.ring_destroy(ring)

	data := []u8{'H', 'E', 'L', 'L', 'O'}
	written := pty.ring_write(ring, data)
	testing.expect_value(t, written, 5)

	avail := pty.ring_available(ring)
	testing.expect_value(t, avail, 5)

	out: [10]u8
	read_n := pty.ring_read(ring, out[:])
	testing.expect_value(t, read_n, 5)
	testing.expect_value(t, string(out[:read_n]), "HELLO")

	testing.expect_value(t, pty.ring_available(ring), 0)

	// Test dynamic auto-grow with 3 MB payload (exceeding initial 256 KB)
	large_payload := make([]u8, 3 * 1024 * 1024, context.temp_allocator)
	for i in 0..<len(large_payload) {
		large_payload[i] = u8((i * 7) & 255)
	}
	large_written := pty.ring_write(ring, large_payload)
	testing.expect_value(t, large_written, len(large_payload))
	testing.expect_value(t, pty.ring_available(ring), len(large_payload))

	large_out := make([]u8, len(large_payload), context.temp_allocator)
	total_read := 0
	for total_read < len(large_payload) {
		chunk_read := pty.ring_read(ring, large_out[total_read:])
		if chunk_read <= 0 do break
		total_read += chunk_read
	}
	testing.expect_value(t, total_read, len(large_payload))
	testing.expect(t, string(large_out) == string(large_payload), "Dynamic ring buffer data must match exactly after auto-grow")
	testing.expect_value(t, pty.ring_available(ring), 0)
}

@test
test_pty_spawn_and_read :: proc(t: ^testing.T) {
	config := pty.Pty_Config{
		shell = "/bin/sh",
		argv  = []string{"-c", "echo ODIN_PTY_OK"},
		rows  = 24,
		cols  = 80,
	}

	handle, err := pty.pty_spawn(config)
	testing.expect(t, err == .None, "pty_spawn failed")
	testing.expect(t, handle != nil, "handle is nil")
	defer pty.pty_close(handle)

	// Wait up to 500ms for output to drain
	out_buf: [1024]u8
	total_read := 0
	start := time.now()

	for time.since(start) < 500 * time.Millisecond {
		n := pty.pty_read_available(handle, out_buf[total_read:])
		total_read += n
		if strings.contains(string(out_buf[:total_read]), "ODIN_PTY_OK") {
			break
		}
		time.sleep(10 * time.Millisecond)
	}

	output_str := string(out_buf[:total_read])
	testing.expect(t, strings.contains(output_str, "ODIN_PTY_OK"), "Expected output 'ODIN_PTY_OK' not found in stream")
}

@test
test_pty_resize :: proc(t: ^testing.T) {
	config := pty.Pty_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	handle, err := pty.pty_spawn(config)
	testing.expect(t, err == .None, "pty_spawn failed")
	defer pty.pty_close(handle)

	ok := pty.pty_resize(handle, 120, 40)
	testing.expect(t, ok, "pty_resize failed")
	testing.expect_value(t, handle.cols, 120)
	testing.expect_value(t, handle.rows, 40)
}

@test
test_pty_foreground_process_and_cwd :: proc(t: ^testing.T) {
	config := pty.Pty_Config{
		shell = "/bin/sh",
		argv  = []string{"-c", "sleep 1"},
		rows  = 24,
		cols  = 80,
	}

	handle, err := pty.pty_spawn(config)
	testing.expect(t, err == .None, "pty_spawn failed")
	testing.expect(t, handle != nil, "handle is nil")
	defer pty.pty_close(handle)

	// Sleep briefly so child process is active in foreground
	time.sleep(50 * time.Millisecond)

	proc_buf: [256]u8
	proc_name := pty.pty_get_foreground_process_name(handle, proc_buf[:])
	testing.expect(t, len(proc_name) > 0, "Expected non-empty foreground process name")
	testing.expect(t, strings.contains(proc_name, "sh") || strings.contains(proc_name, "sleep"), "Process name should be sh or sleep")

	cwd_buf: [1024]u8
	cwd := pty.pty_get_foreground_cwd(handle, cwd_buf[:])
	testing.expect(t, len(cwd) > 0, "Expected non-empty cwd from PTY")
}
