package main

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"
import "core:time"
import parser "../../parser"
import pty "../../platform/pty"
import ipc "../../session_ipc"
import termgrid "../../terminal"

TOTAL_FLOOD_BYTES :: 300 * 1024 * 1024 // Exactly 300 Megabytes (Ghostty / Casey Muratori)
CHUNK_SIZE :: 256 * 1024               // 256 KiB chunk per snapshot
ASRW_TOTAL_OPS :: 50000                // 50,000 rapid cursor jumps & writes (vtebench)
ASRW_BATCH_SIZE :: 50                  // 50 ops per delta snapshot (1,000 delta snapshots)
TRUECOLOR_TOTAL_BYTES :: 2_000_000     // 2 MB dense 24-bit TrueColor sequences (Kitty)
UNICODE_TOTAL_BYTES :: 2_000_000       // 2 MB CJK & wide Unicode characters (Kitty)
INTERACTIVE_LOAD_ITERS :: 1000         // 1,000 keystroke samples under heavy PTY flood (Dan Luu)

Latency_Stats :: struct {
	min_us:  f64,
	p50_us:  f64,
	p95_us:  f64,
	p99_us:  f64,
	p999_us: f64,
	max_us:  f64,
	mean_us: f64,
}

Flood_Stats :: struct {
	total_bytes:    u64,
	elapsed_sec:    f64,
	throughput_mbs: f64,
	frames_sent:    int,
	frames_recv:    int,
}

ASRW_Stats :: struct {
	total_ops:   int,
	elapsed_sec: f64,
	ops_per_sec: f64,
	delta_bytes: u64,
	delta_mb_s:  f64,
	frames_sent: int,
	frames_recv: int,
}

Color_Stats :: struct {
	total_bytes:    u64,
	total_cells:    int,
	elapsed_sec:    f64,
	throughput_mbs: f64,
	cells_per_sec:  f64,
	frames_sent:    int,
	frames_recv:    int,
}

Unicode_Stats :: struct {
	total_bytes:        u64,
	total_codepoints:   int,
	elapsed_sec:        f64,
	throughput_mbs:     f64,
	codepoints_per_sec: f64,
	frames_sent:        int,
	frames_recv:        int,
}

Adapter_Benchmark_Result :: struct {
	name:         string,
	memory_model: string,
	dense_flood:  Flood_Stats,
	asrw:         ASRW_Stats,
	truecolor:    Color_Stats,
	unicode:      Unicode_Stats,
	jitter_load:  Latency_Stats,
}

Transport_Harness :: struct {
	kind:          ipc.Transport_Kind,
	host_port:     ipc.Host_Transport_Port,
	client_port:   ipc.Client_Transport_Port,
	client_id:     int,
	endpoint:      string,
	host_uds:      ipc.UDS_Host_Adapter,
	client_uds:    ipc.UDS_Client_Adapter,
	host_shm:      ipc.SHM_Host_Adapter,
	client_shm:    ipc.SHM_Client_Adapter,
	host_hybrid:   ipc.Hybrid_Host_Adapter,
	client_hybrid: ipc.Hybrid_Client_Adapter,
}

harness_init :: proc(h: ^Transport_Harness, kind: ipc.Transport_Kind, prefix: string) -> bool {
	h.kind = kind
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	h.endpoint = fmt.aprintf("/tmp/term_bench_%v_%s_%d_%d.sock", kind, prefix, pid, now)

	switch kind {
	case .UDS:
		h.host_port = ipc.uds_host_make_port(&h.host_uds)
		h.client_port = ipc.uds_client_make_port(&h.client_uds)
	case .SHM:
		h.host_port = ipc.shm_host_make_port(&h.host_shm)
		h.client_port = ipc.shm_client_make_port(&h.client_shm)
	case .Hybrid:
		h.host_port = ipc.hybrid_host_make_port(&h.host_hybrid)
		h.client_port = ipc.hybrid_client_make_port(&h.client_hybrid)
	}

	if !h.host_port.listen_endpoint(h.host_port.user_data, h.endpoint) {
		fmt.eprintln("Failed to listen on endpoint:", h.endpoint)
		return false
	}

	if c_err := h.client_port.connect_endpoint(h.client_port.user_data, h.endpoint); c_err != .None {
		fmt.eprintln("Failed to connect to endpoint:", h.endpoint, c_err)
		h.host_port.close_endpoint(h.host_port.user_data)
		return false
	}

	cid, ok := h.host_port.accept_client(h.host_port.user_data)
	if !ok {
		fmt.eprintln("Failed to accept client connection")
		h.client_port.close_endpoint(h.client_port.user_data)
		h.host_port.close_endpoint(h.host_port.user_data)
		return false
	}
	h.client_id = cid
	return true
}

harness_close :: proc(h: ^Transport_Harness) {
	h.client_port.close_endpoint(h.client_port.user_data)
	h.host_port.close_endpoint(h.host_port.user_data)
	delete(h.endpoint)
	h.endpoint = ""
}

