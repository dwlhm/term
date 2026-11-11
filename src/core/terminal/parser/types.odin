package terminal_parser

import cell "../cell"
import damage "../damage"
import egc "../egc"
import grid "../grid"

Parser_State :: enum u8 {
	Ground,
	Escape,
	Esc_Charset,
	Dcs_String,
	Esc_In_Dcs,
	Apc_String,
	Esc_In_Apc,
	Csi_Entry,
	Csi_Param,
	Osc_String,
	Esc_In_Osc,
}

Cursor_Shape :: enum u8 {
	Block,
	Beam,
	Underline,
}

Mouse_Tracking_Mode :: enum u8 {
	None,
	X10,          // ?9
	Normal,       // ?1000
	Button_Event, // ?1002
	Any_Event,    // ?1003
}

Mouse_Format :: enum u8 {
	X10,       // Default legacy 1-byte encoding
	Sgr,       // ?1006
	Sgr_Pixel, // ?1016
}

Prompt_State :: enum u8 {
	None,
	Prompt,    // OSC 133;A / 133;P: shell is drawing prompt
	Input,     // OSC 133;B: shell is at prompt waiting for / editing command input
	Executing, // OSC 133;C: shell is executing command
}

Cmd_Output :: struct {
	started:   bool, // 133;C seen
	ended:     bool, // 133;D seen after it
	head_lost: bool, // its first lines left the scrollback before a resize
	start:     i64,
	end:      i64,
	end_col:  int,
}

Cursor :: struct {
	row:          int,
	col:          int,
	saved_row:         int,
	saved_col:         int,
	saved_origin_mode: bool,
	saved_autowrap:    bool,
	active_fg:    u8,
	active_bg:    u8,
	active_style: cell.Style_Flags,
	active_flags: cell.Cell_Flags,
	underline_style: cell.Underline_Style, // SGR 4:n shape for newly written cells
	direct_color: cell.Direct_Color,
	visible:      bool,
	pending_wrap: bool,
	shape:        Cursor_Shape,
	blinking:     bool,
}

MAX_CSI_PARAMS      :: 16
// OSC payloads (clipboard OSC 52, OSC 8 hyperlinks, shell integration) are
// allowed to grow well past a single cell row, but never without a ceiling.
MAX_OSC_BUFFER      :: 1 * 1024 * 1024
MAX_APC_BUFFER      :: 16777216
MAX_DCS_BUFFER      :: 16777216
MAX_RESPONSE_BUFFER :: 1024

Osc_Callback    :: #type proc(user_data: rawptr, osc_id: int, payload: string) -> bool
Csi_Callback    :: #type proc(user_data: rawptr, cmd: rune, params: []int) -> bool
Apc_Callback    :: #type proc(user_data: rawptr, payload: []u8) -> bool
Dcs_Callback    :: #type proc(user_data: rawptr, payload: []u8) -> bool
Clear_Callback  :: #type proc(user_data: rawptr, mode: int)
// Alt_Screen_Callback is raised when the alternate screen buffer is entered or
// left. `mode` carries the original DEC private mode number (47/1047/1049).
Alt_Screen_Callback :: #type proc(user_data: rawptr, enter: bool, mode: int)
Scroll_Callback :: #type proc(user_data: rawptr, n: int, top, bottom: int)

Parser :: struct {
	state:            Parser_State,
	cursor:           Cursor,
	scroll_top:       int,
	scroll_bottom:    int,
	scroll_left:      int,
	scroll_right:     int,
	declrmm:          bool, // DECLRMM (?69) - Left and Right Margin Mode

	csi_params:       [MAX_CSI_PARAMS]int,
	// csi_sep[i] is the byte that terminated parameter i (';' or ':'), 0 when it
	// was the last parameter. Needed to tell `38;2;r;g;b` from `38:2:cs:r:g:b`.
	csi_sep:          [MAX_CSI_PARAMS]u8,
	csi_count:        int,
	csi_prefix:       u8, // e.g. '?'
	csi_intermediate: u8, // e.g. ' ' (0x20) for DECSCUSR

	// ISO-2022 character sets mapped onto GL, plus any pending one-shot shift.
	charsets:         [4]u8,
	gl:               u8,
	gl_single:        u8, // 2 = SS2 pending, 3 = SS3 pending, 0 = none
	esc_charset_slot: u8,

	in_alt_screen:    bool,
	saw_osc133:       bool,
	prompt_state:     Prompt_State,
	has_cmd_exit:     bool,
	last_cmd_exit:    i32,
	cmd_seq:          u32, // commands finished (OSC 133;D), for edge waits
	// Where the last command's output lies (OSC 133;C to 133;D) as grid lines
	// (grid.scrolled + row); terminal_cmd_output reads it.
	cmd_out:          Cmd_Output,
	sync_output:      bool, // (?2026) synchronized update: hold presentation
	// OSC 8 hyperlink currently in effect for newly written cells.
	active_link:      u16,
	// Kitty keyboard protocol: a small stack of progressive-enhancement flags.
	// The top of the stack is what key encoding must honour.
	kbd_flags:        [16]u8,
	kbd_depth:        u8,
	tab_stops:        [256]bool,
	last_print:       rune,
	cursor_key_mode:  bool, // DECCKM (?1)
	keypad_app:       bool, // DECKPAM (ESC =) / DECKPNM (ESC >)
	origin_mode:      bool, // DECOM (?6) - Origin Mode
	autowrap:         bool, // DECAWM (?7) - Auto-wrap Mode
	bracketed_paste:       bool, // Bracketed Paste (?2004)
	alternate_scroll_mode: bool, // Alternate Scroll (?1007)
	mouse_mode:            Mouse_Tracking_Mode,
	mouse_format:     Mouse_Format,
	report_focus:     bool, // Focus In/Out (?1004)

	osc_buf:          [dynamic]u8,
	osc_overflow:     bool,

	apc_buf:          [dynamic]u8,
	apc_overflow:     bool,

	dcs_buf:          [dynamic]u8,
	dcs_overflow:     bool,

	response_buf:     [MAX_RESPONSE_BUFFER]u8,
	response_len:     int,

	utf8_state:       u8,
	utf8_len:         u8,
	utf8_buf:         [4]u8,

	egc_pool:         ^egc.Egc_Pool,
	active_grid:      ^grid.Grid,
	active_damage:    ^damage.Damage_Tracker,

	on_osc:           Osc_Callback,
	on_csi:           Csi_Callback,
	on_apc:           Apc_Callback,
	on_dcs:           Dcs_Callback,
	on_clear:         Clear_Callback,
	on_scroll:        Scroll_Callback,
	on_alt_screen:    Alt_Screen_Callback,
	cell_w:           int,
	cell_h:           int,
	user_data:        rawptr,
}
