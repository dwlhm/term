package platform_tabs

import input "../input"

TAB_OVERFLOW_WIDTH: f32 : 280
TAB_OVERFLOW_ROW_HEIGHT: f32 : 28

// Tab_Info carries visual metadata for a tab item.
Tab_Info :: struct {
	id:        u32,
	title:     string,
	is_active: bool,
	is_exited: bool,
	has_bell:  bool,
}

UI_Tab_Info :: Tab_Info

// Selection binds to session identity, so reorder and close cannot select a different tab.
Tab_Overflow_State :: struct {
	visible:         bool,
	selected_tab_id: u32,
	scroll_row:      int,
	visible_rows:    int,
	rect:            Rect_f32,
}

Tab_Overflow_Action :: enum { None, Activate, Dismiss }

tab_overflow_close :: proc(m: ^Tab_Overflow_State) {
	if m != nil do m^ = Tab_Overflow_State{}
}

tab_overflow_selected_index :: proc(m: ^Tab_Overflow_State, tabs: []Tab_Info) -> int {
	for tab, i in tabs {
		if tab.id == m.selected_tab_id do return i
	}
	return -1
}

tab_overflow_refresh :: proc(m: ^Tab_Overflow_State, tabs: []Tab_Info, bar: ^Tab_Bar_State, window_w, window_h: f32) {
	if m == nil || !m.visible do return
	anchor := bar.overflow_indicator_rect if bar.overflow_indicator_rect.w > 0 else bar.overflow_rect
	if len(tabs) == 0 || anchor.w <= 0 {
		tab_overflow_close(m)
		return
	}
	idx := tab_overflow_selected_index(m, tabs)
	if idx < 0 {
		idx = 0
		for tab, i in tabs {
			if tab.is_active { idx = i; break }
		}
		m.selected_tab_id = tabs[idx].id
	}
	available_h := max(0, window_h - TAB_BAR_HEIGHT)
	m.visible_rows = min(len(tabs), int(available_h / TAB_OVERFLOW_ROW_HEIGHT))
	if m.visible_rows == 0 && available_h > 0 do m.visible_rows = 1
	width := min(TAB_OVERFLOW_WIDTH, max(0, window_w))
	m.rect = Rect_f32{x = clamp(anchor.x + anchor.w - width, 0, max(0, window_w-width)), y = TAB_BAR_HEIGHT, w = width, h = min(available_h, f32(m.visible_rows)*TAB_OVERFLOW_ROW_HEIGHT)}
	m.scroll_row = clamp(m.scroll_row, 0, max(0, len(tabs)-m.visible_rows))
	if idx < m.scroll_row do m.scroll_row = idx
	if idx >= m.scroll_row + m.visible_rows do m.scroll_row = max(0, idx-m.visible_rows+1)
}

tab_overflow_row_rect :: proc(m: ^Tab_Overflow_State, row: int) -> Rect_f32 {
	y := m.rect.y + f32(row)*TAB_OVERFLOW_ROW_HEIGHT
	return Rect_f32{x=m.rect.x, y=y, w=m.rect.w, h=min(TAB_OVERFLOW_ROW_HEIGHT, max(0, m.rect.y+m.rect.h-y))}
}

tab_overflow_dispatch_key :: proc(m: ^Tab_Overflow_State, tabs: []Tab_Info, ev: input.Input_Event) -> Tab_Overflow_Action {
	if ev.is_release do return .None
	idx := tab_overflow_selected_index(m, tabs)
	if len(tabs) == 0 do return .Dismiss
	if idx < 0 do idx = 0
	switch ev.kind {
	case .Escape: return .Dismiss
	case .Enter: return .Activate
	case .Arrow_Down: idx = (idx+1)%len(tabs)
	case .Arrow_Up: idx = (idx+len(tabs)-1)%len(tabs)
	case .Home: idx = 0
	case .End: idx = len(tabs)-1
	case .Printable, .Backspace, .Delete, .Tab, .Arrow_Left, .Arrow_Right, .PgUp, .PgDn, .Ctrl, .Alt_Mod:
		return .None
	}
	m.selected_tab_id = tabs[idx].id
	return .None
}

tab_overflow_dispatch_pointer :: proc(m: ^Tab_Overflow_State, tabs: []Tab_Info, x, y: f32, clicked: bool, wheel: int) -> Tab_Overflow_Action {
	if wheel != 0 && len(tabs) > 0 {
		idx := tab_overflow_selected_index(m, tabs)
		idx = clamp(idx-wheel, 0, len(tabs)-1)
		m.selected_tab_id = tabs[idx].id
		return .None
	}
	if !point_in_rect(x, y, m.rect) {
		if clicked do return .Dismiss
		return .None
	}
	row := int((y-m.rect.y)/TAB_OVERFLOW_ROW_HEIGHT)
	idx := m.scroll_row+row
	if row >= 0 && row < m.visible_rows && idx < len(tabs) {
		m.selected_tab_id = tabs[idx].id
		if clicked do return .Activate
	}
	return .None
}
