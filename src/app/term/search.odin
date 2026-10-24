package term

// In-terminal search bar state (Cmd+F).
//
// The query is searched across the visible grid and scrollback; the active match
// is highlighted through the existing selection overlay, so no extra GPU work is
// needed and the pane scrolls to keep the match visible.

import "core:strings"
import "vendor:sdl3"
import mux_feat "../../features/multiplexer"
import inter_feat "../../features/interaction"

Search_State :: struct {
	active:    bool,
	input:     Text_Input,
	match:     inter_feat.Search_Match,
	has_match: bool,
	dirty:     bool,
}

app_search_query :: proc(app: ^Term_App) -> string {
	return text_input_as_string(&app.search.input)
}

app_search_open :: proc(app: ^Term_App) {
	if app == nil do return
	app.search.active = true
	app.search.dirty = true
	text_input_select_all(&app.search.input)
	app_search_refresh(app, forward = true)
}

app_search_close :: proc(app: ^Term_App) {
	if app == nil do return
	app.search.active = false
	app.search.has_match = false
	app.search.match = {}
	if app.mouse.selection.pane_id == app.mux.focused_pane_id {
		mouse_clear_selection(&app.mouse)
	}
}

app_search_toggle :: proc(app: ^Term_App) {
	if app.search.active {
		app_search_close(app)
	} else {
		app_search_open(app)
	}
}

app_search_clear :: proc(app: ^Term_App) {
	text_input_clear(&app.search.input)
	app.search.has_match = false
	app.search.dirty = true
}

app_search_append :: proc(app: ^Term_App, text: string) {
	if app == nil || len(text) == 0 do return
	if text_input_insert(&app.search.input, text) {
		app.search.dirty = true
		app_search_refresh(app, forward = true)
	}
}

app_search_backspace :: proc(app: ^Term_App) {
	if app == nil do return
	if text_input_delete_back(&app.search.input) {
		app.search.dirty = true
		app_search_refresh(app, forward = true)
	}
}

app_search_handle_key :: proc(app: ^Term_App, key: sdl3.Keycode, mod: sdl3.Keymod) -> bool {
	if app == nil || !app.search.active do return false
	changed, handled := text_input_handle_key(&app.search.input, key, mod)
	if changed {
		app.search.dirty = true
		app_search_refresh(app, forward = true)
	}
	return handled
}

// app_search_refresh re-runs the search from the current match (or the top of the
// visible area) and selects the hit.
app_search_refresh :: proc(app: ^Term_App, forward: bool) {
	if app == nil do return
	pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
	if pane == nil || pane.session == nil {
		app.search.has_match = false
		return
	}

	query := app_search_query(app)
	if len(query) == 0 {
		app.search.has_match = false
		return
	}

	anchor_row := 0
	anchor_col := 0
	if app.search.has_match {
		anchor_row = app.search.match.row
		anchor_col = app.search.match.col_start + 1 if forward else app.search.match.col_start - 1
	}

	match := inter_feat.search_find(&pane.session.term, query, anchor_row, anchor_col, forward)
	app.search.match = match
	app.search.has_match = match.found
	if !match.found do return

	start, end := inter_feat.search_match_cells(match)
	app.mouse.selection = inter_feat.Selection_State{
		active     = true,
		mode       = .Stream,
		pane_id    = pane.id,
		start_cell = start,
		end_cell   = end,
	}
	app_search_reveal(app, pane, match)
}

// app_search_reveal scrolls the pane so the match is on screen.
app_search_reveal :: proc(app: ^Term_App, pane: ^mux_feat.Pane_Entry, match: inter_feat.Search_Match) {
	if pane == nil || pane.session == nil do return
	rows := pane.session.term.rows
	switch {
	case match.row < 0:
		pane.session.scroll_offset = min(-match.row, pane.session.term.grid.history_count)
	case match.row >= rows:
		pane.session.scroll_offset = max(0, match.row - rows + 1)
	case:
		pane.session.scroll_offset = 0
	}
}

// app_search_step moves to the next/previous match.
app_search_step :: proc(app: ^Term_App, forward: bool) {
	if app == nil || len(app_search_query(app)) == 0 do return
	if !app.search.has_match {
		app_search_refresh(app, forward)
		return
	}
	app_search_refresh(app, forward)
}

app_search_status :: proc(app: ^Term_App) -> string {
	if !app.search.active do return ""
	query := app_search_query(app)
	if len(query) == 0 do return "Type to search"
	if app.search.has_match do return "Match found"
	return strings.concatenate({"No match: ", query}, context.temp_allocator)
}
