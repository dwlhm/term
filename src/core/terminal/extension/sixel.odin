package terminal_extension

// Sixel Graphics Protocol Decoder (DEC VT240 / VT340 / Modern Sixel)
// Autonomous Core Terminal Engine (src/core/terminal/extension/*).
//
// Invariant: Full specification lifecycle coverage upfront:
//   - Introducer & Aspect Ratios: `DCS [p1] ; [p2] ; [p3] q`
//   - Raster Attributes: `" [Pan; Pad; Ph; Pv]`
//   - Color Registers & Models: `# [slot]`, `# [slot] ; 2 ; [r] ; [g] ; [b]` (RGB), `# [slot] ; 1 ; [h] ; [l] ; [s]` (HLS)
//   - Standard DEC 16-color Sixel palette pre-initialized
//   - RLE Compression: `! [count] [char]`
//   - 6-Pixel Bands, CR `$`, and LF `-`

import "base:runtime"

@(rodata)
DEFAULT_SIXEL_PALETTE := [16][4]u8{
	{0, 0, 0, 255},       // 0: Black
	{51, 51, 204, 255},   // 1: Blue (20, 20, 80%)
	{204, 33, 33, 255},   // 2: Red (80, 13, 13%)
	{51, 204, 51, 255},   // 3: Green (20, 80, 20%)
	{204, 51, 204, 255},  // 4: Magenta (80, 20, 80%)
	{51, 204, 204, 255},  // 5: Cyan (20, 80, 80%)
	{204, 204, 51, 255},  // 6: Yellow (80, 80, 20%)
	{135, 135, 135, 255}, // 7: Gray 53%
	{66, 66, 66, 255},    // 8: Gray 26%
	{84, 84, 255, 255},   // 9: Light Blue (33, 33, 100%)
	{255, 84, 84, 255},   // 10: Light Red (100, 33, 33%)
	{84, 255, 84, 255},   // 11: Light Green (33, 100, 33%)
	{255, 84, 255, 255},  // 12: Light Magenta (100, 33, 100%)
	{84, 255, 255, 255},  // 13: Light Cyan (33, 100, 100%)
	{255, 255, 84, 255},  // 14: Light Yellow (100, 100, 33%)
	{230, 230, 230, 255}, // 15: White 90%
}

_sixel_hue_to_rgb :: proc "contextless" (p, q, t_in: f32) -> f32 {
	t := t_in
	if t < 0.0 do t += 1.0
	if t > 1.0 do t -= 1.0
	if t < 1.0 / 6.0 do return p + (q - p) * 6.0 * t
	if t < 1.0 / 2.0 do return q
	if t < 2.0 / 3.0 do return p + (q - p) * (2.0 / 3.0 - t) * 6.0
	return p
}

sixel_hls_to_rgba :: proc "contextless" (h_deg, l_pct, s_pct: int) -> [4]u8 {
	h := f32(h_deg % 360) / 360.0
	l := clamp(f32(l_pct) / 100.0, 0.0, 1.0)
	s := clamp(f32(s_pct) / 100.0, 0.0, 1.0)
	if s == 0.0 {
		val := u8(l * 255.0 + 0.5)
		return {val, val, val, 255}
	}
	q := l * (1.0 + s) if l < 0.5 else l + s - (l * s)
	p := 2.0 * l - q
	r := u8(clamp(_sixel_hue_to_rgb(p, q, h + 1.0 / 3.0) * 255.0 + 0.5, 0.0, 255.0))
	g := u8(clamp(_sixel_hue_to_rgb(p, q, h) * 255.0 + 0.5, 0.0, 255.0))
	b := u8(clamp(_sixel_hue_to_rgb(p, q, h - 1.0 / 3.0) * 255.0 + 0.5, 0.0, 255.0))
	return {r, g, b, 255}
}

@(private = "file")
_parse_uint_advance :: proc(data: []u8, idx: ^int) -> int {
	val := 0
	for idx^ < len(data) && data[idx^] >= '0' && data[idx^] <= '9' {
		val = val * 10 + int(data[idx^] - '0')
		idx^ += 1
	}
	return val
}

@(private = "file")
_sixel_probe_dimensions :: proc(data: []u8, start_idx: int) -> (w, h: int) {
	cur_x, cur_y := 0, 0
	max_x, max_y := 0, 0
	canvas_w, canvas_h := 0, 0
	i := start_idx

	for i < len(data) {
		b := data[i]
		i += 1
		switch b {
		case '"':
			_ = _parse_uint_advance(data, &i) // Pan
			if i < len(data) && data[i] == ';' do i += 1
			_ = _parse_uint_advance(data, &i) // Pad
			if i < len(data) && data[i] == ';' do i += 1
			ph := _parse_uint_advance(data, &i)
			if i < len(data) && data[i] == ';' do i += 1
			pv := _parse_uint_advance(data, &i)
			if ph > 0 && pv > 0 {
				canvas_w = min(ph, KITTY_MAX_DIMENSION)
				canvas_h = min(pv, KITTY_MAX_DIMENSION)
			}
		case '!':
			count := _parse_uint_advance(data, &i)
			if i < len(data) && data[i] >= '?' && data[i] <= '~' {
				cur_x += count
				max_x = max(max_x, cur_x)
				max_y = max(max_y, cur_y + 6)
				i += 1
			}
		case '$': cur_x = 0
		case '-': cur_x = 0; cur_y += 6
		case '?'..='~':
			cur_x += 1
			max_x = max(max_x, cur_x)
			max_y = max(max_y, cur_y + 6)
		}
	}
	w = canvas_w if canvas_w > 0 else max_x
	h = canvas_h if canvas_h > 0 else max_y
	return w, h
}

