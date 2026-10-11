package input_core

// Input_Event_Type distinguishes PTY keys from terminal-local events.
Input_Event_Type :: enum u8 {
	Key,
	Pointer,
	Local,
	Drop,
}

// Input_Pointer_Kind identifies one terminal-local pointer transition.
Input_Pointer_Kind :: enum u8 {
	Motion,
	Button_Down,
	Button_Up,
	Wheel,
}

// Input_Local_Action identifies an action handled by the application.
Input_Local_Action :: enum u8 {
	None,
	Copy,
	Paste,
	Zoom_In,
	Zoom_Out,
	Reload_Config,
	Detach_Tab,
	Attach_Session,
}

// Input_Drop_Kind distinguishes file path drops, text drops, and hover/completion states.
Input_Drop_Kind :: enum u8 {
	File,
	Text,
	Position,
	Begin,
	Complete,
}

// Input_Drop_Event carries drag-and-drop data from the OS.
// text holds a heap-allocated copy of the dropped content; callers must delete it for File/Text.
Input_Drop_Event :: struct {
	kind: Input_Drop_Kind,
	text: string, // heap-allocated; caller must delete after use for File/Text
	x:    f32,
	y:    f32,
}

// Input_Pointer_Event carries SDL mouse data without terminal mouse-reporting
// bytes. Coordinates are in window pixels; wheel_integer_* are SDL's whole
// scroll ticks and wheel_* preserve the high-resolution deltas.
Input_Pointer_Event :: struct {
	kind:              Input_Pointer_Kind,
	x, y:              f32,
	dx, dy:            f32,
	button:            u8,
	clicks:            u8,
	pressed:           bool,
	primary_down:      bool,
	wheel_x, wheel_y:  f32,
	wheel_integer_x:   i32,
	wheel_integer_y:   i32,
	wheel_flipped:     bool,
	shift:             bool,
	gui:               bool,
}

// Input_Key_Kind names the key carried by a key Input_Event.
Input_Key_Kind :: enum u8 {
	Printable,
	Enter,
	Backspace,
	Delete,
	Tab,
	Escape,
	Arrow_Up,
	Arrow_Down,
	Arrow_Left,
	Arrow_Right,
	Home,
	End,
	PgUp,
	PgDn,
	Ctrl,
	Alt_Mod,
}

// Input_Event is one translated SDL event. Key events retain the original
// key-oriented fields; pointer and local events use pointer/action instead.
// Non-key events are local to the terminal application and encode to zero
// PTY bytes. paste_shadow marks SDL text matching a local paste so app
// dispatch can keep it for an active text editor or skip it for the PTY.
Input_Event :: struct {
	event_type: Input_Event_Type,
	kind:       Input_Key_Kind,
	rune:       rune,
	ctrl:       bool,
	alt:        bool,
	shift:      bool,
	gui:        bool,
	is_release: bool,
	paste_shadow: bool,
	pointer:    Input_Pointer_Event,
	action:     Input_Local_Action,
	drop:       Input_Drop_Event,
}

