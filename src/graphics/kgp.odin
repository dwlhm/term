package graphics

import "base:runtime"

// Action is the KGP command type.
Action :: enum u8 {
	Transmit,       // t
	Transmit_Put,   // T
	Put,            // p
	Query,          // q
	Delete,         // d
	Frame,          // f
	Animate,        // a
	Compose,        // c
}

// Medium is the payload delivery method.
Medium :: enum u8 {
	Direct,        // d
	File,          // f
	Temp_File,     // t
	Shared_Memory, // s
}

// Format is the pixel encoding.
Format :: enum u8 {
	RGB24 = 24,
	RGBA32 = 32,
	PNG = 100,
}

// Feed_Result is the outcome of processing a KGP command.
Feed_Result :: enum u8 {
	Ok,
	NotFound,
	Invalid,
	Unsupported,
	No_Space,
}

// Control holds all parsed KGP key=value pairs.
Control :: struct {
	action:       Action,
	format:       Format,
	medium:       Medium,
	compression:  u8, // 0=none, 'z'=zlib
	id:           u32,
	number:       u32,
	placement_id: u32,
	quiet:        u8,
	src_w:        u32,
	src_h:        u32,
	file_size:    u32,
	file_offset:  u32,
	cols:         u16,
	rows:         u16,
	cell_x:       u32,
	cell_y:       u32,
	z:            i32,
	src_x:        u32,
	src_y:        u32,
	src_rect_w:   u32,
	src_rect_h:   u32,
	parent_id:    u32,
	parent_pl:    u32,
	rel_h:        i32,
	rel_v:        i32,
	cursor_pol:   u8,
	unicode_ph:   u8,
	more:         bool,
	delete_mode:  u8, // 0=none, 'a'/'A'/'i'/'I'/'n'/'N'/'c'/'C'/'f'/'F'/'x'/'y'/'z'/'Z'/'w'/'W'
	delete_id:    u32,
	delete_num:   u32,
	delete_pl:    u32,
	delete_z:     i32,
	delete_x:     u32,
	delete_y:     u32,
	// Action-specific animation fields. The wire keys are overloaded by the
	// display and animation actions, so parsing keeps their meanings separate.
	frame_edit:           u32,
	frame_background:     u32,
	compose_source:       u32,
	compose_destination:  u32,
	animate_frame:        u32,
	animate_current:      u32,
	frame_gap:            i32,
	frame_gap_set:        bool,
	animation_state:      u32,
	animation_loops:      u32,
	compose_mode:         u8,
	background_color:     u32,
	background_color_set: bool,
	usage:                u32,
}

// Response_Sink is the callback for sending KGP responses.
Response_Sink :: struct {
	user_data: rawptr,
	write:     proc(user_data: rawptr, data: []u8),
}
