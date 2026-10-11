package interaction

import termgrid "../terminal"

Interaction_Mode :: enum u8 {
	Passthrough = 0,
	Visual      = 1,
	Search      = 2,
}

Visual_Kind :: enum u8 {
	Char  = 0,
	Line  = 1,
	Block = 2,
}

Viewport_Flow :: enum u8 {
	Live   = 0,
	Paused = 1,
}

Interaction_Action :: enum u8 {
	None            = 0,
	Copy            = 1,
	Paste           = 2,
	Scroll_To_Match = 3,
	Resume_Live     = 4,
	Open_Link       = 5,
	Select_All      = 6,
}

Search_Match :: termgrid.Search_Match

MAX_SEARCH_MATCHES :: 256

Interaction_State :: struct {
	mode:                     Interaction_Mode,
	visual_kind:              Visual_Kind,
	viewport_flow:            Viewport_Flow,
	visual_cursor:            termgrid.Terminal_Point,
	selection_anchor:         termgrid.Terminal_Point,
	selection_active:         bool,
	pending_yank:             bool,
	paused_offset:            int,
	paused_lines_accumulated: int,
	search_query:             [256]u8,
	search_len:               int,
	search_active:            bool,
	search_matches:           [MAX_SEARCH_MATCHES]Search_Match,
	search_match_count:       int,
	search_match_idx:         int,
	status_msg:               [64]u8,
	status_len:               int,
}