_bench_rand :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^
}

main :: proc() {
	fmt.println("====================================================================================================")
	fmt.println("               EXTREME 5-WORKLOAD COMPARATIVE TRANSPORT BENCHMARK SUITE                             ")
	fmt.println("       Ghostty / Alacritty (VTEbench) / Kitty / Casey Muratori / Dan Luu Standard Matrix            ")
	fmt.println("          Comparing: 1) Pure UDS | 2) Pure POSIX SHM | 3) Hybrid UDS + SHM                          ")
	fmt.println("====================================================================================================")
	fmt.printf("Workload 1: 300 MB Dense PTY Stream (Ghostty / Casey Muratori)\n")
	fmt.printf("Workload 2: VTEbench Alt-Screen Random Write (50,000 cursor jumps & writes)\n")
	fmt.printf("Workload 3: Kitty SGR 24-bit TrueColor Storm (2,000,000 bytes)\n")
	fmt.printf("Workload 4: Kitty CJK / Unicode Wide Character Flood (2,000,000 bytes)\n")
	fmt.printf("Workload 5: Interactive Keystroke Responsiveness & Jitter Under Heavy Load (1,000 keystrokes)\n")
	fmt.println("")

	res_uds := run_adapter_benchmark(.UDS)
	fmt.println("")

	res_shm := run_adapter_benchmark(.SHM)
	fmt.println("")

	res_hybrid := run_adapter_benchmark(.Hybrid)
	fmt.println("")

	print_comparative_table(res_uds, res_shm, res_hybrid)
}

run_adapter_benchmark :: proc(kind: ipc.Transport_Kind) -> Adapter_Benchmark_Result {
	name: string
	memory_model: string
	switch kind {
	case .UDS:
		name = "Adapter 1: Pure UDS"
		memory_model = "Socket Kernel Buffer Copy"
	case .SHM:
		name = "Adapter 2: Pure POSIX SHM"
		memory_model = "Zero-Copy Double-Buffer SHM"
	case .Hybrid:
		name = "Adapter 3: Hybrid UDS + SHM"
		memory_model = "Zero-Copy SHM + 40B UDS Notify"
	}

	fmt.printf(">>> Running Extreme 5-Workload Benchmarks for %s ...\n", name)

	// Workload 1: 300 MB Dense PTY Stream (Ghostty / Casey Muratori)
	fmt.print("  [1/5] 300 MB Dense PTY Stream... ")
	h_flood: Transport_Harness
	dense_flood: Flood_Stats
	if harness_init(&h_flood, kind, "flood") {
		dense_flood = bench_vte_dense_flood(&h_flood.host_port, &h_flood.client_port, h_flood.client_id)
		harness_close(&h_flood)
		fmt.printf("done. (%.2f MB/s in %.2f s, %d frames)\n", dense_flood.throughput_mbs, dense_flood.elapsed_sec, dense_flood.frames_recv)
	} else {
		fmt.println("FAILED to initialize harness")
	}

	// Workload 2: VTEbench Alt-Screen Random Write (ASRW)
	fmt.print("  [2/5] VTEbench Alt-Screen Random Write (50,000 ops)... ")
	h_asrw: Transport_Harness
	asrw: ASRW_Stats
	if harness_init(&h_asrw, kind, "asrw") {
		asrw = bench_vte_asrw(&h_asrw.host_port, &h_asrw.client_port, h_asrw.client_id)
		harness_close(&h_asrw)
		fmt.printf("done. (%.0f ops/s, %.2f MB/s delta in %.1f ms)\n", asrw.ops_per_sec, asrw.delta_mb_s, asrw.elapsed_sec * 1000.0)
	} else {
		fmt.println("FAILED to initialize harness")
	}

	// Workload 3: Kitty SGR 24-bit TrueColor Storm
	fmt.print("  [3/5] Kitty SGR 24-bit TrueColor Storm (2 MB)... ")
	h_tc: Transport_Harness
	truecolor: Color_Stats
	if harness_init(&h_tc, kind, "truecolor") {
		truecolor = bench_kitty_truecolor_storm(&h_tc.host_port, &h_tc.client_port, h_tc.client_id)
		harness_close(&h_tc)
		fmt.printf("done. (%.0f cells/s, %.2f MB/s in %.1f ms)\n", truecolor.cells_per_sec, truecolor.throughput_mbs, truecolor.elapsed_sec * 1000.0)
	} else {
		fmt.println("FAILED to initialize harness")
	}

	// Workload 4: Kitty CJK / Unicode Wide Character Flood
	fmt.print("  [4/5] Kitty CJK / Wide Unicode Flood (2 MB)... ")
	h_uni: Transport_Harness
	unicode: Unicode_Stats
	if harness_init(&h_uni, kind, "unicode") {
		unicode = bench_kitty_unicode_wide(&h_uni.host_port, &h_uni.client_port, h_uni.client_id)
		harness_close(&h_uni)
		fmt.printf("done. (%.0f codepoints/s, %.2f MB/s in %.1f ms)\n", unicode.codepoints_per_sec, unicode.throughput_mbs, unicode.elapsed_sec * 1000.0)
	} else {
		fmt.println("FAILED to initialize harness")
	}

	// Workload 5: Interactive Keystroke Responsiveness & Jitter Under Heavy Load
	fmt.print("  [5/5] Typometer Keystroke Responsiveness & Jitter Under Load (1,000 samples)... ")
	h_jit: Transport_Harness
	jitter_load: Latency_Stats
	if harness_init(&h_jit, kind, "jitter") {
		jitter_load = bench_interactive_jitter_under_load(&h_jit.host_port, &h_jit.client_port, h_jit.client_id)
		harness_close(&h_jit)
		fmt.printf("done. (p50: %.1f µs, p95: %.1f µs, p99: %.1f µs, p99.9: %.1f µs)\n", jitter_load.p50_us, jitter_load.p95_us, jitter_load.p99_us, jitter_load.p999_us)
	} else {
		fmt.println("FAILED to initialize harness")
	}

	return Adapter_Benchmark_Result{
		name         = name,
		memory_model = memory_model,
		dense_flood  = dense_flood,
		asrw         = asrw,
		truecolor    = truecolor,
		unicode      = unicode,
		jitter_load  = jitter_load,
	}
}

