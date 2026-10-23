package term

// OSC 8 hyperlink activation (Cmd+Click).
//
// The parser stores the link id beside the cell; this module resolves the cell
// under the pointer and hands the URI to the platform. Only web/mail schemes are
// allowed so a hostile PTY stream cannot launch arbitrary handlers.

import "core:strings"
import "vendor:sdl3"
import cursor "../../core/cursor"
import core_terminal "../../core/terminal"
import inter_feat "../../features/interaction"

_hyperlink_scheme_allowed :: proc(uri: string) -> bool {
	for prefix in ([?]string{"http://", "https://", "mailto:"}) {
		if strings.has_prefix(uri, prefix) do return true
	}
	return false
}

// Hyperlink_Hover is the app-side hover state for the OSC 8 run under the
// pointer: the owning pane, the logical grid row, and the inclusive column span
// (expanded across spaces). `blocked` marks a link with a disallowed scheme.
Hyperlink_Hover :: struct {
	active:    bool,
	pane_id:   u32,
	row:       int,
	col_start: int,
	col_end:   int,
	blocked:   bool,
}

// _app_hyperlink_cell resolves the hyperlink-bearing cell under the pointer,
// returning the owning pane id, the terminal, and the resolved link metadata.
_app_hyperlink_cell :: proc(app: ^Term_App, mx, my: f32) -> (pane_id: u32, term: ^core_terminal.Terminal, cell_row, cell_col: int, link_id: u16, uri: string, ok: bool) {
	if app == nil do return 0, nil, 0, 0, 0, "", false
	for &pane in app.mux.panes {
		if pane.kind != .Terminal || pane.session == nil do continue
		if !inter_feat.is_in_rect({mx, my}, pane.rect) do continue

		eff_px, eff_py := pane_grid_pad(
			pane.rect,
			pane.session.term.rows,
			pane.session.term.cols,
			app.layout.metrics.cell_w,
			app.layout.metrics.cell_h,
			app.layout.metrics.pane_pad_x,
			app.layout.metrics.pane_pad_y,
		)
		screen_row, cell_col := inter_feat.pixel_to_cell(
			{mx, my},
			pane.rect,
			app.layout.metrics.cell_w,
			app.layout.metrics.cell_h,
			eff_px,
			eff_py,
		)
		cell_row := screen_row - pane.session.scroll_offset
		link_id, uri := core_terminal.terminal_cell_hyperlink(&pane.session.term, cell_row, cell_col)
		return pane.id, &pane.session.term, cell_row, cell_col, link_id, uri, true
	}
	return 0, nil, 0, 0, 0, "", false
}

// app_hyperlink_at returns the URI under the pointer, if any.
app_hyperlink_at :: proc(app: ^Term_App, mx, my: f32) -> string {
	_, _, _, _, _, uri, ok := _app_hyperlink_cell(app, mx, my)
	return uri if ok else ""
}

// app_hyperlink_highlight computes the hover highlight for the OSC 8 run under
// the pointer: the full contiguous span (spaces included) and its openable vs
// blocked classification.
app_hyperlink_highlight :: proc(app: ^Term_App, mx, my: f32) -> Hyperlink_Hover {
	result: Hyperlink_Hover
	pane_id, term, cell_row, cell_col, link_id, uri, ok := _app_hyperlink_cell(app, mx, my)
	if !ok || term == nil || link_id == 0 do return result

	col_start, col_end, span_ok := core_terminal.terminal_hyperlink_span(term, cell_row, cell_col)
	if !span_ok do return result

	result.active = true
	result.pane_id = pane_id
	result.row = cell_row
	result.col_start = col_start
	result.col_end = col_end
	result.blocked = !_hyperlink_scheme_allowed(uri)
	return result
}

// app_open_hyperlink_at opens the OSC 8 link under the pointer (Cmd+Click).
app_open_hyperlink_at :: proc(app: ^Term_App, mx, my: f32) -> bool {
	uri := app_hyperlink_at(app, mx, my)
	if len(uri) == 0 || !_hyperlink_scheme_allowed(uri) do return false
	return sdl3.OpenURL(strings.clone_to_cstring(uri, context.temp_allocator))
}

// _hyperlink_cursor_for maps a resolved URI to the hover cursor that communicates
// the affordance: openable links get a hand pointer, links with a blocked scheme
// get "not allowed", and an empty URI means there is no link under the pointer.
_hyperlink_cursor_for :: proc(uri: string) -> (cursor.Mouse_Cursor, bool) {
	if len(uri) == 0 do return .Default, false
	return (.Pointer if _hyperlink_scheme_allowed(uri) else .Not_Allowed), true
}
