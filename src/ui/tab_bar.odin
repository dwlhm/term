package ui

// Tab_Hit_Target designates interactive regions within the tab bar.
Tab_Hit_Target :: enum u8 {
	None = 0,
	Tab_Item,
	Btn_Close,
	Btn_New_Tab,
}

// Tab_Bar_State manages visual layout bounds and pointer hover feedback for tabs.
Tab_Bar_State :: struct {
	rect:            Rect_f32,
	new_tab_rect:    Rect_f32,
	hover_target:    Tab_Hit_Target,
	hover_tab_idx:   int,
	hover_close_idx: int,
	hover_new_tab:   bool,
}

// Tab_Action represents the discrete user action triggered by pointer interaction.
Tab_Action :: enum u8 {
	None = 0,
	Switch_Tab,
	Close_Tab,
	New_Tab,
}

// tab_bar_init initializes the tab bar state to clean defaults.
tab_bar_init :: proc(state: ^Tab_Bar_State) {
	if state == nil do return
	state.rect = Rect_f32{}
	state.hover_target = .None
	state.hover_tab_idx = -1
	state.hover_close_idx = -1
	state.hover_new_tab = false
}

TRAFFIC_LIGHT_OFFSET_DARWIN: f32 : 78.0
NEW_TAB_BTN_WIDTH: f32 : 32.0
CLOSE_BTN_WIDTH: f32 : 24.0
TAB_CLOSE_MIN_WIDTH: f32 : 2 * CLOSE_BTN_WIDTH

// tab_bar_layout reserves the new-tab control and fits tabs into the remaining width.
tab_bar_layout :: proc(state: ^Tab_Bar_State, window_w: f32, tab_count: int, out_rects: []Rect_f32) -> int {
	if state == nil do return 0
	width := max(0, window_w)
	state.rect = Rect_f32{w = width, h = TAB_BAR_HEIGHT}
	left_offset: f32 = 0
	when ODIN_OS == .Darwin {
		left_offset = min(TRAFFIC_LIGHT_OFFSET_DARWIN, max(0, width - NEW_TAB_BTN_WIDTH))
	}
	button_w := min(NEW_TAB_BTN_WIDTH, max(0, width - left_offset))
	avail_w := max(0, width - left_offset - button_w)
	count := max(0, min(tab_count, len(out_rects)))
	tab_w: f32 = 0
	if count > 0 {
		tab_w = min(TAB_MAX_W, avail_w / f32(count))
	}
	for i in 0 ..< count {
		x := left_offset + f32(i) * tab_w
		out_rects[i] = Rect_f32{x = x, w = min(tab_w, max(0, width - button_w - x)), h = TAB_BAR_HEIGHT}
	}
	state.new_tab_rect = Rect_f32{x = left_offset + f32(count) * tab_w, w = button_w, h = TAB_BAR_HEIGHT}
	return count
}

// tab_bar_hit_test determines which tab element or button is positioned under (x, y).
tab_bar_hit_test :: proc(state: ^Tab_Bar_State, tab_count: int, tab_rects: []Rect_f32, x, y: f32) -> (target: Tab_Hit_Target, tab_idx: int) {
	if state == nil do return .None, -1
	if !point_in_rect(x, y, state.rect) {
		return .None, -1
	}

	count := min(tab_count, len(tab_rects))

	for i in 0 ..< count {
		r := tab_rects[i]
		if point_in_rect(x, y, r) {
			close_rect := Rect_f32{
				x = r.x + r.w - CLOSE_BTN_WIDTH,
				y = r.y,
				w = CLOSE_BTN_WIDTH,
				h = r.h,
			}
			if r.w >= TAB_CLOSE_MIN_WIDTH && point_in_rect(x, y, close_rect) {
				return .Btn_Close, i
			}
			return .Tab_Item, i
		}
	}

	if point_in_rect(x, y, state.new_tab_rect) {
		return .Btn_New_Tab, -1
	}

	return .None, -1
}

// tab_bar_dispatch_pointer processes pointer movement and clicks over the tab bar chrome.
tab_bar_dispatch_pointer :: proc(
	state: ^Tab_Bar_State,
	tab_count: int,
	tab_rects: []Rect_f32,
	px, py: f32,
	is_down: bool,
	button: u8 = 1,
	clicks: u8 = 1,
) -> (consumed: bool, action: Tab_Action, target_idx: int) {
	if state == nil do return false, .None, -1
	target, idx := tab_bar_hit_test(state, tab_count, tab_rects, px, py)

	state.hover_target = target
	state.hover_tab_idx = idx if target == .Tab_Item else -1
	state.hover_close_idx = idx if target == .Btn_Close else -1
	state.hover_new_tab = (target == .Btn_New_Tab)

	in_bar := point_in_rect(px, py, state.rect)
	if !in_bar do return false, .None, -1

	if is_down {
		if button == 2 && target == .Tab_Item {
			return true, .Close_Tab, idx
		}
		if clicks == 2 && button == 1 && target == .None {
			return true, .New_Tab, -1
		}
		if button == 1 {
			switch target {
			case .Tab_Item:
				return true, .Switch_Tab, idx
			case .Btn_Close:
				return true, .Close_Tab, idx
			case .Btn_New_Tab:
				return true, .New_Tab, -1
			case .None:
				return true, .None, -1
			}
		}
	}

	return true, .None, -1
}