// 1. 300 MB Dense PTY Stream (Ghostty / Casey Muratori)
bench_vte_dense_flood :: proc(
	host_port: ^ipc.Host_Transport_Port,
	client_port: ^ipc.Client_Transport_Port,
	client_id: int,
) -> Flood_Stats {
	term := new(termgrid.Terminal)
	termgrid.terminal_init(term, 24, 80)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}

	prs: parser.Parser
	parser.parser_init(&prs)

	cmd := fmt.aprintf("stty -onlcr 2>/dev/null; head -c %d /dev/zero", TOTAL_FLOOD_BYTES)
	defer delete(cmd)

	p: pty.Pty
	if !pty.pty_spawn(&p, 24, 80, "/bin/sh", {"-c", cmd}) {
		fmt.eprintln("Failed to spawn PTY child producer for 300MB flood")
		return {}
	}
	defer {
		if p.pid > 0 {
			posix.kill(posix.pid_t(p.pid), .SIGKILL)
			status: c.int
			posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
			p.pid = -1
		}
		pty.pty_close(&p)
	}

	drain_buf := make([]u8, CHUNK_SIZE)
	defer delete(drain_buf)

	client_buf := make([]u8, CHUNK_SIZE)
	defer delete(client_buf)

	total_drained := u64(0)
	frames_sent := 0
	frames_recv := 0

	t0 := time.tick_now()
	seq := u64(1)

	for total_drained < TOTAL_FLOOD_BYTES {
		n, eof := pty.pty_drain(&p, drain_buf, len(drain_buf))
		if n > 0 {
			total_drained += u64(n)
			frames_sent += 1

			// Parse incoming PTY stream through terminal parser into Terminal grid
			parser.parse_chunk(&prs, term, drain_buf[:n])

			// Publish snapshot through the transport port
			_, send_err := host_port.publish_snapshot(
				host_port.user_data,
				client_id,
				1,
				seq,
				drain_buf[:n],
			)
			seq += 1

			if send_err == .None {
				rn, _, rok := client_port.read_snapshot(client_port.user_data, client_buf)
				if rok && rn > 0 {
					frames_recv += 1
				}
			}
			free_all(context.temp_allocator)
			continue
		}

		if eof do break

		// Non-blocking drain returned EAGAIN, poll PTY master fd
		pfd := posix.pollfd{fd = posix.FD(p.master), events = {.IN}}
		_ = posix.poll(&pfd, 1, 50)
	}

	elapsed := time.duration_seconds(time.tick_since(t0))
	if elapsed <= 0.000001 do elapsed = 0.000001

	mb := f64(total_drained) / (1024.0 * 1024.0)
	mb_s := mb / elapsed

	return Flood_Stats{
		total_bytes    = total_drained,
		elapsed_sec    = elapsed,
		throughput_mbs = mb_s,
		frames_sent    = frames_sent,
		frames_recv    = frames_recv,
	}
}

