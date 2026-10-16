package term

// OSC 52 Remote Clipboard Protocol Extension
// Part of Tier 3 Application Shell (src/app/term/*).
// Handles remote application clipboard synchronization (e.g. from Neovim, tmux, SSH).

import "core:encoding/base64"
import "core:strings"

// osc_52_handler implements terminal_extension.Osc_Handler_Proc for OSC 52.
// Payload format: "c;<base64-data>" (system clipboard) or ";<base64-data>".
osc_52_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
	cb := (^Clipboard_Bridge)(user_data)
	if cb == nil do return false

	parts := strings.split(payload, ";", context.temp_allocator)
	if len(parts) < 2 do return false

	data_part := parts[1]
	// Security: Querying the clipboard via OSC 52 ("?") is blocked to prevent remote snooping.
	if len(data_part) == 0 || data_part == "?" {
		return false
	}

	decoded, err := base64.decode(data_part, allocator = context.temp_allocator)
	if err != nil do return false

	return clipboard_set_text(cb, string(decoded))
}
