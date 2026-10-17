package terminal_extension

import "base:runtime"
import "core:encoding/base64"
import "core:strings"

// Osc_52_Clipboard_Sink is the decoupled callback invoked when an OSC 52 sequence sets clipboard text.
Osc_52_Clipboard_Sink :: #type proc(user_data: rawptr, text: string) -> bool

// Osc_52_Context stores the sink procedure and associated user context pointer.
Osc_52_Context :: struct {
	sink:      Osc_52_Clipboard_Sink,
	user_data: rawptr,
}

// osc_52_parse extracts and decodes the Base64 payload from an OSC 52 sequence.
// Payload format: "c;<base64-data>" (system clipboard) or ";<base64-data>".
// Returns false if payload is empty, malformed, or attempts to read clipboard ("?").
osc_52_parse :: proc(payload: string, allocator: runtime.Allocator = context.temp_allocator) -> (text: string, ok: bool) {
	parts := strings.split(payload, ";", context.temp_allocator)
	if len(parts) < 2 do return "", false

	data_part := parts[1]
	// Security: Querying the clipboard via OSC 52 ("?") is blocked to prevent remote snooping.
	if len(data_part) == 0 || data_part == "?" {
		return "", false
	}

	decoded, err := base64.decode(data_part, allocator = allocator)
	if err != nil do return "", false

	return string(decoded), true
}

// osc_52_handler implements Osc_Handler_Proc for OSC 52 remote clipboard synchronization.
// Decoupled from windowing systems and clipboard implementations.
osc_52_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term: rawptr) -> bool {
	ctx := (^Osc_52_Context)(user_data)
	if ctx == nil || ctx.sink == nil do return false

	text, ok := osc_52_parse(payload, context.temp_allocator)
	if !ok do return false

	return ctx.sink(ctx.user_data, text)
}