// 2. VTEbench Alt-Screen Random Write (ASRW)
bench_vte_asrw :: proc(
	host_port: ^ipc.Host_Transport_Port,
	client_port: ^ipc.Client_Transport_Port,
	client_id: int,
) -> ASRW_Stats {
	term := new(termgrid.Terminal)
	termgrid.terminal_init(term, 24, 80)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}

	p: parser.Parser
	parser.parser_init(&p)

	// Switch terminal to Alternate Screen
	alt_enter := "\x1b[?1049h"
	parser.parse_chunk(&p, term, transmute([]u8)alt_enter)

	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(snap_buf)

	client_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(client_buf)

	delta_bytes := u64(0)
	frames_sent := 0
	frames_recv := 0
	seq := u64(1)
	rng: u64 = 0x123456789ABCDEF0

	t0 := time.tick_now()

	seq_buf: [32]u8
	batch_count := ASRW_TOTAL_OPS / ASRW_BATCH_SIZE

	for _ in 0..<batch_count {
		for _ in 0..<ASRW_BATCH_SIZE {
			r := int((_bench_rand(&rng) % 24) + 1)
			c := int((_bench_rand(&rng) % 80) + 1)
			ch := u8('A' + (_bench_rand(&rng) % 26))
			s := fmt.bprintf(seq_buf[:], "\x1b[%d;%dH%c", r, c, ch)
			parser.parse_chunk(&p, term, transmute([]u8)s)
		}

		// Compute delta damage and encode delta snapshot
		snap_hdr := ipc.Snapshot_Header{
			workspace_id = 1,
			pane_id      = 1,
			snapshot_rev = seq,
			topology_rev = 1,
			kind         = .Delta,
		}

		snap_len, enc_err := ipc.encode_terminal_snapshot(snap_buf, term, snap_hdr)
		if enc_err == .None && snap_len > 0 {
			_, send_err := host_port.publish_snapshot(
				host_port.user_data,
				client_id,
				1,
				seq,
				snap_buf[:snap_len],
			)
			seq += 1

			if send_err == .None {
				frames_sent += 1
				rn, _, rok := client_port.read_snapshot(client_port.user_data, client_buf)
				if rok && rn > 0 {
					frames_recv += 1
					delta_bytes += u64(rn)
				}
			}
		}

		termgrid.terminal_clear_damage(term)
		free_all(context.temp_allocator)
	}

	elapsed := time.duration_seconds(time.tick_since(t0))
	if elapsed <= 0.000001 do elapsed = 0.000001

	// Switch back from Alternate Screen
	alt_exit := "\x1b[?1049l"
	parser.parse_chunk(&p, term, transmute([]u8)alt_exit)

	ops_per_sec := f64(ASRW_TOTAL_OPS) / elapsed
	delta_mb := f64(delta_bytes) / (1024.0 * 1024.0)
	delta_mb_s := delta_mb / elapsed

	return ASRW_Stats{
		total_ops   = ASRW_TOTAL_OPS,
		elapsed_sec = elapsed,
		ops_per_sec = ops_per_sec,
		delta_bytes = delta_bytes,
		delta_mb_s  = delta_mb_s,
		frames_sent = frames_sent,
		frames_recv = frames_recv,
	}
}

// 3. Kitty SGR 24-bit TrueColor Storm
bench_kitty_truecolor_storm :: proc(
	host_port: ^ipc.Host_Transport_Port,
	client_port: ^ipc.Client_Transport_Port,
	client_id: int,
) -> Color_Stats {
	term := new(termgrid.Terminal)
	termgrid.terminal_init(term, 24, 80)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}

	p: parser.Parser
	parser.parser_init(&p)

	CHUNK_CAP :: 64 * 1024

	// Pre-generate 2 MB buffer of SGR 24-bit TrueColor sequences
	raw_buf := make([]u8, TRUECOLOR_TOTAL_BYTES + 128)
	defer delete(raw_buf)

	buf_pos := 0
	cell_count := 0
	r, g, b := 0, 0, 0
	for buf_pos < TRUECOLOR_TOTAL_BYTES {
		r = (r + 17) & 0xFF
		g = (g + 31) & 0xFF
		b = (b + 47) & 0xFF
		s := fmt.bprintf(
			raw_buf[buf_pos:],
			"\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm#",
			r, g, b, 255 - r, 255 - g, 255 - b,
		)
		buf_pos += len(s)
		cell_count += 1
	}
	total_bytes := u64(buf_pos)

	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(snap_buf)

	client_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(client_buf)

	frames_sent := 0
	frames_recv := 0
	seq := u64(1)

	t0 := time.tick_now()

	offset := 0
	for offset < buf_pos {
		chunk_len := min(CHUNK_CAP, buf_pos - offset)
		parser.parse_chunk(&p, term, raw_buf[offset:offset + chunk_len])
		offset += chunk_len

		snap_hdr := ipc.Snapshot_Header{
			workspace_id = 1,
			pane_id      = 1,
			snapshot_rev = seq,
			topology_rev = 1,
			kind         = .Delta,
		}

		snap_len, enc_err := ipc.encode_terminal_snapshot(snap_buf, term, snap_hdr)
		if enc_err == .None && snap_len > 0 {
			_, send_err := host_port.publish_snapshot(
				host_port.user_data,
				client_id,
				1,
				seq,
				snap_buf[:snap_len],
			)
			seq += 1

			if send_err == .None {
				frames_sent += 1
				rn, _, rok := client_port.read_snapshot(client_port.user_data, client_buf)
				if rok && rn > 0 {
					frames_recv += 1
				}
			}
		}

		termgrid.terminal_clear_damage(term)
		free_all(context.temp_allocator)
	}

	elapsed := time.duration_seconds(time.tick_since(t0))
	if elapsed <= 0.000001 do elapsed = 0.000001

	mb := f64(total_bytes) / (1024.0 * 1024.0)
	throughput_mbs := mb / elapsed
	cells_per_sec := f64(cell_count) / elapsed

	return Color_Stats{
		total_bytes    = total_bytes,
		total_cells    = cell_count,
		elapsed_sec    = elapsed,
		throughput_mbs = throughput_mbs,
		cells_per_sec  = cells_per_sec,
		frames_sent    = frames_sent,
		frames_recv    = frames_recv,
	}
}

