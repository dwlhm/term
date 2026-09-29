package platform_tabs

import input "../input"
import i18n "../../i18n"

DRAG_THRESHOLD_PX: f32 : 4.0

// Tab_Drag_Phase tracks the pointer lifecycle of a tab reorder gesture.
Tab_Drag_Phase :: enum u8 {
	Idle = 0,
	Pressed,
	Dragging,
}

// Tab_Drag_Action reports the discrete transition produced by a drag pointer event.
Tab_Drag_Action :: enum u8 {
	None = 0,
	Move,
	Drop,
	Cancel,
}

// Tab_Drag_State owns the drag-to-reorder gesture for the tab strip.
Tab_Drag_State :: struct {
	phase:     Tab_Drag_Phase,
	from_idx:  int,
	from_id:   u32,
	drop_gap:  int,
	press_x:   f32,
	pointer_x: f32,
	pointer_y: f32,
}

// tab_drag_reset returns a drag state to the idle baseline.
tab_drag_reset :: proc(d: ^Tab_Drag_State) {
	if d == nil do return
	d^ = Tab_Drag_State{}
	d.from_idx = -1
	d.drop_gap = -1
}

// tab_drag_begin arms a press gesture over a tab. The drag only leaves the
// pressed phase once the pointer travels DRAG_THRESHOLD_PX horizontally.
tab_drag_begin :: proc(d: ^Tab_Drag_State, tab_idx: int, tab_id: u32, px, py: f32) -> bool {
	if d == nil || tab_idx < 0 do return false
	d.phase = .Pressed
	d.from_idx = tab_idx
	d.from_id = tab_id
	d.drop_gap = tab_idx
	d.press_x = px
	d.pointer_x = px
	d.pointer_y = py
	return true
}

// tab_bar_drop_gap resolves the insertion boundary 0..tab_count nearest x by
// comparing against each (already scrolled) tab center.
tab_bar_drop_gap :: proc(bar: ^Tab_Bar_State, tab_count: int, tab_rects: []Rect_f32, x: f32) -> int {
	if bar == nil do return 0
	count := clamp(tab_count, 0, len(tab_rects))
	for i in 0 ..< count {
		center := tab_rects[i].x + tab_rects[i].w * 0.5
		if x < center do return i
	}
	return count
}

// tab_bar_gap_x returns the pixel x of an insertion boundary: the left edge of
// tab_rects[gap], or the right edge of the last tab when gap == count.
tab_bar_gap_x :: proc(bar: ^Tab_Bar_State, tab_count: int, tab_rects: []Rect_f32, gap: int) -> f32 {
	if bar == nil do return 0
	count := clamp(tab_count, 0, len(tab_rects))
	if count == 0 do return bar.left_offset - bar.scroll_offset
	if gap <= 0 do return tab_rects[0].x
	if gap >= count do return tab_rects[count - 1].x + tab_rects[count - 1].w
	return tab_rects[gap].x
}

// tab_drag_dispatch_pointer advances a drag gesture. It consumes every pointer
// event while pressed or dragging so motion never leaks to the terminal. Button
// down is owned by the caller (begin). Drop returns the resolved drop boundary,
// after which the state resets to Idle.
tab_drag_dispatch_pointer :: proc(
	d: ^Tab_Drag_State,
	bar: ^Tab_Bar_State,
	tab_count: int,
	tab_rects: []Rect_f32,
	px, py: f32,
	kind: input.Input_Pointer_Kind,
	button: u8,
) -> (consumed: bool, action: Tab_Drag_Action, drop_gap: int) {
	if d == nil || d.phase == .Idle do return false, .None, -1
	if tab_count <= 0 || d.from_idx < 0 || d.from_idx >= tab_count {
		tab_drag_reset(d)
		return true, .Cancel, -1
	}

	switch kind {
	case .Motion:
		if d.phase == .Pressed && abs(px - d.press_x) >= DRAG_THRESHOLD_PX {
			d.phase = .Dragging
		}
		d.pointer_x = px
		d.pointer_y = py
		if d.phase == .Dragging {
			d.drop_gap = tab_bar_drop_gap(bar, tab_count, tab_rects, px)
			return true, .Move, d.drop_gap
		}
		return true, .Move, d.drop_gap

	case .Button_Up:
		if button == 1 {
			if d.phase == .Dragging {
				gap := d.drop_gap
				tab_drag_reset(d)
				return true, .Drop, gap
			}
			tab_drag_reset(d)
			return true, .None, -1
		}
		return true, .None, -1

	case .Button_Down, .Wheel:
		return true, .None, -1
	}

	return true, .None, -1
}

