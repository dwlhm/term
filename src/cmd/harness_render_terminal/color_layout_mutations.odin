package main

// Mutation probes for the colour/decoration regression: each one encodes a
// deliberately broken mutation on Instance_Renderer and requires the pixel
// comparator to catch it.

import "core:fmt"
import "vendor:wgpu"

import contract "../../core/render/contract"

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

// _run_color_layout_mutations re-encodes targets[1] with each mutation against
// the known-good baseline in targets[0].
_run_color_layout_mutations :: proc(
	h: ^Harness_State,
	r: ^_Color_Renderers,
	targets: ^[2]_Color_Target,
	term: ^Synthetic_Terminal,
	buf_size: u64,
	bytes_per_row: u32,
) -> bool {
	ok := true

	// 1. Old two-word colour stride: reading 2 words per cell instead of COLOR_WORDS_PER_CELL.
	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &r.inst_b, term, targets[1].view, .Two_Word_Color_Stride)
	_encode_readback(enc, targets[1].tex, targets[1].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y := _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("two-word colour stride", d > 0, d, x, y)

	// 2. Old production order: decorations painted by the background pass,
	// under the glyph ink.
	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &r.inst_b, term, targets[1].view, .Decor_Under_Glyph)
	_encode_readback(enc, targets[1].tex, targets[1].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("decoration painted under glyphs", d > 0, d, x, y)

	// 3. Strikethrough vertical offset mutation.
	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &r.inst_b, term, targets[1].view, .Strike_Offset)
	_encode_readback(enc, targets[1].tex, targets[1].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("strikethrough offset", d > 0, d, x, y)

	// 4. Synthetic italic shear in glyph.wgsl: sheared vs un-sheared must differ,
	// and two sheared encodings must match pixel-for-pixel.
	_fill_italic_decor_cells(term)
	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &r.inst_a, term, targets[0].view, .None)
	_encode_instance_target(h, enc, &r.inst_b, term, targets[1].view, .Disable_Italic_Shear)
	_encode_readback(enc, targets[0].tex, targets[0].buf, bytes_per_row)
	_encode_readback(enc, targets[1].tex, targets[1].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)
	ok &= _mutation_expect_diff("synthetic italic shear disabled", d > 0, d, x, y)

	enc = contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &r.inst_b, term, targets[1].view, .None)
	_encode_readback(enc, targets[1].tex, targets[1].buf, bytes_per_row)
	_submit_encoder(h, enc)
	d, x, y = _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)
	if d == 0 {
		fmt.println("[PASS] italic decor: sheared glyphs deterministic (0 diff pixels)")
	} else {
		fmt.printfln("[FAIL] italic decor: sheared glyphs diverge (%d diff pixels, first at %d,%d)", d, x, y)
		ok = false
	}
	return ok
}