// 4. Kitty CJK / Unicode Wide Character Flood
bench_kitty_unicode_wide :: proc(
	host_port: ^ipc.Host_Transport_Port,
	client_port: ^ipc.Client_Transport_Port,
	client_id: int,
) -> Unicode_Stats {
	term := new(termgrid.Terminal)
	termgrid.terminal_init(term, 24, 80)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}

	client_term := new(termgrid.Terminal)
	termgrid.terminal_init(client_term, 24, 80)
	defer {
		termgrid.terminal_destroy(client_term)
		free(client_term)
	}

	p: parser.Parser
	parser.parser_init(&p)

	CHUNK_CAP :: 64 * 1024

	UNICODE_SRC :: "안녕하세요 세계 ── 测试终端高性能 ── 日本語文字端末 ── ┌─┬─┐│┼│└─┴─┘\n"
	src_bytes := transmute([]u8)string(UNICODE_SRC)
	src_len := len(src_bytes)
	src_codepoints := strings.rune_count(UNICODE_SRC)

	raw_buf := make([]u8, UNICODE_TOTAL_BYTES + src_len)
	defer delete(raw_buf)

	buf_pos := 0
	codepoint_count := 0
	for buf_pos < UNICODE_TOTAL_BYTES {
		copy(raw_buf[buf_pos:], src_bytes)
		buf_pos += src_len
		codepoint_count += src_codepoints
	}
	total_bytes := u64(buf_pos)

	snap_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(snap_buf)

	client_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(client_buf)

	frames_sent := 0
	frames_recv := 0
	seq := u64(1)

	t0 := time.tick_now()

	offset := 0
	for offset < buf_pos {
		chunk_len := min(CHUNK_CAP, buf_pos - offset)
		parser.parse_chunk(&p, term, raw_buf[offset:offset + chunk_len])
		offset += chunk_len

		snap_hdr := ipc.Snapshot_Header{
			workspace_id = 1,
			pane_id      = 1,
			snapshot_rev = seq,
			topology_rev = 1,
			kind         = .Full,
		}

		snap_len, enc_err := ipc.encode_terminal_snapshot(snap_buf, term, snap_hdr)
		if enc_err == .None && snap_len > 0 {
			_, send_err := host_port.publish_snapshot(
				host_port.user_data,
				client_id,
				1,
				seq,
				snap_buf[:snap_len],
			)
			seq += 1

			if send_err == .None {
				frames_sent += 1
				rn, _, rok := client_port.read_snapshot(client_port.user_data, client_buf)
				if rok && rn > 0 {
					frames_recv += 1
					// Verify wide glyph continuation handling and snapshot deserialization on client
					_, _ = ipc.apply_terminal_snapshot(client_term, client_buf[:rn])
				}
			}
		}

		termgrid.terminal_clear_damage(term)
		free_all(context.temp_allocator)
	}

	elapsed := time.duration_seconds(time.tick_since(t0))
	if elapsed <= 0.000001 do elapsed = 0.000001

	mb := f64(total_bytes) / (1024.0 * 1024.0)
	throughput_mbs := mb / elapsed
	cp_per_sec := f64(codepoint_count) / elapsed

	return Unicode_Stats{
		total_bytes        = total_bytes,
		total_codepoints   = codepoint_count,
		elapsed_sec        = elapsed,
		throughput_mbs     = throughput_mbs,
		codepoints_per_sec = cp_per_sec,
		frames_sent        = frames_sent,
		frames_recv        = frames_recv,
	}
}

