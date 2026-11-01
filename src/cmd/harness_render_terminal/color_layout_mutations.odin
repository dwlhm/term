package main

// Mutation probes for the colour/decoration regression: each one encodes a
// deliberately broken strategy and requires the pixel comparator to see it.
// They guard the three contract points the regression asserts: the shared
// per-cell colour stride, the decoration-over-glyph order, and the pixel-centre
// convention for strikethrough sampling.

import "core:fmt"
import "vendor:wgpu"

import contract "../../core/render/contract"
import terminal "../../core/render/terminal"

_submit_encoder :: proc(h: ^Harness_State, enc: contract.Gpu_CommandEncoder) {
	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.wait_for_idle(h.device)
}

// _readback_compare maps both targets, counts differing pixels and unmaps them.
_readback_compare :: proc(
	h: ^Harness_State,
	a, b: ^_Color_Target,
	buf_size: u64,
	bytes_per_row: u32,
) -> (diff, first_x, first_y: int) {
	pa := _map_readback(h, a.buf, buf_size)
	pb := _map_readback(h, b.buf, buf_size)
	diff, first_x, first_y = _compare_pixels(pa, pb, bytes_per_row)
	wgpu.BufferUnmap(wgpu.Buffer(rawptr(a.buf)))
	wgpu.BufferUnmap(wgpu.Buffer(rawptr(b.buf)))
	return
}

_mutation_expect_diff :: proc(name: string, caught: bool, diff, x, y: int) -> bool {
	if caught {
		fmt.printfln("[PASS] Mutation: %s caught (%d diff pixels, first at %d,%d)", name, diff, x, y)
		return true
	}
	fmt.printfln("[FAIL] Mutation: %s was NOT caught!", name)
	return false
}

// _run_color_layout_mutations re-encodes single targets against a known-good
// reference. target 0/1/2 hold the baseline instance/tile/fullscreen pixels.
_run_color_layout_mutations :: proc(
	h: ^Harness_State,
	r: ^_Color_Renderers,
	targets: ^[3]_Color_Target,
	color_buf: contract.Gpu_Buffer,
	term: ^Synthetic_Terminal,
	buf_size: u64,
	bytes_per_row: u32,
) -> bool {
	ok := true
	mutant_bind := _fullscreen_bind_group(h, &r.fs, color_buf, h.fs_mutant_pipeline)
	defer if rawptr(mutant_bind) != nil do contract.destroy_bind_group(mutant_bind)

	// 1. Old two-word colour stride: shaders still read COLOR_WORDS_PER_CELL.
	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_fullscreen_target(h, enc, &r.fs, term, color_buf, targets[2].view, 2)
	_encode_readback(enc, targets[2].tex, targets[2].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y := _readback_compare(h, &targets[0], &targets[2], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("two-word colour stride", d > 0, d, x, y)

	// 2. Old production order: decorations painted by the background pass,
	// under the glyph ink.
	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &r.inst, term, targets[0].view, .Decor_Under_Glyph)
	_encode_readback(enc, targets[0].tex, targets[0].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("decoration painted under glyphs", d > 0, d, x, y)

	// 3. Old fullscreen strike sampling: py + 0.5 on a pixel-centred fragment.
	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_fullscreen_target(h, enc, &r.fs, term, color_buf, targets[2].view, terminal.COLOR_WORDS_PER_CELL, h.fs_mutant_pipeline, mutant_bind)
	_encode_readback(enc, targets[2].tex, targets[2].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[2], &targets[1], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("strikethrough half-pixel offset", d > 0, d, x, y)

	// 4. Italic decor: the instance strategy defers italic grids to the cell
	// shaders, so tile and fullscreen must agree on the sheared glyph + decor.
	_fill_italic_decor_cells(term)
	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_tile_target(h, enc, &r.tile, term, color_buf, targets[1].view)
	_encode_fullscreen_target(h, enc, &r.fs, term, color_buf, targets[2].view)
	_encode_readback(enc, targets[1].tex, targets[1].buf, bytes_per_row)
	_encode_readback(enc, targets[2].tex, targets[2].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[1], &targets[2], buf_size, bytes_per_row)
	if d == 0 {
		fmt.println("[PASS] italic decor: tile == fullscreen for sheared glyphs (0 diff pixels)")
	} else {
		fmt.printfln("[FAIL] italic decor: tile and fullscreen diverge (%d diff pixels, first at %d,%d)", d, x, y)
		ok = false
	}
	return ok
}
