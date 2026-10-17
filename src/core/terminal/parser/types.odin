package terminal_parser

import cell "../cell"
import egc "../egc"

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

Cursor :: struct {
	row:          int,
	col:          int,
	saved_row:    int,
	saved_col:    int,
	active_fg:    u8,
	active_bg:    u8,
	active_style: cell.Style_Flags,
	active_flags: cell.Cell_Flags,
	direct_color: cell.Direct_Color,
	visible:      bool,
	pending_wrap: bool,
	shape:        Cursor_Shape,
	blinking:     bool,
}

MAX_CSI_PARAMS      :: 16
MAX_OSC_BUFFER      :: 512
MAX_RESPONSE_BUFFER :: 256

Osc_Callback :: #type proc(user_data: rawptr, osc_id: int, payload: string) -> bool
Csi_Callback :: #type proc(user_data: rawptr, cmd: rune, params: []int) -> bool

Parser :: struct {
	state:            Parser_State,
	cursor:           Cursor,
	scroll_top:       int,
	scroll_bottom:    int,

	csi_params:       [MAX_CSI_PARAMS]int,
	csi_count:        int,
	csi_prefix:       u8, // e.g. '?'
	csi_intermediate: u8, // e.g. ' ' (0x20) for DECSCUSR

	in_alt_screen:    bool,
	cursor_key_mode:  bool, // DECCKM (?1)

	osc_buf:          [MAX_OSC_BUFFER]u8,
	osc_len:          int,

	response_buf:     [MAX_RESPONSE_BUFFER]u8,
	response_len:     int,

	utf8_state:       u8,
	utf8_len:         u8,
	utf8_buf:         [4]u8,

	egc_pool:         ^egc.Egc_Pool,

	on_osc:           Osc_Callback,
	on_csi:           Csi_Callback,
	user_data:        rawptr,
}