// 5. Interactive Keystroke Responsiveness & Jitter Under Heavy Load (Dan Luu / Typometer)
bench_interactive_jitter_under_load :: proc(
	host_port: ^ipc.Host_Transport_Port,
	client_port: ^ipc.Client_Transport_Port,
	client_id: int,
) -> Latency_Stats {
	samples := make([]f64, INTERACTIVE_LOAD_ITERS)
	defer delete(samples)

	cmd := fmt.aprintf("stty -onlcr 2>/dev/null; head -c %d /dev/zero", 100 * 1024 * 1024)
	defer delete(cmd)

	p: pty.Pty
	if !pty.pty_spawn(&p, 24, 80, "/bin/sh", {"-c", cmd}) {
		fmt.eprintln("Failed to spawn PTY child producer for background flood")
		return {}
	}
	defer {
		if p.pid > 0 {
			posix.kill(posix.pid_t(p.pid), .SIGKILL)
			status: c.int
			posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
			p.pid = -1
		}
		pty.pty_close(&p)
	}

	drain_buf := make([]u8, 64 * 1024)
	defer delete(drain_buf)

	client_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(client_buf)

	key_payload := [1]u8{'x'}
	key_frame := ipc.Frame{
		header = {
			major = ipc.PROTOCOL_MAJOR,
			minor = ipc.PROTOCOL_MINOR,
			kind  = .Input,
		},
		payload = key_payload[:],
	}

	ack_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Ack,
			request_id = 1,
		},
		payload = nil,
	}

	sum_us := 0.0
	seq := u64(1)

	for i in 0..<INTERACTIVE_LOAD_ITERS {
		// Drain available background PTY output and publish as background snapshot
		n, _ := pty.pty_drain(&p, drain_buf, len(drain_buf))
		if n > 0 {
			_, _ = host_port.publish_snapshot(host_port.user_data, client_id, 1, seq, drain_buf[:n])
			seq += 1
		}

		t0 := time.tick_now()

		// Client sends key press
		_, _ = client_port.send_frame(client_port.user_data, key_frame)

		// Host receives key press
		_, _, _ = host_port.recv_frame(host_port.user_data, client_id)

		// Host sends immediate ack
		_, _ = host_port.send_frame(host_port.user_data, client_id, ack_frame)

		// Client receives ack (and consumes any interleaved snapshot frames)
		for _ in 0..<20 {
			f, _, status := client_port.recv_frame(client_port.user_data)
			if status == .Ok {
				if f.header.kind == .Ack {
					break
				}
			} else {
				break
			}
		}

		dur := time.duration_nanoseconds(time.tick_since(t0))
		us := f64(dur) / 1000.0
		samples[i] = us
		sum_us += us

		// Client drains pending snapshots if any was published
		if n > 0 {
			_, _, _ = client_port.read_snapshot(client_port.user_data, client_buf)
		}

		free_all(context.temp_allocator)
	}

	slice.sort(samples)

	p50_idx := int(f64(INTERACTIVE_LOAD_ITERS) * 0.50)
	p95_idx := int(f64(INTERACTIVE_LOAD_ITERS) * 0.95)
	p99_idx := int(f64(INTERACTIVE_LOAD_ITERS) * 0.99)
	p999_idx := int(f64(INTERACTIVE_LOAD_ITERS) * 0.999)
	if p999_idx >= INTERACTIVE_LOAD_ITERS do p999_idx = INTERACTIVE_LOAD_ITERS - 1

	return Latency_Stats{
		min_us  = samples[0],
		p50_us  = samples[p50_idx],
		p95_us  = samples[p95_idx],
		p99_us  = samples[p99_idx],
		p999_us = samples[p999_idx],
		max_us  = samples[INTERACTIVE_LOAD_ITERS - 1],
		mean_us = sum_us / f64(INTERACTIVE_LOAD_ITERS),
	}
}

