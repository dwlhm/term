package core_terminal

import "core:encoding/base64"
import extension "extension"

// Raw bytes per kitty transmit chunk: 3072 bytes encode to 4096 base64 chars,
// the chunk size the protocol recommends.
PAINT_KITTY_CHUNK :: 3072

// _paint_kitty re-emits the kitty images used on the active screen (direct
// RGBA transmission) and then their placements, without moving the cursor or
// asking the receiver for a reply. Images that exceed the protocol limits are
// skipped rather than sent half.
_paint_kitty :: proc(t: ^Terminal, out: ^[dynamic]u8) {
	ks := _paint_kitty_state(t)
	if ks == nil do return
	screen: extension.Kitty_Screen = .Alternate if t.parser.in_alt_screen else .Primary
	for &img in ks.images {
		if img.id == 0 || !_paint_kitty_image_used(ks, &img, screen, t.rows) do continue
		if !_paint_kitty_transmit(out, &img) do continue
		_paint_kitty_frames(out, &img)
		_paint_kitty_anim_ctrl(out, &img)
		if img.is_virtual {
			_paint_kitty_key(out, "\x1b_Ga=p,U=1,q=2,i", int(img.id))
			_paint_kitty_key(out, ",c", img.cols)
			_paint_kitty_key(out, ",r", img.rows)
			_paint_str(out, "\x1b\\")
		}
		for &pl in ks.placements {
			if pl.image_id == img.id && _paint_kitty_placement_visible(&pl, screen, t.rows) {
				_paint_kitty_place(out, &pl)
			}
		}
	}
}

_paint_kitty_state :: proc(t: ^Terminal) -> ^extension.Kitty_Extension {
	for i in 0 ..< t.extensions.ext_count {
		e := &t.extensions.extensions[i]
		if e.name == "kitty_graphics" do return (^extension.Kitty_Extension)(e.user_data)
	}
	return nil
}

_paint_kitty_placement_visible :: proc(pl: ^extension.Kitty_Placement, screen: extension.Kitty_Screen, rows: int) -> bool {
	return pl.is_active && pl.screen == screen && pl.y_row >= 0 && pl.y_row < rows
}

_paint_kitty_image_used :: proc(ks: ^extension.Kitty_Extension, img: ^extension.Kitty_Image, screen: extension.Kitty_Screen, rows: int) -> bool {
	if img.is_virtual do return img.screen == screen
	for &pl in ks.placements {
		if pl.image_id == img.id && _paint_kitty_placement_visible(&pl, screen, rows) do return true
	}
	return false
}

_paint_kitty_transmit :: proc(out: ^[dynamic]u8, img: ^extension.Kitty_Image) -> bool {
	size := img.width * img.height * 4
	if !extension.kitty_dims_valid(img.width, img.height) || len(img.pixels) < size do return false
	if (size + 2) / 3 * 4 > extension.KITTY_MAX_PAYLOAD_BYTES do return false
	_paint_kitty_key(out, "\x1b_Ga=t,f=32,t=d,q=2,i", int(img.id))
	_paint_kitty_key(out, ",s", img.width)
	_paint_kitty_key(out, ",v", img.height)
	_paint_kitty_payload(out, img.pixels[:size])
	return true
}

// _paint_kitty_payload writes RGBA bytes as base64 chunks. `m=1` continues the
// APC transfer, `m=0` finishes it; the caller has already written the first
// chunk's control keys (up to but not including `,m`).
_paint_kitty_payload :: proc(out: ^[dynamic]u8, px: []u8) {
	for off := 0; off < len(px); off += PAINT_KITTY_CHUNK {
		chunk := px[off:min(off + PAINT_KITTY_CHUNK, len(px))]
		more := 1 if off + PAINT_KITTY_CHUNK < len(px) else 0
		if off == 0 {
			_paint_kitty_key(out, ",m", more)
		} else {
			_paint_kitty_key(out, "\x1b_Gm", more)
		}
		_paint_str(out, ";")
		_paint_base64(out, chunk)
		_paint_str(out, "\x1b\\")
	}
}

