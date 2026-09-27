package session_core

// Session_Mode differentiates between promptless zero-overhead headless execution
// and full interactive shell execution with standard dotfiles and ZLE.
Session_Mode :: enum u8 {
	Fast_Headless,
	Interactive_GUI,
}

// Terminal_Observer_Port specifies callback hooks for terminal state mutations.
Terminal_Observer_Port :: struct {
	user_data:       rawptr,
	on_damage:       proc(user_data: rawptr, min_row, min_col, max_row, max_col: int),
	on_title_change: proc(user_data: rawptr, title: string),
	on_bell:         proc(user_data: rawptr),
	on_exit:         proc(user_data: rawptr, exit_code: int),
}

// Session_Config defines configuration options for spawning a core terminal session.
Session_Config :: struct {
	rows:     int,
	cols:     int,
	shell:    string,
	cwd:      string,
	mode:     Session_Mode,
	observer: Terminal_Observer_Port,
}
