package feature_session_core

// Text the broker stores: request bodies and results come from other sessions
// and are typed into a terminal, so control bytes are dropped; results are
// capped around a marker.

// _clean drops, in place, the control bytes in text another session sent
// that would act on a terminal (newlines kept when asked); returns the length.
@(private)
_clean :: proc(buf: []u8, newlines: bool) -> int {
	n := 0
	for ch in buf {
		if ch >= 0x20 && ch != 0x7f || ch == '\t' || (newlines && ch == '\n') {
			buf[n] = ch
			n += 1
		}
	}
	return n
}

@(private)
_has_visible :: proc(s: string) -> bool {
	for i in 0..<len(s) do if s[i] > 0x20 && s[i] != 0x7f do return true
	return false
}

// _copy_capped copies text, keeping its head and tail around a marker when it
// does not fit (cut on UTF-8 boundaries).
@(private)
_copy_capped :: proc(dst: []u8, text: string) -> int {
	if len(text) <= len(dst) do return copy(dst, text)
	MARK :: "\n[… output truncated …]\n"
	half := (len(dst) - len(MARK)) / 2
	head := _rune_floor(text, half)
	tail := _rune_ceil(text, len(text) - half)
	n := copy(dst, text[:head])
	n += copy(dst[n:], MARK)
	n += copy(dst[n:], text[tail:])
	return n
}

@(private = "file")
_rune_floor :: proc(s: string, i: int) -> int {
	j := i
	for j > 0 && s[j] & 0xC0 == 0x80 do j -= 1
	return j
}

@(private = "file")
_rune_ceil :: proc(s: string, i: int) -> int {
	j := i
	for j < len(s) && s[j] & 0xC0 == 0x80 do j += 1
	return j
}