TAB_MENU_ITEM_COUNT :: 5
TAB_MENU_WIDTH: f32 : 210.0
TAB_MENU_ITEM_H: f32 : 26.0
TAB_MENU_PAD_Y: f32 : 4.0
TAB_MENU_HEIGHT: f32 : 2 * TAB_MENU_PAD_Y + f32(TAB_MENU_ITEM_COUNT) * TAB_MENU_ITEM_H

// Tab_Menu_Item enumerates the tab context menu entries in display order.
Tab_Menu_Item :: enum u8 {
	Close = 0,
	Close_Others,
	Close_To_Right,
	New_Tab,
	Rename,
}

// Tab_Menu_Action reports the discrete outcome of a menu interaction.
Tab_Menu_Action :: enum u8 {
	None = 0,
	Activated,
	Dismissed,
}

// Tab_Menu_State owns the right-click tab context menu, the discovery surface
// listing every tab action with its real shortcut hint.
Tab_Menu_State :: struct {
	visible:      bool,
	target_idx:   int,
	target_id:    u32,
	rect:         Rect_f32,
	anchor_x:     f32,
	anchor_y:     f32,
	item_rects:   [TAB_MENU_ITEM_COUNT]Rect_f32,
	disabled:     [TAB_MENU_ITEM_COUNT]bool,
	active_item:  int,
	hover_item:   int,
}

// tab_menu_init initializes the context menu to a hidden, fully disabled state.
tab_menu_init :: proc(m: ^Tab_Menu_State) {
	if m == nil do return
	m.visible = false
	m.target_idx = -1
	m.target_id = 0
	m.rect = Rect_f32{}
	m.anchor_x = 0
	m.anchor_y = 0
	m.item_rects = {}
	for i in 0 ..< TAB_MENU_ITEM_COUNT {
		m.disabled[i] = true
	}
	m.active_item = -1
	m.hover_item = -1
}

// tab_menu_refresh applies the enable rules for the current tab topology.
tab_menu_refresh :: proc(m: ^Tab_Menu_State, tab_count, max_tabs: int) {
	if m == nil do return
	m.disabled[int(Tab_Menu_Item.Close)] = !(tab_count >= 1)
	m.disabled[int(Tab_Menu_Item.Close_Others)] = !(tab_count > 1)
	m.disabled[int(Tab_Menu_Item.Close_To_Right)] = !(m.target_idx >= 0 && m.target_idx < tab_count - 1)
	m.disabled[int(Tab_Menu_Item.New_Tab)] = !(tab_count < max_tabs)
	m.disabled[int(Tab_Menu_Item.Rename)] = !(m.target_idx >= 0 && m.target_idx < tab_count)
}

// tab_menu_layout recomputes item rectangles and clamps the panel inside the window.
tab_menu_layout :: proc(m: ^Tab_Menu_State, window_w, window_h: f32) {
	if m == nil do return
	w := TAB_MENU_WIDTH
	h := TAB_MENU_HEIGHT
	x := clamp(m.anchor_x, 0, max(0, window_w - w))
	y := clamp(m.anchor_y, 0, max(0, window_h - h))
	m.rect = Rect_f32{x = x, y = y, w = w, h = h}

	iy := y + TAB_MENU_PAD_Y
	for i in 0 ..< TAB_MENU_ITEM_COUNT {
		m.item_rects[i] = Rect_f32{x = x, y = iy, w = w, h = TAB_MENU_ITEM_H}
		iy += TAB_MENU_ITEM_H
	}
}

// tab_menu_open shows the menu anchored at the click point and refreshes rules.
tab_menu_open :: proc(
	m: ^Tab_Menu_State,
	target_idx: int,
	target_id: u32,
	tab_count, max_tabs: int,
	px, py, window_w, window_h: f32,
) {
	if m == nil do return
	m.visible = true
	m.target_idx = target_idx
	m.target_id = target_id
	m.anchor_x = px
	m.anchor_y = py
	m.active_item = -1
	m.hover_item = -1
	tab_menu_refresh(m, tab_count, max_tabs)
	tab_menu_layout(m, window_w, window_h)
}

// tab_menu_close hides the menu and clears its target binding.
tab_menu_close :: proc(m: ^Tab_Menu_State) {
	if m == nil do return
	m.visible = false
	m.target_idx = -1
	m.target_id = 0
	m.active_item = -1
	m.hover_item = -1
}

