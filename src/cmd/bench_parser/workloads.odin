package main

import "core:fmt"
import "core:strings"

// Deterministic synthetic output streams, one per parser/grid cost class.
// Text lines end in "\r\n" as a PTY with onlcr delivers them; a bare "\n"
// keeps the column, so lines would staircase across the screen and measure
// wrapping and wide row clears instead of the workload.

Workload :: struct {
	name:  string,
	unit:  string, // what one "op" is in the report
	units: int,    // number of ops in data
	data:  []u8,
}

WORKLOAD_BYTES :: 4 << 20

@(private = "file")
Rng :: struct {
	state: u64,
}

@(private = "file")
_next :: proc(r: ^Rng) -> u64 {
	r.state ~= r.state << 13
	r.state ~= r.state >> 7
	r.state ~= r.state << 17
	return r.state
}

workloads_make :: proc(rows, cols: int, allocator := context.allocator) -> []Workload {
	out := make([dynamic]Workload, allocator)
	append(&out, _lines("ascii_long", cols - 1, "abcdefghijklmnopqrstuvwxyz ", allocator))
	append(&out, _numbers(allocator))
	append(&out, _repeat("lf", "", "\n", allocator))
	region := fmt.aprintf("\x1b[2;%dr\x1b[%d;1H", rows - 1, rows - 1, allocator = allocator)
	append(&out, _repeat("lf_region", region, "\n", allocator))
	append(&out, _sgr(allocator))
	append(&out, _lines("box", cols / 2, "─│┌┐└┘├┤┬┴┼▁▂▃▄▅▆▇█", allocator))
	append(&out, _lines("cjk_emoji", cols / 3, "日本語のテキスト世界😀🚀αβγüé ", allocator))
	return out[:]
}

// _lines: full-width lines of random runes from `alphabet`.
@(private = "file")
_lines :: proc(name: string, per_line: int, alphabet: string, allocator := context.allocator) -> Workload {
	glyphs := make([dynamic]string, context.temp_allocator)
	for _, i in alphabet {
		size := 1
		for i + size < len(alphabet) && alphabet[i + size] & 0xC0 == 0x80 do size += 1
		append(&glyphs, alphabet[i:][:size])
	}
	b := strings.builder_make(0, WORKLOAD_BYTES + 1024, allocator)
	rng := Rng{0x9E3779B97F4A7C15}
	lines := 0
	for strings.builder_len(b) < WORKLOAD_BYTES {
		for _ in 0 ..< per_line do strings.write_string(&b, glyphs[_next(&rng) % u64(len(glyphs))])
		strings.write_string(&b, "\r\n")
		lines += 1
	}
	return {name, "line", lines, b.buf[:]}
}

// _numbers: `seq`-style short lines.
@(private = "file")
_numbers :: proc(allocator := context.allocator) -> Workload {
	b := strings.builder_make(0, WORKLOAD_BYTES + 32, allocator)
	n := 0
	for strings.builder_len(b) < WORKLOAD_BYTES {
		n += 1
		strings.write_int(&b, n)
		strings.write_string(&b, "\r\n")
	}
	return {"ascii_short", "line", n, b.buf[:]}
}

@(private = "file")
_repeat :: proc(name, prefix, unit: string, allocator := context.allocator) -> Workload {
	b := strings.builder_make(0, WORKLOAD_BYTES + len(prefix), allocator)
	strings.write_string(&b, prefix)
	n := 0
	for strings.builder_len(b) < WORKLOAD_BYTES {
		strings.write_string(&b, unit)
		n += 1
	}
	return {name, "LF", n, b.buf[:]}
}

// _sgr: truecolor tokens, the shape of colored compiler/log output.
@(private = "file")
_sgr :: proc(allocator := context.allocator) -> Workload {
	b := strings.builder_make(0, WORKLOAD_BYTES + 256, allocator)
	rng := Rng{0xD1B54A32D192ED03}
	words := [?]string{"token", "value", "error", "warning:", "x=1", "ok"}
	lines := 0
	for strings.builder_len(b) < WORKLOAD_BYTES {
		for _ in 0 ..< 12 {
			v := _next(&rng)
			fmt.sbprintf(&b, "\x1b[38;2;%d;%d;%dm%s\x1b[0m ", v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, words[v % len(words)])
		}
		strings.write_string(&b, "\r\n")
		lines += 1
	}
	return {"sgr", "line", lines, b.buf[:]}
}
