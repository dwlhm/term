package main

// Contract definitions for communication between Backend and Frontend.
// Decouples terminal/PTY state from OS window/GPU rendering.

import termgrid "../terminal"
import render "../render"
import input "../platform/input"
import interaction "../interaction"

// APP_DEFAULT_ROWS/COLS is the initial grid size (80x24).
APP_DEFAULT_ROWS :: 24
APP_DEFAULT_COLS :: 80

// APP_DRAIN_CAP caps one exhaustive pty_drain at 2MB (swallows giant output chunks).
APP_DRAIN_CAP :: 2 * 1024 * 1024

// APP_FRAME_INTERVAL_MS bounds the time spent polling when no event is ready.
// WGPU surface presentation (.Fifo) paces rendering to VSync; this interval
// is no longer used for artificial frame throttling.
APP_FRAME_INTERVAL_MS :: 8

// APP_CELL_W/H is the cell size in pixels. Must match the renderer's cell
// metrics and the input pump's fallback grid math, or the grid and the
// window drift apart.
APP_CELL_W :: 8
APP_CELL_H :: 16

// APP_FONT_SIZE is the requested font size in pixels.
APP_FONT_SIZE :: f32(13)

// APP_FONT_ZOOM_* bounds the logical font size requested by local zoom.
APP_FONT_ZOOM_MIN :: f32(8)
APP_FONT_ZOOM_MAX :: f32(32)
APP_FONT_ZOOM_STEP :: f32(1)

// APP_TITLE is the window title.
APP_TITLE :: "Term"

// APP_SHELL_FALLBACK is the shell when $SHELL is unset or empty.
APP_SHELL_FALLBACK :: "/bin/sh"

// APP_SHELL_ENV is the environment variable naming the login shell.
APP_SHELL_ENV :: "SHELL"

// APP_DEBUG_ENV gates frame diagnostics; APP_DEBUG_VALUE enables them.
APP_DEBUG_ENV :: "TERM_DEBUG"
APP_DEBUG_VALUE :: "1"

// APP_BANNER_EXIT_FMT is the one-shot exit banner; %d is the exit code.
APP_BANNER_EXIT_FMT :: "[ process exited (%d) - press R to relaunch, Q to quit ]"

// APP_BANNER_FAIL is the banner kept on screen when a relaunch fails.
APP_BANNER_FAIL :: "[ relaunch failed - press R to retry, Q to quit ]"

// APP_ALT_SCREEN_WHEEL_LINES is the number of arrow key events generated
// per mouse wheel tick when running on the alternate screen.
APP_ALT_SCREEN_WHEEL_LINES :: 3

// APP_SYNC_OUTPUT_TIMEOUT_NS bounds how long synchronized output (mode 2026)
// can defer rendering before forcing a frame (100ms safety timeout).
APP_SYNC_OUTPUT_TIMEOUT_NS :: 100_000_000

// APP_HUD_* constants define badge titles during modal interaction and viewport pause.
APP_HUD_VISUAL_FMT        :: "[ VISUAL %s ]"
APP_HUD_VISUAL_PAUSED_FMT :: "[ VISUAL %s (+%d lines) ]"
APP_HUD_PAUSED_FMT        :: "[ ⏸ PAUSED • Esc to Resume ]"
APP_HUD_PAUSED_ACC_FMT    :: "[ ⏸ PAUSED (+%d lines) • Esc to Resume ]"
APP_HUD_FIND_FMT          :: "[ FIND: '%s' (%d/%d) ]"
APP_HUD_FIND_EMPTY_FMT    :: "[ FIND: '%s' (0/0) ]"
APP_HUD_FIND_PROMPT       :: "[ FIND ]"

// Render_State encapsulates all grid and cursor data needed by the Frontend
// to compose and present a frame.
Render_State :: struct {
	terminal:             ^termgrid.Terminal,
	view:                 ^termgrid.Terminal_View,
	cursor:               ^render.Cursor_Overlay,
	interaction:          ^interaction.Interaction_State,
	cursor_dirty:         bool,
	focused:              bool,
	synchronized_output:  bool,
	sync_output_start_ns: u64,
	debug_frames:         bool,
}

// UI_Event_Type categorizes events crossing from Frontend to Backend.
UI_Event_Type :: enum {
	Input,
	Resize,
	Focus,
	Paste,
	Quit,
}

// UI_Event represents an event received by the frontend (keyboard, mouse,
// window resize, focus change, quit) to be processed by the backend.
UI_Event :: struct {
	type:        UI_Event_Type,
	input:       input.Input_Event,
	pixel_w:     i32,
	pixel_h:     i32,
	rows:        int,
	cols:        int,
	focused:     bool,
	text:        string,
}

// App_Exit_Action is the per-key decision while the child is Exited.
App_Exit_Action :: enum {
	None,
	Relaunch,
	Quit,
}

// Clipboard callbacks allow Backend to perform OSC 52 operations without
// depending on SDL or windowing libraries.
Clipboard_Write_Proc :: #type proc(user_data: rawptr, text: string)
Clipboard_Read_Proc  :: #type proc(user_data: rawptr, out: []u8) -> int

// grid_dimensions_for_pixels converts window pixel dimensions and cell metrics
// to grid row and column counts.
grid_dimensions_for_pixels :: proc(
	pixel_w, pixel_h: i32,
	cell_w, cell_h, pad_x, pad_y: f32,
) -> (rows, cols: int) {
	cw := int(cell_w)
	if cw <= 0 {
		cw = APP_CELL_W
	}
	ch := int(cell_h)
	if ch <= 0 {
		ch = APP_CELL_H
	}
	avail_w := int(pixel_w) - int(2 * pad_x)
	avail_h := int(pixel_h) - int(pad_y) - int(pad_x)
	if avail_w < cw {
		avail_w = cw
	}
	if avail_h < ch {
		avail_h = ch
	}
	cols = avail_w / cw
	rows = avail_h / ch
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	return rows, cols
}

// _app_grid_for_pixels preserves legacy naming compatibility.
_app_grid_for_pixels :: grid_dimensions_for_pixels

// app_handle_exited_key routes one input event while the child is Exited.
// Printable 'r'/'R' relaunches, Printable 'q'/'Q' and Escape quit;
// every other kind (incl Ctrl/Alt/arrows) is ignored.
app_handle_exited_key :: proc(ev: input.Input_Event) -> App_Exit_Action {
	#partial switch ev.kind {
	case .Printable:
		if ev.rune == 'r' || ev.rune == 'R' {
			return .Relaunch
		}
		if ev.rune == 'q' || ev.rune == 'Q' {
			return .Quit
		}
		return .None
	case .Escape:
		return .Quit
	case:
		return .None
	}
}
