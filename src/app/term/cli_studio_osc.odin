package term

// Native OSC 7502 (Surface & Layer Protocol) emitters for `term studio`.

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import ext "../../core/terminal/extension"

studio_osc_write :: proc(s: string) {
	if len(s) > 0 {
		_, _ = os.write(os.stdout, transmute([]u8)s)
	}
}

studio_osc_reset :: proc() {
	studio_osc_write("\x1b]7502;0\x1b\\")
}

studio_osc_focus :: proc(id: u16) {
	buf: [32]u8
	msg := fmt.bprintf(buf[:], "\x1b]7502;4;%d\x1b\\", id)
	studio_osc_write(msg)
}

studio_osc_show :: proc(id: u16, visible: bool) {
	buf: [32]u8
	msg := fmt.bprintf(buf[:], "\x1b]7502;5;%d;%d\x1b\\", id, 1 if visible else 0)
	studio_osc_write(msg)
}

studio_osc_close :: proc(id: u16) {
	buf: [32]u8
	msg := fmt.bprintf(buf[:], "\x1b]7502;6;%d\x1b\\", id)
	studio_osc_write(msg)
}

studio_osc_target :: proc(id: u16, payload: string) {
	buf: [32]u8
	hdr := fmt.bprintf(buf[:], "\x1b]7502;1;%d\x07", id)
	studio_osc_write(hdr)
	studio_osc_write(payload)
	if id != 0 {
		studio_osc_write("\x1b]7502;1;0\x07")
	}
}

studio_osc_split :: proc(id, parent: u16, dir: ext.Surface_Split_Dir, ratio: int, focus: bool) {
	buf: [64]u8
	msg := fmt.bprintf(
		buf[:],
		"\x1b]7502;2;%d;%d;%d;%d;%d\x1b\\",
		id, parent, int(dir), ratio, 1 if focus else 0,
	)
	studio_osc_write(msg)
}

studio_osc_popup :: proc(
	id: u16,
	w, h: int,
	anchor: ext.Surface_Anchor,
	x, y, z: int,
	chrome: ext.Surface_Chrome,
	focus: bool,
	title: string,
) {
	buf: [128]u8
	b64 := ""
	if len(title) > 0 {
		b64 = base64.encode(transmute([]u8)title, base64.ENC_TABLE, context.temp_allocator)
	}
	msg := fmt.bprintf(
		buf[:],
		"\x1b]7502;3;%d;%d;%d;%d;%d;%d;%d;%d;%d;%s\x1b\\",
		id, w, h, int(anchor), x, y, z, int(chrome), 1 if focus else 0, b64,
	)
	studio_osc_write(msg)
}
