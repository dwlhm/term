package main

import "core:fmt"
import "core:time"
import termgrid "../../terminal"
import parser "../../parser"

main :: proc() {
	// Initialize parser and terminal
	p: parser.Parser
	parser.parser_init(&p)
	
	t := new(termgrid.Terminal)
	termgrid.terminal_init(t, 24, 80)
	defer {
		termgrid.terminal_destroy(t)
		free(t)
	}
	
	// Test 1: ASCII throughput
	fmt.println("=== Performance Test 1: ASCII Throughput ===")
	
	// Create a large ASCII buffer (1 MB)
	ascii_data := make([]u8, 1024 * 1024)
	for i in 0..<len(ascii_data) {
		ascii_data[i] = u8(0x20 + (i % 95)) // printable ASCII
	}
	
	// Warm up
	parser.parse_chunk(&p, t, ascii_data[:1024])
	parser.parser_reset(&p)
	
	// Benchmark
	start := time.now()
	iterations := 100
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, t, ascii_data)
	}
	elapsed := time.since(start)
	
	total_bytes := int(len(ascii_data)) * iterations
	mb_per_sec := f64(total_bytes) / f64(elapsed / time.Millisecond) / 1024.0
	cycles_per_byte := f64(elapsed) / f64(total_bytes)
	
	fmt.printf("Processed %d bytes in %d ms\n", total_bytes, cast(int)(elapsed / time.Millisecond))
	fmt.printf("Throughput: %.2f MB/s\n", mb_per_sec)
	fmt.printf("Cycles/byte: %.2f ns/byte\n", cycles_per_byte)
	fmt.printf("Target: >100 MB/s, <10 ns/byte\n")
	
	if mb_per_sec > 100.0 {
		fmt.println("✓ ASCII throughput target met")
	} else {
		fmt.println("✗ ASCII throughput target NOT met")
	}
	
	delete(ascii_data)
	
	// Test 2: CSI sequence throughput
	fmt.println("\n=== Performance Test 2: CSI Sequence Throughput ===")
	
	// Create CSI sequence buffer (ESC[1;1H repeated)
	csi_data := make([]u8, 10000)
	pos := 0
	for i in 0..<1000 {
		csi_data[pos+0] = 0x1B
		csi_data[pos+1] = '['
		csi_data[pos+2] = '1'
		csi_data[pos+3] = ';'
		csi_data[pos+4] = '1'
		csi_data[pos+5] = 'H'
		pos += 6
	}
	
	// Warm up
	parser.parse_chunk(&p, t, csi_data[:60])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 1000
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, t, csi_data)
	}
	elapsed = time.since(start)
	
	sequences_per_sec := f64(1000 * iterations) / (f64(elapsed) / f64(time.Second))
	
	fmt.printf("Processed %d sequences in %d ms\n", 1000 * iterations, cast(int)(elapsed / time.Millisecond))
	fmt.printf("Throughput: %.0f sequences/sec\n", sequences_per_sec)
	fmt.printf("Target: >1M sequences/sec\n")
	
	if sequences_per_sec > 1_000_000.0 {
		fmt.println("✓ CSI sequence throughput target met")
	} else {
		fmt.println("✗ CSI sequence throughput target NOT met")
	}
	
	delete(csi_data)
	
	// Test 3: Mixed workload (95% ASCII, 5% CSI)
	fmt.println("\n=== Performance Test 3: Mixed Workload ===")
	
	mixed_data := make([]u8, 100000)
	pos = 0
	for i in 0..<1000 {
		// 95 bytes of ASCII
		for j in 0..<95 {
			mixed_data[pos] = u8(0x20 + (j % 95))
			pos += 1
		}
		// 5 bytes of CSI (ESC[0m)
		mixed_data[pos+0] = 0x1B
		mixed_data[pos+1] = '['
		mixed_data[pos+2] = '0'
		mixed_data[pos+3] = 'm'
		pos += 4
	}
	
	// Warm up
	parser.parse_chunk(&p, t, mixed_data[:1000])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 100
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, t, mixed_data)
	}
	elapsed = time.since(start)
	
	total_bytes = int(len(mixed_data)) * iterations
	mb_per_sec = f64(total_bytes) / f64(elapsed / time.Millisecond) / 1024.0
	
	fmt.printf("Processed %d bytes in %d ms\n", total_bytes, cast(int)(elapsed / time.Millisecond))
	fmt.printf("Throughput: %.2f MB/s\n", mb_per_sec)
	fmt.printf("Target: >100 MB/s for typical terminal output\n")
	
	if mb_per_sec > 100.0 {
		fmt.println("✓ Mixed workload throughput target met")
	} else {
		fmt.println("✗ Mixed workload throughput target NOT met")
	}
	
	delete(mixed_data)

	// Test 4: 16-color & 256-color SGR Throughput
	fmt.println("\n=== Performance Test 4: 16-Color & 256-Color SGR Throughput ===")
	
	sgr_color_seqs := [?]string{
		"\x1b[31m", "\x1b[42m", "\x1b[93m", "\x1b[104m", "\x1b[39m", "\x1b[49m",
		"\x1b[38;5;196m", "\x1b[48;5;21m", "\x1b[38:5:82m", "\x1b[48:5:235m",
	}
	sgr_color_data := make([]u8, 100000)
	sgr_color_count := 0
	pos = 0
	for pos + 20 < len(sgr_color_data) {
		seq := sgr_color_seqs[sgr_color_count % len(sgr_color_seqs)]
		copy(sgr_color_data[pos:], transmute([]u8)seq)
		pos += len(seq)
		sgr_color_count += 1
	}
	sgr_color_slice := sgr_color_data[:pos]
	
	// Warm up
	parser.parse_chunk(&p, t, sgr_color_slice[:min(pos, 1000)])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 500
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, t, sgr_color_slice)
	}
	elapsed = time.since(start)
	
	total_bytes = len(sgr_color_slice) * iterations
	total_seqs := sgr_color_count * iterations
	sec := f64(elapsed) / f64(time.Second)
	mb_per_sec = (f64(total_bytes) / (1024.0 * 1024.0)) / sec
	sequences_per_sec = f64(total_seqs) / sec
	
	fmt.printf("Processed %d bytes (%d sequences) in %d ms\n", total_bytes, total_seqs, cast(int)(elapsed / time.Millisecond))
	fmt.printf("Throughput: %.2f MB/s, %.0f sequences/sec\n", mb_per_sec, sequences_per_sec)
	delete(sgr_color_data)

	// Test 5: SGR Text Attributes Throughput
	fmt.println("\n=== Performance Test 5: SGR Text Attributes Throughput ===")
	
	sgr_attr_seqs := [?]string{
		"\x1b[1m", "\x1b[2m", "\x1b[3m", "\x1b[4m", "\x1b[7m", "\x1b[9m",
		"\x1b[22m", "\x1b[23m", "\x1b[24m", "\x1b[27m", "\x1b[29m", "\x1b[1;31m", "\x1b[0m",
	}
	sgr_attr_data := make([]u8, 100000)
	sgr_attr_count := 0
	pos = 0
	for pos + 20 < len(sgr_attr_data) {
		seq := sgr_attr_seqs[sgr_attr_count % len(sgr_attr_seqs)]
		copy(sgr_attr_data[pos:], transmute([]u8)seq)
		pos += len(seq)
		sgr_attr_count += 1
	}
	sgr_attr_slice := sgr_attr_data[:pos]
	
	// Warm up
	parser.parse_chunk(&p, t, sgr_attr_slice[:min(pos, 1000)])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 500
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, t, sgr_attr_slice)
	}
	elapsed = time.since(start)
	
	total_bytes = len(sgr_attr_slice) * iterations
	total_seqs = sgr_attr_count * iterations
	sec = f64(elapsed) / f64(time.Second)
	mb_per_sec = (f64(total_bytes) / (1024.0 * 1024.0)) / sec
	sequences_per_sec = f64(total_seqs) / sec
	
	fmt.printf("Processed %d bytes (%d sequences) in %d ms\n", total_bytes, total_seqs, cast(int)(elapsed / time.Millisecond))
	fmt.printf("Throughput: %.2f MB/s, %.0f sequences/sec\n", mb_per_sec, sequences_per_sec)
	delete(sgr_attr_data)

	// Test 6: Cursor Controls Throughput
	fmt.println("\n=== Performance Test 6: Cursor Controls Throughput ===")
	
	cursor_seqs := [?]string{
		"\x1b[H", "\x1b[10;20H", "\x1b[1;1f", "\x1b[A", "\x1b[5A", "\x1b[B", "\x1b[3B",
		"\x1b[C", "\x1b[4C", "\x1b[D", "\x1b[2D", "\x1b[G", "\x1b[15G", "\x1b[d", "\x1b[8d",
		"\x1b[K", "\x1b[1K", "\x1b[2K", "\x1b[J", "\x1b[2J",
	}
	cursor_data := make([]u8, 100000)
	cursor_count := 0
	pos = 0
	for pos + 20 < len(cursor_data) {
		seq := cursor_seqs[cursor_count % len(cursor_seqs)]
		copy(cursor_data[pos:], transmute([]u8)seq)
		pos += len(seq)
		cursor_count += 1
	}
	cursor_slice := cursor_data[:pos]
	
	// Warm up
	parser.parse_chunk(&p, t, cursor_slice[:min(pos, 1000)])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 500
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, t, cursor_slice)
	}
	elapsed = time.since(start)
	
	total_bytes = len(cursor_slice) * iterations
	total_seqs = cursor_count * iterations
	sec = f64(elapsed) / f64(time.Second)
	mb_per_sec = (f64(total_bytes) / (1024.0 * 1024.0)) / sec
	sequences_per_sec = f64(total_seqs) / sec
	
	fmt.printf("Processed %d bytes (%d sequences) in %d ms\n", total_bytes, total_seqs, cast(int)(elapsed / time.Millisecond))
	fmt.printf("Throughput: %.2f MB/s, %.0f sequences/sec\n", mb_per_sec, sequences_per_sec)
	delete(cursor_data)

	fmt.println("\n=== All Performance Tests Complete ===")
}