// _tab_menu_next_enabled walks wrap-around from cur in dir (+1/-1) to the next
// enabled item, returning cur when every item is disabled.
_tab_menu_next_enabled :: proc(m: ^Tab_Menu_State, cur, dir: int) -> int {
	idx := 0
	if cur < 0 {
		idx = 0 if dir > 0 else TAB_MENU_ITEM_COUNT - 1
	} else {
		idx = (cur + dir + TAB_MENU_ITEM_COUNT) % TAB_MENU_ITEM_COUNT
	}
	for _ in 0 ..< TAB_MENU_ITEM_COUNT {
		if !m.disabled[idx] do return idx
		idx = (idx + dir + TAB_MENU_ITEM_COUNT) % TAB_MENU_ITEM_COUNT
	}
	return cur
}

// tab_menu_dispatch_pointer handles modal pointer interaction. Hover sets the
// hover item; a click on an enabled item activates it, a click on a disabled
// item is swallowed, and a click outside the panel dismisses the menu.
tab_menu_dispatch_pointer :: proc(
	m: ^Tab_Menu_State,
	px, py: f32,
	is_click: bool,
	tab_count, max_tabs: int,
) -> (consumed: bool, action: Tab_Menu_Action, item: Tab_Menu_Item) {
	if m == nil || !m.visible do return false, .None, .Close
	tab_menu_refresh(m, tab_count, max_tabs)

	if is_click {
		hit := -1
		for i in 0 ..< TAB_MENU_ITEM_COUNT {
			if point_in_rect(px, py, m.item_rects[i]) {
				hit = i
				break
			}
		}
		if hit < 0 {
			if !point_in_rect(px, py, m.rect) do return true, .Dismissed, .Close
			return true, .None, .Close
		}
		if m.disabled[hit] do return true, .None, .Close
		return true, .Activated, Tab_Menu_Item(hit)
	}

	hover := -1
	if point_in_rect(px, py, m.rect) {
		for i in 0 ..< TAB_MENU_ITEM_COUNT {
			if point_in_rect(px, py, m.item_rects[i]) {
				if !m.disabled[i] do hover = i
				break
			}
		}
	}
	m.hover_item = hover
	return true, .None, .Close
}

// tab_menu_dispatch_key handles modal key navigation.
tab_menu_dispatch_key :: proc(
	m: ^Tab_Menu_State,
	ev: input.Input_Event,
	tab_count, max_tabs: int,
) -> (consumed: bool, action: Tab_Menu_Action, item: Tab_Menu_Item) {
	if m == nil || !m.visible do return false, .None, .Close
	tab_menu_refresh(m, tab_count, max_tabs)
	if ev.is_release do return true, .None, .Close

	switch ev.kind {
	case .Escape:
		return true, .Dismissed, .Close
	case .Enter:
		if m.active_item >= 0 && m.active_item < TAB_MENU_ITEM_COUNT && !m.disabled[m.active_item] {
			return true, .Activated, Tab_Menu_Item(m.active_item)
		}
		return true, .None, .Close
	case .Arrow_Down:
		m.active_item = _tab_menu_next_enabled(m, m.active_item, 1)
		return true, .None, .Close
	case .Arrow_Up:
		m.active_item = _tab_menu_next_enabled(m, m.active_item, -1)
		return true, .None, .Close
	case .Printable, .Backspace, .Delete, .Tab, .Arrow_Left, .Arrow_Right, .Home, .End, .PgUp, .PgDn, .Ctrl, .Alt_Mod:
		return true, .None, .Close
	}
	return true, .None, .Close
}

// tab_menu_item_label resolves the localized label for a menu item.
tab_menu_item_label :: proc(copy: ^i18n.Strings, item: Tab_Menu_Item) -> string {
	c := copy
	if c == nil do c = i18n.i18n_get()
	switch item {
	case .Close:
		return c.menu_close_tab
	case .Close_Others:
		return c.menu_close_others
	case .Close_To_Right:
		return c.menu_close_to_right
	case .New_Tab:
		return c.menu_new_tab
	case .Rename:
		return c.menu_rename
	}
	return ""
}

// tab_menu_item_shortcut returns the keybinding hint for an item.
tab_menu_item_shortcut :: proc(item: Tab_Menu_Item) -> string {
	switch item {
	case .Close:          return "\u2318D"
	case .New_Tab:        return "\u2318T"
	case .Close_Others:   return "\u2325\u2318D"
	case .Close_To_Right: return "\u2325\u21E7\u2318D"
	case .Rename:         return "\u2318R"
	}
	return ""
}

// Tab_Rename_Action reports the discrete outcome of inline tab rename editing.
Tab_Rename_Action :: enum u8 {
	None = 0,
	Commit,
	Cancel,
	Changed,
}