print_comparative_table :: proc(uds, shm, hybrid: Adapter_Benchmark_Result) {
	fmt.println("====================================================================================================")
	fmt.println("                  EXTREME 5-WORKLOAD COMPARATIVE TRANSPORT BENCHMARK REPORT                         ")
	fmt.println("          Ghostty / VTEbench / Kitty / Dan Luu Extreme Matrix across 3 IPC Transports               ")
	fmt.println("====================================================================================================")
	fmt.printf("%-33s | %-20s | %-20s | %-20s\n", "Workload & Metric", "1. Pure UDS", "2. Pure POSIX SHM", "3. Hybrid UDS+SHM")
	fmt.println("----------------------------------+----------------------+----------------------+-------------------")
	fmt.printf("%-33s | %-20s | %-20s | %-20s\n", "Transport Architecture", uds.memory_model, "Direct Mmap Zero-Copy", "Mmap + UDS Control")
	fmt.println("----------------------------------+----------------------+----------------------+-------------------")

	// 1. Dense PTY Flood
	fmt.printf("%-33s | %20s | %20s | %20s\n", "1. 300 MB Dense PTY Flood", "", "", "")
	tp_flood_uds := fmt.tprintf("%.2f MB/s", uds.dense_flood.throughput_mbs)
	tp_flood_shm := fmt.tprintf("%.2f MB/s", shm.dense_flood.throughput_mbs)
	tp_flood_hyb := fmt.tprintf("%.2f MB/s", hybrid.dense_flood.throughput_mbs)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Throughput", tp_flood_uds, tp_flood_shm, tp_flood_hyb)

	el_flood_uds := fmt.tprintf("%.2f s", uds.dense_flood.elapsed_sec)
	el_flood_shm := fmt.tprintf("%.2f s", shm.dense_flood.elapsed_sec)
	el_flood_hyb := fmt.tprintf("%.2f s", hybrid.dense_flood.elapsed_sec)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Elapsed Time", el_flood_uds, el_flood_shm, el_flood_hyb)

	fr_flood_uds := fmt.tprintf("%d / %d", uds.dense_flood.frames_sent, uds.dense_flood.frames_recv)
	fr_flood_shm := fmt.tprintf("%d / %d", shm.dense_flood.frames_sent, shm.dense_flood.frames_recv)
	fr_flood_hyb := fmt.tprintf("%d / %d", hybrid.dense_flood.frames_sent, hybrid.dense_flood.frames_recv)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Frames (Sent / Recv)", fr_flood_uds, fr_flood_shm, fr_flood_hyb)
	fmt.println("----------------------------------+----------------------+----------------------+-------------------")

	// 2. VTEbench Alt-Screen Random Write
	fmt.printf("%-33s | %20s | %20s | %20s\n", "2. VTEbench Alt-Screen Write", "", "", "")
	ops_asrw_uds := fmt.tprintf("%.0f ops/s", uds.asrw.ops_per_sec)
	ops_asrw_shm := fmt.tprintf("%.0f ops/s", shm.asrw.ops_per_sec)
	ops_asrw_hyb := fmt.tprintf("%.0f ops/s", hybrid.asrw.ops_per_sec)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Throughput", ops_asrw_uds, ops_asrw_shm, ops_asrw_hyb)

	dtp_asrw_uds := fmt.tprintf("%.2f MB/s", uds.asrw.delta_mb_s)
	dtp_asrw_shm := fmt.tprintf("%.2f MB/s", shm.asrw.delta_mb_s)
	dtp_asrw_hyb := fmt.tprintf("%.2f MB/s", hybrid.asrw.delta_mb_s)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Delta Throughput", dtp_asrw_uds, dtp_asrw_shm, dtp_asrw_hyb)

	el_asrw_uds := fmt.tprintf("%.1f ms", uds.asrw.elapsed_sec * 1000.0)
	el_asrw_shm := fmt.tprintf("%.1f ms", shm.asrw.elapsed_sec * 1000.0)
	el_asrw_hyb := fmt.tprintf("%.1f ms", hybrid.asrw.elapsed_sec * 1000.0)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Elapsed Time", el_asrw_uds, el_asrw_shm, el_asrw_hyb)

	fr_asrw_uds := fmt.tprintf("%d / %d", uds.asrw.frames_sent, uds.asrw.frames_recv)
	fr_asrw_shm := fmt.tprintf("%d / %d", shm.asrw.frames_sent, shm.asrw.frames_recv)
	fr_asrw_hyb := fmt.tprintf("%d / %d", hybrid.asrw.frames_sent, hybrid.asrw.frames_recv)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Delta Snapshots (Sent/Recv)", fr_asrw_uds, fr_asrw_shm, fr_asrw_hyb)
	fmt.println("----------------------------------+----------------------+----------------------+-------------------")

	// 3. Kitty SGR 24-bit TrueColor Storm
	fmt.printf("%-33s | %20s | %20s | %20s\n", "3. Kitty TrueColor SGR Storm", "", "", "")
	cell_tc_uds := fmt.tprintf("%.0f cells/s", uds.truecolor.cells_per_sec)
	cell_tc_shm := fmt.tprintf("%.0f cells/s", shm.truecolor.cells_per_sec)
	cell_tc_hyb := fmt.tprintf("%.0f cells/s", hybrid.truecolor.cells_per_sec)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Cell Throughput", cell_tc_uds, cell_tc_shm, cell_tc_hyb)

	tp_tc_uds := fmt.tprintf("%.2f MB/s", uds.truecolor.throughput_mbs)
	tp_tc_shm := fmt.tprintf("%.2f MB/s", shm.truecolor.throughput_mbs)
	tp_tc_hyb := fmt.tprintf("%.2f MB/s", hybrid.truecolor.throughput_mbs)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Data Throughput", tp_tc_uds, tp_tc_shm, tp_tc_hyb)

	el_tc_uds := fmt.tprintf("%.1f ms", uds.truecolor.elapsed_sec * 1000.0)
	el_tc_shm := fmt.tprintf("%.1f ms", shm.truecolor.elapsed_sec * 1000.0)
	el_tc_hyb := fmt.tprintf("%.1f ms", hybrid.truecolor.elapsed_sec * 1000.0)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Elapsed Time", el_tc_uds, el_tc_shm, el_tc_hyb)

	fr_tc_uds := fmt.tprintf("%d / %d", uds.truecolor.frames_sent, uds.truecolor.frames_recv)
	fr_tc_shm := fmt.tprintf("%d / %d", shm.truecolor.frames_sent, shm.truecolor.frames_recv)
	fr_tc_hyb := fmt.tprintf("%d / %d", hybrid.truecolor.frames_sent, hybrid.truecolor.frames_recv)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Snapshots (Sent / Recv)", fr_tc_uds, fr_tc_shm, fr_tc_hyb)
	fmt.println("----------------------------------+----------------------+----------------------+-------------------")

	// 4. Kitty CJK / Wide Unicode Flood
	fmt.printf("%-33s | %20s | %20s | %20s\n", "4. Kitty CJK/Wide Unicode Flood", "", "", "")
	cp_uni_uds := fmt.tprintf("%.0f cp/s", uds.unicode.codepoints_per_sec)
	cp_uni_shm := fmt.tprintf("%.0f cp/s", shm.unicode.codepoints_per_sec)
	cp_uni_hyb := fmt.tprintf("%.0f cp/s", hybrid.unicode.codepoints_per_sec)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Codepoint Throughput", cp_uni_uds, cp_uni_shm, cp_uni_hyb)

	tp_uni_uds := fmt.tprintf("%.2f MB/s", uds.unicode.throughput_mbs)
	tp_uni_shm := fmt.tprintf("%.2f MB/s", shm.unicode.throughput_mbs)
	tp_uni_hyb := fmt.tprintf("%.2f MB/s", hybrid.unicode.throughput_mbs)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Data Throughput", tp_uni_uds, tp_uni_shm, tp_uni_hyb)

	el_uni_uds := fmt.tprintf("%.1f ms", uds.unicode.elapsed_sec * 1000.0)
	el_uni_shm := fmt.tprintf("%.1f ms", shm.unicode.elapsed_sec * 1000.0)
	el_uni_hyb := fmt.tprintf("%.1f ms", hybrid.unicode.elapsed_sec * 1000.0)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Elapsed Time", el_uni_uds, el_uni_shm, el_uni_hyb)

	fr_uni_uds := fmt.tprintf("%d / %d", uds.unicode.frames_sent, uds.unicode.frames_recv)
	fr_uni_shm := fmt.tprintf("%d / %d", shm.unicode.frames_sent, shm.unicode.frames_recv)
	fr_uni_hyb := fmt.tprintf("%d / %d", hybrid.unicode.frames_sent, hybrid.unicode.frames_recv)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Snapshots (Sent / Recv)", fr_uni_uds, fr_uni_shm, fr_uni_hyb)
	fmt.println("----------------------------------+----------------------+----------------------+-------------------")

	// 5. Typometer Keystroke Latency & Jitter Under Load
	fmt.printf("%-33s | %20s | %20s | %20s\n", "5. Typometer Jitter Under Load", "", "", "")
	p50_uds := fmt.tprintf("%.1f µs", uds.jitter_load.p50_us)
	p50_shm := fmt.tprintf("%.1f µs", shm.jitter_load.p50_us)
	p50_hyb := fmt.tprintf("%.1f µs", hybrid.jitter_load.p50_us)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Latency (p50)", p50_uds, p50_shm, p50_hyb)

	p95_uds := fmt.tprintf("%.1f µs", uds.jitter_load.p95_us)
	p95_shm := fmt.tprintf("%.1f µs", shm.jitter_load.p95_us)
	p95_hyb := fmt.tprintf("%.1f µs", hybrid.jitter_load.p95_us)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Latency (p95)", p95_uds, p95_shm, p95_hyb)

	p99_uds := fmt.tprintf("%.1f µs", uds.jitter_load.p99_us)
	p99_shm := fmt.tprintf("%.1f µs", shm.jitter_load.p99_us)
	p99_hyb := fmt.tprintf("%.1f µs", hybrid.jitter_load.p99_us)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Tail Jitter Latency (p99)", p99_uds, p99_shm, p99_hyb)

	p999_uds := fmt.tprintf("%.1f µs", uds.jitter_load.p999_us)
	p999_shm := fmt.tprintf("%.1f µs", shm.jitter_load.p999_us)
	p999_hyb := fmt.tprintf("%.1f µs", hybrid.jitter_load.p999_us)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Worst Tail Jitter (p99.9)", p999_uds, p999_shm, p999_hyb)

	mean_uds := fmt.tprintf("%.1f µs", uds.jitter_load.mean_us)
	mean_shm := fmt.tprintf("%.1f µs", shm.jitter_load.mean_us)
	mean_hyb := fmt.tprintf("%.1f µs", hybrid.jitter_load.mean_us)
	fmt.printf("   %-30s | %20s | %20s | %20s\n", "Mean Round-Trip Latency", mean_uds, mean_shm, mean_hyb)
	fmt.println("====================================================================================================")
}
