package terminal_extension

// OSC 9 (iTerm2 / ConEmu) & OSC 777 (urxvt) Terminal Notification Protocol
// Part of Autonomous Core Terminal Engine (src/core/terminal/extension/*).
//
// Invariant: Wire format parsing of desktop notification sequences.
// Zero heap allocations in steady-state reporting.

import "core:strings"

MAX_NOTIFY_TITLE_LEN :: 128
MAX_NOTIFY_BODY_LEN  :: 1024

OSC_NOTIFY_9   :: 9
OSC_NOTIFY_777 :: 777

Terminal_Notification :: struct {
	title_buf: [MAX_NOTIFY_TITLE_LEN]u8,
	title_len: int,
	body_buf:  [MAX_NOTIFY_BODY_LEN]u8,
	body_len:  int,
}

terminal_notification_title :: proc "contextless" (n: ^Terminal_Notification) -> string {
	if n == nil || n.title_len == 0 do return ""
	return string(n.title_buf[:n.title_len])
}

terminal_notification_body :: proc "contextless" (n: ^Terminal_Notification) -> string {
	if n == nil || n.body_len == 0 do return ""
	return string(n.body_buf[:n.body_len])
}

Osc_Notify_Sink :: #type proc(user_data: rawptr, notif: Terminal_Notification) -> bool

Osc_Notify_Context :: struct {
	sink:      Osc_Notify_Sink,
	user_data: rawptr,
}

// _sanitize_copy copies `src` into `dst` up to len(dst), stripping ASCII control
// codes (< 0x20) other than tab (0x09) to prevent hostile terminal injection.
@(private = "file")
_sanitize_copy :: proc(dst: []u8, src: string) -> int {
	out := 0
	cap := len(dst)
	for i := 0; i < len(src) && out < cap; i += 1 {
		b := src[i]
		if b >= 0x20 || b == '\t' {
			dst[out] = b
			out += 1
		}
	}
	return out
}

// osc_9_handler parses iTerm2 / ConEmu notification payload.
// Format: `ESC ] 9 ; <message> ST` or `ESC ] 9 ; 1 ; <message> ST`.
osc_9_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	ctx := (^Osc_Notify_Context)(user_data)
	if ctx == nil || ctx.sink == nil do return false

	body := payload
	if strings.has_prefix(body, "1;") {
		body = body[2:]
	}

	notif := Terminal_Notification{}
	notif.body_len = _sanitize_copy(notif.body_buf[:], body)
	if notif.body_len == 0 do return false

	return ctx.sink(ctx.user_data, notif)
}

// osc_777_handler parses urxvt notification payload.
// Format: `ESC ] 777 ; notify ; <title> ; <message> ST`.
osc_777_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	ctx := (^Osc_Notify_Context)(user_data)
	if ctx == nil || ctx.sink == nil do return false

	rem := payload
	action, has_action := strings.split_iterator(&rem, ";")
	if !has_action || action != "notify" do return false

	title, _ := strings.split_iterator(&rem, ";")
	body, _ := strings.split_iterator(&rem, ";")

	notif := Terminal_Notification{}
	notif.title_len = _sanitize_copy(notif.title_buf[:], title)
	notif.body_len = _sanitize_copy(notif.body_buf[:], body)
	if notif.title_len == 0 && notif.body_len == 0 do return false

	return ctx.sink(ctx.user_data, notif)
}