// _paint_kitty_frames re-transmits every stored animation frame. Each frame is
// its own kitty `a=f` transmission with the recorded source rect, gap and
// composition; frames that would exceed the receiver limits are skipped.
_paint_kitty_frames :: proc(out: ^[dynamic]u8, img: ^extension.Kitty_Image) {
	for &frame in img.animation.frames {
		size := frame.width * frame.height * 4
		if !extension.kitty_dims_valid(frame.width, frame.height) || len(frame.pixels) < size do continue
		if (size + 2) / 3 * 4 > extension.KITTY_MAX_PAYLOAD_BYTES do continue
		_paint_kitty_key(out, "\x1b_Ga=f,q=2,i", int(img.id))
		_paint_kitty_key(out, ",r", frame.frame_num)
		_paint_kitty_key(out, ",s", frame.width)
		_paint_kitty_key(out, ",v", frame.height)
		if frame.composition != 0 do _paint_kitty_key(out, ",c", int(frame.composition))
		_paint_kitty_key(out, ",z", frame.duration_ms)
		_paint_kitty_src_rect(out, frame.x, frame.y, frame.w, frame.h)
		if frame.offset_x != 0 do _paint_kitty_key(out, ",X", frame.offset_x)
		if frame.offset_y != 0 do _paint_kitty_key(out, ",Y", frame.offset_y)
		_paint_kitty_payload(out, frame.pixels[:size])
	}
}

_paint_kitty_src_rect :: proc(out: ^[dynamic]u8, x, y, w, h: int) {
	if x != 0 do _paint_kitty_key(out, ",x", x)
	if y != 0 do _paint_kitty_key(out, ",y", y)
	if w != 0 do _paint_kitty_key(out, ",w", w)
	if h != 0 do _paint_kitty_key(out, ",h", h)
}

// _paint_kitty_anim_ctrl restores the animation state machine after the frames:
// `s` state (1 stop / 2 load / 3 run), `v` loop count, `c` current frame
// (1-based, as the parser maps it back to an index) and `z` the frame gap.
_paint_kitty_anim_ctrl :: proc(out: ^[dynamic]u8, img: ^extension.Kitty_Image) {
	anim := &img.animation
	if len(anim.frames) == 0 do return
	_paint_kitty_key(out, "\x1b_Ga=a,q=2,i", int(img.id))
	_paint_kitty_key(out, ",s", int(anim.state))
	_paint_kitty_key(out, ",v", anim.loop_count)
	_paint_kitty_key(out, ",c", anim.current_frame + 1)
	idx := clamp(anim.current_frame, 0, len(anim.frames) - 1)
	_paint_kitty_key(out, ",z", anim.frames[idx].duration_ms)
	_paint_str(out, "\x1b\\")
}

_paint_kitty_place :: proc(out: ^[dynamic]u8, pl: ^extension.Kitty_Placement) {
	_paint_cup(out, pl.y_row + 1, pl.x_col + 1)
	_paint_kitty_key(out, "\x1b_Ga=p,C=1,q=2,i", int(pl.image_id))
	if pl.placement_id != 0 do _paint_kitty_key(out, ",p", int(pl.placement_id))
	_paint_kitty_key(out, ",c", pl.cols)
	_paint_kitty_key(out, ",r", pl.rows)
	_paint_kitty_key(out, ",x", pl.src_x)
	_paint_kitty_key(out, ",y", pl.src_y)
	_paint_kitty_key(out, ",w", pl.src_w)
	_paint_kitty_key(out, ",h", pl.src_h)
	_paint_kitty_key(out, ",z", pl.z_index)
	_paint_str(out, "\x1b\\")
}

_paint_kitty_key :: proc(out: ^[dynamic]u8, key: string, v: int) {
	_paint_str(out, key)
	_paint_str(out, "=")
	_paint_int(out, v)
}

// _paint_base64 encodes straight into the tail of `out` (no temporary buffer).
_paint_base64 :: proc(out: ^[dynamic]u8, data: []u8) {
	start := len(out)
	resize(out, start + base64.encoded_len(data))
	_, _ = base64.encode_into_buf(out[start:], data)
}
