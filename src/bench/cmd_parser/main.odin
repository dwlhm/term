package main

import "core:fmt"
import "core:time"
import termgrid "../../terminal"
import parser "../../parser"

main :: proc() {
	// Initialize parser and terminal
	p: parser.Parser
	parser.parser_init(&p)
	
	t: termgrid.Terminal
	termgrid.terminal_init(&t, 24, 80)
	defer termgrid.terminal_destroy(&t)
	
	// Test 1: ASCII throughput
	fmt.println("=== Performance Test 1: ASCII Throughput ===")
	
	// Create a large ASCII buffer (1 MB)
	ascii_data := make([]u8, 1024 * 1024)
	for i in 0..<len(ascii_data) {
		ascii_data[i] = u8(0x20 + (i % 95)) // printable ASCII
	}
	
	// Warm up
	parser.parse_chunk(&p, &t, ascii_data[:1024])
	parser.parser_reset(&p)
	
	// Benchmark
	start := time.now()
	iterations := 100
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, &t, ascii_data)
	}
	elapsed := time.since(start)
	
	total_bytes := int(len(ascii_data)) * iterations
	mb_per_sec := f64(total_bytes) / f64(elapsed / time.Millisecond) / 1024.0
	cycles_per_byte := f64(elapsed) / f64(total_bytes)
	
	fmt.printf("Processed %d bytes in %d ms\n", total_bytes, elapsed / time.Millisecond)
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
	parser.parse_chunk(&p, &t, csi_data[:60])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 1000
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, &t, csi_data)
	}
	elapsed = time.since(start)
	
	sequences_per_sec := f64(1000 * iterations) / (f64(elapsed) / f64(time.Second))
	
	fmt.printf("Processed %d sequences in %d ms\n", 1000 * iterations, elapsed / time.Millisecond)
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
	parser.parse_chunk(&p, &t, mixed_data[:1000])
	parser.parser_reset(&p)
	
	// Benchmark
	start = time.now()
	iterations = 100
	for i in 0..<iterations {
		parser.parser_reset(&p)
		parser.parse_chunk(&p, &t, mixed_data)
	}
	elapsed = time.since(start)
	
	total_bytes = int(len(mixed_data)) * iterations
	mb_per_sec = f64(total_bytes) / f64(elapsed / time.Millisecond) / 1024.0
	
	fmt.printf("Processed %d bytes in %d ms\n", total_bytes, elapsed / time.Millisecond)
	fmt.printf("Throughput: %.2f MB/s\n", mb_per_sec)
	fmt.printf("Target: >100 MB/s for typical terminal output\n")
	
	if mb_per_sec > 100.0 {
		fmt.println("✓ Mixed workload throughput target met")
	} else {
		fmt.println("✗ Mixed workload throughput target NOT met")
	}
	
	delete(mixed_data)
	
	fmt.println("\n=== All Performance Tests Complete ===")
}
