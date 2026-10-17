package terminal_parser

import damage "../damage"
import grid "../grid"

_parser_feed_utf8 :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, b: u8) {
	if p.utf8_state == 0 {
		if b < 0xC0 {
			return
		} else if b < 0xE0 {
			p.utf8_state = 1
			p.utf8_buf[0] = b
			p.utf8_len = 1
		} else if b < 0xF0 {
			p.utf8_state = 2
			p.utf8_buf[0] = b
			p.utf8_len = 1
		} else if b < 0xF8 {
			p.utf8_state = 3
			p.utf8_buf[0] = b
			p.utf8_len = 1
		}
		return
	}

	if b < 0x80 || b >= 0xC0 {
		p.utf8_state = 0
		p.utf8_len = 0
		if b >= 0xC0 {
			_parser_feed_utf8(p, g, d, b)
		}
		return
	}

	p.utf8_buf[p.utf8_len] = b
	p.utf8_len += 1
	p.utf8_state -= 1

	if p.utf8_state == 0 {
		val: u32
		switch p.utf8_len {
		case 2:
			val = (u32(p.utf8_buf[0] & 0x1F) << 6) | u32(p.utf8_buf[1] & 0x3F)
		case 3:
			val = (u32(p.utf8_buf[0] & 0x0F) << 12) | (u32(p.utf8_buf[1] & 0x3F) << 6) | u32(p.utf8_buf[2] & 0x3F)
		case 4:
			val = (u32(p.utf8_buf[0] & 0x07) << 18) | (u32(p.utf8_buf[1] & 0x3F) << 12) | (u32(p.utf8_buf[2] & 0x3F) << 6) | u32(p.utf8_buf[3] & 0x3F)
		}
		p.utf8_len = 0
		if val > 0 && val <= 0x10FFFF {
			_parser_put_char(p, g, d, rune(val))
		}
	}
}
