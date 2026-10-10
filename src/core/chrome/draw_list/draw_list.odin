package draw_list

// Pure Declarative UI Geometry Engine - Ui_Draw_List Primitives.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.
// Depends only on `base:runtime`. Emits pure geometric records consumed
// by `core_render/chrome`.

import "base:runtime"

// Ui_Cmd_Kind discriminates declarative drawing primitives.
Ui_Cmd_Kind :: enum {
	Rect,
	Rounded_Rect,
	Border,
	Text_Run,
	Icon,
	Shadow,
}

// Ui_Draw_Cmd is a pure geometric command with no GPU dependencies.
// rect: [x, y, width, height] in logical/physical pixels
// color: [r, g, b, a] in normalized sRGB (0.0 .. 1.0)
// border_color: [r, g, b, a] in normalized sRGB (0.0 .. 1.0)
// radius: corner radius for rounded rect / border / shadow
// text: text payload for Text_Run
// clip_rect: [min_x, min_y, max_x, max_y] bounding scissor (all zeroes = no clip)
Ui_Draw_Cmd :: struct {
	kind:         Ui_Cmd_Kind,
	rect:         [4]f32,
	color:        [4]f32,
	border_color: [4]f32,
	radius:       f32,
	text:         string,
	clip_rect:    [4]f32,
}

// Ui_Draw_List holds an ordered sequence of 2D drawing primitives.
Ui_Draw_List :: struct {
	commands:  [dynamic]Ui_Draw_Cmd,
	allocator: runtime.Allocator,
}

// ui_draw_list_init initializes the draw list buffer.
ui_draw_list_init :: proc(dl: ^Ui_Draw_List, allocator := context.allocator) {
	if dl == nil do return
	dl.allocator = allocator
	dl.commands = make([dynamic]Ui_Draw_Cmd, allocator)
}

// ui_draw_list_destroy deallocates the commands slice.
ui_draw_list_destroy :: proc(dl: ^Ui_Draw_List) {
	if dl == nil do return
	delete(dl.commands)
	dl.commands = nil
}

// ui_draw_list_clear resets command count without releasing capacity.
ui_draw_list_clear :: proc(dl: ^Ui_Draw_List) {
	if dl == nil do return
	clear(&dl.commands)
}

// ui_draw_rect appends a flat filled rectangle command.
ui_draw_rect :: proc(dl: ^Ui_Draw_List, rect: [4]f32, color: [4]f32, clip_rect: [4]f32 = {}) {
	if dl == nil do return
	cmd := Ui_Draw_Cmd{
		kind      = .Rect,
		rect      = rect,
		color     = color,
		clip_rect = clip_rect,
	}
	append(&dl.commands, cmd)
}

// ui_draw_rounded_rect appends a filled rounded rectangle command.
ui_draw_rounded_rect :: proc(dl: ^Ui_Draw_List, rect: [4]f32, color: [4]f32, radius: f32, clip_rect: [4]f32 = {}) {
	if dl == nil do return
	cmd := Ui_Draw_Cmd{
		kind      = .Rounded_Rect,
		rect      = rect,
		color     = color,
		radius    = radius,
		clip_rect = clip_rect,
	}
	append(&dl.commands, cmd)
}

// ui_draw_border appends an outline border command with optional corner radius.
ui_draw_border :: proc(dl: ^Ui_Draw_List, rect: [4]f32, border_color: [4]f32, radius: f32 = 0, clip_rect: [4]f32 = {}) {
	if dl == nil do return
	cmd := Ui_Draw_Cmd{
		kind         = .Border,
		rect         = rect,
		border_color = border_color,
		radius       = radius,
		clip_rect    = clip_rect,
	}
	append(&dl.commands, cmd)
}

// ui_draw_text appends a text run command.
ui_draw_text :: proc(dl: ^Ui_Draw_List, rect: [4]f32, text: string, color: [4]f32, clip_rect: [4]f32 = {}) {
	if dl == nil do return
	cmd := Ui_Draw_Cmd{
		kind      = .Text_Run,
		rect      = rect,
		color     = color,
		text      = text,
		clip_rect = clip_rect,
	}
	append(&dl.commands, cmd)
}

// ui_draw_shadow appends a drop-shadow command.
ui_draw_shadow :: proc(dl: ^Ui_Draw_List, rect: [4]f32, color: [4]f32, radius: f32, clip_rect: [4]f32 = {}) {
	if dl == nil do return
	cmd := Ui_Draw_Cmd{
		kind      = .Shadow,
		rect      = rect,
		color     = color,
		radius    = radius,
		clip_rect = clip_rect,
	}
	append(&dl.commands, cmd)
}