// Tab_Rename_State owns the double-click inline rename buffer for one tab.
Tab_Rename_State :: struct {
	active:  bool,
	tab_idx: int,
	tab_id:  u32,
	buf:     [128]u8,
	len:     int,
	caret:   int,
}

// tab_rename_init initializes the rename buffer to an inactive state.
tab_rename_init :: proc(rs: ^Tab_Rename_State) {
	if rs == nil do return
	rs.active = false
	rs.tab_idx = -1
	rs.tab_id = 0
	rs.len = 0
	rs.caret = 0
}

// tab_rename_begin starts editing a tab seeded with its current display title.
tab_rename_begin :: proc(rs: ^Tab_Rename_State, tab_idx: int, tab_id: u32, initial: string) -> bool {
	if rs == nil || tab_idx < 0 do return false
	n := min(len(initial), len(rs.buf))
	copy(rs.buf[:n], initial[:n])
	rs.len = n
	rs.caret = n
	rs.tab_idx = tab_idx
	rs.tab_id = tab_id
	rs.active = true
	return true
}

// tab_rename_cancel ends the editing session and clears its buffer.
tab_rename_cancel :: proc(rs: ^Tab_Rename_State) {
	if rs == nil do return
	rs.active = false
	rs.len = 0
	rs.caret = 0
	rs.tab_idx = -1
	rs.tab_id = 0
}

// tab_rename_text returns the current edit buffer as a string.
tab_rename_text :: proc(rs: ^Tab_Rename_State) -> string {
	if rs == nil do return ""
	return string(rs.buf[:rs.len])
}

// tab_rename_dispatch_key applies one key to the rename buffer.
tab_rename_dispatch_key :: proc(rs: ^Tab_Rename_State, ev: input.Input_Event) -> (consumed: bool, action: Tab_Rename_Action) {
	if rs == nil || !rs.active do return false, .None
	if ev.is_release do return true, .None

	switch ev.kind {
	case .Enter:
		return true, .Commit
	case .Escape:
		return true, .Cancel
	case .Backspace:
		if rs.len > 0 {
			rs.len = _tab_rename_trim_runr(rs.buf[:], rs.len)
			rs.caret = rs.len
			return true, .Changed
		}
		return true, .None
	case .Printable:
		if ev.rune >= 32 && ev.rune != 127 {
			buf: [4]u8
			bn := _tab_rename_encode_rune(ev.rune, buf[:])
			if bn > 0 && rs.len + bn <= len(rs.buf) {
				copy(rs.buf[rs.len:], buf[:bn])
				rs.len += bn
				rs.caret = rs.len
				return true, .Changed
			}
		}
		return true, .None
	case .Arrow_Up, .Arrow_Down, .Arrow_Left, .Arrow_Right, .Delete, .Home, .End, .Tab, .PgUp, .PgDn, .Ctrl, .Alt_Mod:
		return true, .None
	case:
		return true, .None
	}
}

// tab_rename_dispatch_pointer commits when a click lands outside the editing tab rect.
tab_rename_dispatch_pointer :: proc(
	rs: ^Tab_Rename_State,
	px, py: f32,
	is_click: bool,
	title_rect: Rect_f32,
) -> (consumed: bool, action: Tab_Rename_Action) {
	if rs == nil || !rs.active do return false, .None
	if is_click && !point_in_rect(px, py, title_rect) {
		return true, .Commit
	}
	return true, .None
}

_tab_rename_encode_rune :: proc(r: rune, dst: []u8) -> int {
	if r < 0 || r > 0x10FFFF do return 0
	switch {
	case r <= 0x7F:
		if len(dst) < 1 do return 0
		dst[0] = u8(r)
		return 1
	case r <= 0x7FF:
		if len(dst) < 2 do return 0
		dst[0] = u8(0xC0 | (r >> 6))
		dst[1] = u8(0x80 | (r & 0x3F))
		return 2
	case r <= 0xFFFF:
		if len(dst) < 3 do return 0
		dst[0] = u8(0xE0 | (r >> 12))
		dst[1] = u8(0x80 | ((r >> 6) & 0x3F))
		dst[2] = u8(0x80 | (r & 0x3F))
		return 3
	case:
		if len(dst) < 4 do return 0
		dst[0] = u8(0xF0 | (r >> 18))
		dst[1] = u8(0x80 | ((r >> 12) & 0x3F))
		dst[2] = u8(0x80 | ((r >> 6) & 0x3F))
		dst[3] = u8(0x80 | (r & 0x3F))
		return 4
	}
}

_tab_rename_trim_runr :: proc(buf: []u8, len: int) -> int {
	if len <= 0 do return 0
	i := len - 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}