@(private = "file")
_sixel_parse_header :: proc(data: []u8) -> (data_start, bg_mode: int, ok: bool) {
	q_idx := -1
	for b, i in data {
		if b == 'q' || b == 'Q' { q_idx = i; break }
		if (b < '0' || b > '9') && b != ';' && b != '?' && b != ' ' do return 0, 0, false
	}
	if q_idx < 0 do return 0, 0, false

	bg_mode = 1 // default transparent
	idx := 0
	p1 := _parse_uint_advance(data, &idx)
	_ = p1
	if idx < q_idx && data[idx] == ';' {
		idx += 1
		bg_mode = _parse_uint_advance(data, &idx)
	}
	return q_idx + 1, bg_mode, true
}

@(private = "file")
_sixel_write_slice :: proc(pixels: []u8, w, h, x, y: int, mask: u8, color: [4]u8) {
	if x < 0 || x >= w do return
	for bit in 0..<6 {
		py := y + bit
		if py >= h do break
		if (mask & (1 << uint(bit))) != 0 {
			offset := (py * w + x) * 4
			pixels[offset + 0] = color[0]
			pixels[offset + 1] = color[1]
			pixels[offset + 2] = color[2]
			pixels[offset + 3] = color[3]
		}
	}
}

sixel_decode :: proc(payload: []u8, allocator: runtime.Allocator) -> (pixels: []u8, width, height: int, ok: bool) {
	data_start, bg_mode, header_ok := _sixel_parse_header(payload)
	if !header_ok || data_start >= len(payload) do return nil, 0, 0, false

	w, h := _sixel_probe_dimensions(payload, data_start)
	if w <= 0 || h <= 0 || !kitty_dims_valid(w, h) do return nil, 0, 0, false

	total_bytes := w * h * 4
	px := make([]u8, total_bytes, allocator)
	defer if !ok && len(px) > 0 do delete(px, allocator)

	palette: [256][4]u8
	copy(palette[:16], DEFAULT_SIXEL_PALETTE[:])
	for i in 16..<256 do palette[i] = {255, 255, 255, 255}

	// If background mode 0 or 2, fill canvas with color register 0
	if bg_mode == 0 || bg_mode == 2 {
		bg := palette[0]
		for i := 0; i < total_bytes; i += 4 {
			px[i + 0] = bg[0]; px[i + 1] = bg[1]; px[i + 2] = bg[2]; px[i + 3] = bg[3]
		}
	}

	active_slot := 0
	cur_x, cur_y := 0, 0
	i := data_start

	for i < len(payload) {
		b := payload[i]
		i += 1
		switch b {
		case '#':
			slot := _parse_uint_advance(payload, &i)
			if i < len(payload) && payload[i] == ';' {
				i += 1
				model := _parse_uint_advance(payload, &i)
				if i < len(payload) && payload[i] == ';' do i += 1
				c1 := _parse_uint_advance(payload, &i)
				if i < len(payload) && payload[i] == ';' do i += 1
				c2 := _parse_uint_advance(payload, &i)
				if i < len(payload) && payload[i] == ';' do i += 1
				c3 := _parse_uint_advance(payload, &i)
				if slot < 256 {
					if model == 2 {
						r := u8(clamp(f32(c1) * 255.0 / 100.0 + 0.5, 0.0, 255.0))
						g := u8(clamp(f32(c2) * 255.0 / 100.0 + 0.5, 0.0, 255.0))
						b_col := u8(clamp(f32(c3) * 255.0 / 100.0 + 0.5, 0.0, 255.0))
						palette[slot] = {r, g, b_col, 255}
					} else if model == 1 {
						palette[slot] = sixel_hls_to_rgba(c1, c2, c3)
					}
				}
			} else {
				active_slot = clamp(slot, 0, 255)
			}
		case '!':
			count := _parse_uint_advance(payload, &i)
			if i < len(payload) && payload[i] >= '?' && payload[i] <= '~' {
				mask := payload[i] - '?'
				i += 1
				for _ in 0..<count {
					_sixel_write_slice(px, w, h, cur_x, cur_y, mask, palette[active_slot])
					cur_x += 1
				}
			}
		case '$': cur_x = 0
		case '-': cur_x = 0; cur_y += 6
		case '?'..='~':
			_sixel_write_slice(px, w, h, cur_x, cur_y, b - '?', palette[active_slot])
			cur_x += 1
		case '"':
			// Consume any inline raster attributes in body
			for i < len(payload) && ((payload[i] >= '0' && payload[i] <= '9') || payload[i] == ';') do i += 1
		}
	}
	return px, w, h, true
}
