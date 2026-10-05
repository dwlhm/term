package platform_tabs

import "core:fmt"
import "core:unicode/utf8"

// Rect_f32 defines a 2D floating-point rectangle.
Rect_f32 :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

// point_in_rect performs a half-open bounding box check for (x, y) within r.
point_in_rect :: #force_inline proc(x, y: f32, r: Rect_f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// Tab_Hit_Target designates interactive regions within the tab bar.
Tab_Hit_Target :: enum u8 {
	None = 0,
	Tab_Item,
	Btn_Close,
	Btn_New_Tab,
	Btn_Overflow,
	Btn_Detached,
}

TAB_BAR_HEIGHT:          f32 : 28.0
UI_CHROME_CELL_WIDTH:    f32 : 8.0
TAB_GAP:                 f32 : 16.0
TRAFFIC_LIGHT_OFFSET_DARWIN: f32 : 76.0
NEW_TAB_BTN_WIDTH:       f32 : 28.0
CLOSE_BTN_WIDTH:         f32 : 22.0
TAB_CLOSE_MIN_WIDTH:     f32 : 2 * CLOSE_BTN_WIDTH
TAB_SCROLL_WHEEL_STEP:   f32 : 60.0
TAB_TITLE_PAD_LEFT:      f32 : 10.0
TAB_BAR_MIN_DRAG_W:      f32 : 100.0

TAB_BAR_ANIM_CAP       :: 32
TAB_BAR_ANIM_EPS:       f32 = 0.002
TAB_BAR_ANIM_DT_MAX_MS: f32 = 50.0

// Tab_Bar_Anim tracks per-slot interaction transition progress for tab chrome.
Tab_Bar_Anim :: struct {
	hover_t:     [TAB_BAR_ANIM_CAP]f32,
	active_t:    [TAB_BAR_ANIM_CAP]f32,
	close_t:     [TAB_BAR_ANIM_CAP]f32,
	new_tab_t:   f32,
	anim_active: bool,
}

// Tab_Bar_State manages visual layout bounds and pointer hover feedback for tabs.
Tab_Bar_State :: struct {
	rect:                    Rect_f32,
	new_tab_rect:            Rect_f32,
	overflow_rect:           Rect_f32,
	overflow_indicator_rect: Rect_f32,
	detached_badge_rect:     Rect_f32,
	hover_overflow:          bool,
	hover_detached:          bool,
	hover_target:            Tab_Hit_Target,
	hover_tab_idx:           int,
	hover_close_idx:         int,
	hover_new_tab:           bool,
	viewport_rect:           Rect_f32,
	title_rect:              Rect_f32,
	drag_rect:               Rect_f32,
	scroll_offset:           f32,
	scroll_max:              f32,
	content_w:               f32,
	tab_w:                   f32,
	avail_w:                 f32,
	left_offset:             f32,
	max_title_len:           int,
	display_start:           int,
	visible_tab_count:       int,
	overflow_count:          int,
	detached_count:          int,
	target_scroll_idx:       int,
	anim:                    Tab_Bar_Anim,
}

// Tab_Action represents the discrete user action triggered by pointer interaction.
Tab_Action :: enum u8 {
	None = 0,
	Switch_Tab,
	Close_Tab,
	New_Tab,
	Context_Menu,
	Show_Overflow,
	Window_Zoom,
	Open_Session_Switcher,
}

// tabs_init initializes the tab bar state to clean defaults.
tabs_init :: proc(state: ^Tab_Bar_State) {
	if state == nil do return
	state.rect = Rect_f32{}
	state.new_tab_rect = Rect_f32{}
	state.overflow_rect = Rect_f32{}
	state.overflow_indicator_rect = Rect_f32{}
	state.detached_badge_rect = Rect_f32{}
	state.hover_overflow = false
	state.hover_detached = false
	state.hover_target = .None
	state.hover_tab_idx = -1
	state.hover_close_idx = -1
	state.hover_new_tab = false
	state.viewport_rect = Rect_f32{}
	state.title_rect = Rect_f32{}
	state.drag_rect = Rect_f32{}
	state.scroll_offset = 0
	state.scroll_max = 0
	state.content_w = 0
	state.tab_w = 0
	state.avail_w = 0
	state.left_offset = 0
	state.max_title_len = 16
	state.display_start = 0
	state.visible_tab_count = 0
	state.overflow_count = 0
	state.detached_count = 0
	state.target_scroll_idx = -1
	state.anim = Tab_Bar_Anim{}
}

tab_bar_init :: tabs_init

// tab_bar_anim_activate arms the tab bar animation so the next update ticks transitions.
tab_bar_anim_activate :: proc(state: ^Tab_Bar_State) {
	if state == nil do return
	state.anim.anim_active = true
}

// _approach moves cur toward target by step without ever overshooting.
_approach :: proc(cur, target, step: f32) -> f32 {
	if step <= 0 do return cur
	if cur < target do return min(cur + step, target)
	if cur > target do return max(cur - step, target)
	return cur
}

// _ease_out_cubic applies a cubic ease-out curve to normalized t.
_ease_out_cubic :: proc(t: f32) -> f32 {
	u := clamp(t, 0, 1)
	return 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u)
}

// _lerp4 linearly interpolates every component of color a toward b by t.
_lerp4 :: proc(a, b: [4]f32, t: f32) -> [4]f32 {
	u := clamp(t, 0, 1)
	return {
		a.r + (b.r - a.r) * u,
		a.g + (b.g - a.g) * u,
		a.b + (b.b - a.b) * u,
		a.a + (b.a - a.a) * u,
	}
}

_rune_count :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}

// tabs_anim_update advances per-slot interaction transitions toward their targets.
// It returns true while any channel is still moving so the caller can schedule a repaint.
// Durations are supplied by the caller to keep this proc free of app/theme state.
tabs_anim_update :: proc(
	state: ^Tab_Bar_State,
	active_idx: int,
	dt_ms: f32,
	hover_ms, active_ms: f32,
) -> bool {
	if state == nil do return false
	if !state.anim.anim_active do return false

	dt := clamp(dt_ms, 0, TAB_BAR_ANIM_DT_MAX_MS)
	hover_step: f32 = 0
	active_step: f32 = 0
	if hover_ms > 0 do hover_step = dt / hover_ms
	if active_ms > 0 do active_step = dt / active_ms

	moving := false
	for i in 0 ..< TAB_BAR_ANIM_CAP {
		hover_target := f32(1) if i == state.hover_tab_idx else f32(0)
		active_target := f32(1) if i == active_idx else f32(0)
		close_target := f32(1) if i == state.hover_close_idx else f32(0)

		state.anim.hover_t[i] = _approach(state.anim.hover_t[i], hover_target, hover_step)
		state.anim.active_t[i] = _approach(state.anim.active_t[i], active_target, active_step)
		state.anim.close_t[i] = _approach(state.anim.close_t[i], close_target, hover_step)

		if abs(state.anim.hover_t[i] - hover_target) > TAB_BAR_ANIM_EPS do moving = true
		if abs(state.anim.active_t[i] - active_target) > TAB_BAR_ANIM_EPS do moving = true
		if abs(state.anim.close_t[i] - close_target) > TAB_BAR_ANIM_EPS do moving = true
	}

	new_tab_target := f32(1) if state.hover_new_tab else f32(0)
	state.anim.new_tab_t = _approach(state.anim.new_tab_t, new_tab_target, hover_step)
	if abs(state.anim.new_tab_t - new_tab_target) > TAB_BAR_ANIM_EPS do moving = true

	if !moving {
		for i in 0 ..< TAB_BAR_ANIM_CAP {
			state.anim.hover_t[i] = f32(1) if i == state.hover_tab_idx else f32(0)
			state.anim.active_t[i] = f32(1) if i == active_idx else f32(0)
			state.anim.close_t[i] = f32(1) if i == state.hover_close_idx else f32(0)
		}
		state.anim.new_tab_t = new_tab_target
		state.anim.anim_active = false
		return false
	}

	return true
}

tab_bar_anim_update :: tabs_anim_update

// tabs_layout calculates content-driven tab widths, fits tabs starting from display_start,
// ensures active tab visibility, and positions overflow and new tab controls.
tabs_layout :: proc(
	state: ^Tab_Bar_State,
	window_w: f32,
	tab_count: int,
	out_rects: []Rect_f32,
	active_idx: int = -1,
	titles: []string = nil,
) -> int {
	if state == nil do return 0
	width := max(0, window_w)
	count := clamp(tab_count, 0, len(out_rects))

	for i in 0 ..< len(out_rects) {
		out_rects[i] = Rect_f32{}
	}

	if width <= 0 {
		state.rect = Rect_f32{}
		state.new_tab_rect = Rect_f32{}
		state.overflow_rect = Rect_f32{}
		state.overflow_indicator_rect = Rect_f32{}
		state.detached_badge_rect = Rect_f32{}
		state.viewport_rect = Rect_f32{}
		state.title_rect = Rect_f32{}
		state.drag_rect = Rect_f32{}
		state.avail_w = 0
		state.left_offset = 0
		state.visible_tab_count = 0
		state.overflow_count = count
		state.scroll_max = 0
		state.scroll_offset = 0
		return 0
	}

	traffic_light_offset: f32 = 0
	when ODIN_OS == .Darwin {
		traffic_light_offset = min(TRAFFIC_LIGHT_OFFSET_DARWIN, max(0, width - NEW_TAB_BTN_WIDTH))
	}

	max_title_len := state.max_title_len if state.max_title_len > 0 else 16
	state.max_title_len = max_title_len

	cw := UI_CHROME_CELL_WIDTH
	tab_widths: [TAB_BAR_ANIM_CAP]f32
	content_w: f32 = 0
	for i in 0 ..< count {
		prefix_len := 4 if (i + 1) < 10 else 5
		title_runes := 0
		if titles != nil && i < len(titles) && len(titles[i]) > 0 {
			title_runes = min(_rune_count(titles[i]), max_title_len)
		} else {
			title_runes = min(8, max_title_len)
		}
		w := f32(prefix_len + title_runes) * cw + TAB_GAP
		tab_widths[i] = w
		content_w += w
	}
	state.content_w = content_w
	state.tab_w = tab_widths[0] if count > 0 else cw * 12 + TAB_GAP

	button_w := NEW_TAB_BTN_WIDTH
	min_drag_w := TAB_BAR_MIN_DRAG_W
	badge_w: f32 = 0
	if state.detached_count > 0 {
		buf: [32]u8
		label := fmt.bprintf(buf[:], "○ %d background", state.detached_count)
		badge_w = min(f32(_rune_count(label)) * cw + 12, max(0, width - traffic_light_offset - button_w))
	}
	// The detached badge is pinned to the far right; the tab strip still starts
	// at the traffic-light offset, and the badge width stays reserved so the tab
	// fit budget never grows into the badge's corner.
	left_offset := traffic_light_offset
	base_reserved := left_offset + button_w + min_drag_w + badge_w

	fit_tabs :: proc(widths: []f32, start_idx, total_count: int, max_w: f32) -> int {
		if total_count <= 0 || start_idx >= total_count || max_w <= 0 do return 0
		fitted := 0
		used: f32 = 0
		for i := start_idx; i < total_count; i += 1 {
			w := widths[i]
			if used + w > max_w && fitted > 0 {
				break
			}
			if fitted == 0 && w > max_w {
				used += w
				fitted += 1
				break
			}
			used += w
			fitted += 1
		}
		return fitted
	}

	all_fit := count > 0 && fit_tabs(tab_widths[:count], 0, count, max(0, width - base_reserved)) == count
	ov_reserve: f32 = 0
	if !all_fit && count > 0 {
		ov_reserve = 36.0
	}

	avail_w := max(0, width - base_reserved - ov_reserve)

	ensure_idx := active_idx
	if ensure_idx < 0 && state.target_scroll_idx >= 0 {
		ensure_idx = state.target_scroll_idx
		state.target_scroll_idx = -1
	}
	if ensure_idx >= 0 && count > 0 {
		act_idx := clamp(ensure_idx, 0, count - 1)
		vis_count := fit_tabs(tab_widths[:count], state.display_start, count, avail_w)
		if act_idx < state.display_start {
			state.display_start = act_idx
		} else if act_idx >= state.display_start + vis_count {
			state.display_start = max(0, act_idx - max(1, vis_count) + 1)
			vis_count = fit_tabs(tab_widths[:count], state.display_start, count, avail_w)
			for act_idx >= state.display_start + vis_count && state.display_start < act_idx {
				state.display_start += 1
				vis_count = fit_tabs(tab_widths[:count], state.display_start, count, avail_w)
			}
		}
	}

	max_display_start := 0
	if count > 0 && avail_w > 0 {
		used: f32 = 0
		max_display_start = count - 1
		for i := count - 1; i >= 0; i -= 1 {
			w := tab_widths[i]
			if used + w > avail_w && used > 0 {
				break
			}
			used += w
			max_display_start = i
		}
	}
	state.display_start = clamp(state.display_start, 0, max_display_start)
	vis_count := fit_tabs(tab_widths[:count], state.display_start, count, avail_w)

	state.visible_tab_count = vis_count
	overflow_cnt := count - vis_count
	if overflow_cnt < 0 do overflow_cnt = 0
	state.overflow_count = overflow_cnt

	cur_x := left_offset
	// The badge owns the right corner, opposite the left-anchored tab strip.
	if state.detached_count > 0 {
		state.detached_badge_rect = Rect_f32{x = max(0, width - badge_w), y = 0, w = badge_w, h = TAB_BAR_HEIGHT}
	} else {
		state.detached_badge_rect = Rect_f32{}
	}
	for k in 0 ..< vis_count {
		idx := state.display_start + k
		if idx < count {
			w := tab_widths[idx]
			out_rects[idx] = Rect_f32{x = cur_x, y = 0, w = w, h = TAB_BAR_HEIGHT}
			cur_x += w
		}
	}

	if state.overflow_count > 0 {
		buf: [16]u8
		str := fmt.bprintf(buf[:], "+%d", state.overflow_count)
		ov_w := f32(_rune_count(str)) * cw + 12.0
		ov_w = min(ov_w, max(0, width - cur_x))
		state.overflow_indicator_rect = Rect_f32{x = cur_x, y = 0, w = ov_w, h = TAB_BAR_HEIGHT}
		state.overflow_rect = state.overflow_indicator_rect
		cur_x += ov_w
	} else {
		state.overflow_indicator_rect = Rect_f32{}
		state.overflow_rect = Rect_f32{}
	}

	btn_w := min(button_w, max(0, width - cur_x))
	state.new_tab_rect = Rect_f32{x = cur_x, y = 0, w = btn_w, h = TAB_BAR_HEIGHT}
	cur_x += btn_w

	// The drag surface stops where the badge begins so the right corner is
	// claimed by exactly one hit target.
	drag_end := width
	if state.detached_badge_rect.w > 0 {
		drag_end = min(drag_end, state.detached_badge_rect.x)
	}
	remaining_w := max(0, drag_end - cur_x)
	state.drag_rect = Rect_f32{x = cur_x, y = 0, w = remaining_w, h = TAB_BAR_HEIGHT}
	state.title_rect = state.drag_rect
	state.rect = Rect_f32{w = width, h = TAB_BAR_HEIGHT}
	state.viewport_rect = Rect_f32{x = left_offset, y = 0, w = max(0, cur_x - left_offset), h = TAB_BAR_HEIGHT}
	state.avail_w = avail_w
	state.left_offset = left_offset

	state.scroll_max = max(0, content_w - avail_w)
	if state.tab_w > 0 {
		state.scroll_offset = min(state.scroll_offset, f32(state.display_start) * state.tab_w)
	}
	state.scroll_offset = clamp(state.scroll_offset, 0, state.scroll_max)

	return count
}

tab_bar_layout :: tabs_layout

// tabs_scroll shifts the tab strip by whole wheel steps, clamped to the scroll range.
tabs_scroll :: proc(state: ^Tab_Bar_State, wheel_ticks: int) -> bool {
	if state == nil do return false
	delta := -f32(wheel_ticks) * TAB_SCROLL_WHEEL_STEP
	prev := state.scroll_offset
	state.scroll_offset = clamp(prev + delta, 0, state.scroll_max)
	if state.tab_w > 0 {
		state.display_start = int(state.scroll_offset / state.tab_w)
	}
	return state.scroll_offset != prev
}

tab_bar_scroll :: tabs_scroll

// tab_bar_scroll_to_tab adjusts the scroll offset so tab idx lies fully inside the viewport.
tab_bar_scroll_to_tab :: proc(state: ^Tab_Bar_State, idx: int) -> bool {
	if state == nil || idx < 0 do return false
	prev_start := state.display_start
	prev_offset := state.scroll_offset

	state.target_scroll_idx = idx
	if idx < state.display_start {
		state.display_start = idx
	} else if state.visible_tab_count > 0 && idx >= state.display_start + state.visible_tab_count {
		state.display_start = max(0, idx - state.visible_tab_count + 1)
	} else if state.visible_tab_count == 0 {
		state.display_start = idx
	}

	tab_w := state.tab_w if state.tab_w > 0 else 100.0
	state.scroll_offset = f32(state.display_start) * tab_w
	state.scroll_offset = clamp(state.scroll_offset, 0, state.scroll_max)

	return state.display_start != prev_start || state.scroll_offset != prev_offset || state.target_scroll_idx >= 0
}

// tab_bar_hit_test determines which tab element or button is positioned under (x, y).
tab_bar_hit_test :: proc(state: ^Tab_Bar_State, tab_count: int, tab_rects: []Rect_f32, x, y: f32) -> (target: Tab_Hit_Target, tab_idx: int) {
	if state == nil do return .None, -1

	if (state.overflow_count > 0 && point_in_rect(x, y, state.overflow_indicator_rect)) || (state.overflow_rect.w > 0 && point_in_rect(x, y, state.overflow_rect)) {
		return .Btn_Overflow, -1
	}
	if state.new_tab_rect.w > 0 && point_in_rect(x, y, state.new_tab_rect) {
		return .Btn_New_Tab, -1
	}
	if state.detached_count > 0 && state.detached_badge_rect.w > 0 && point_in_rect(x, y, state.detached_badge_rect) {
		return .Btn_Detached, -1
	}
	if !point_in_rect(x, y, state.viewport_rect) && !point_in_rect(x, y, state.rect) {
		return .None, -1
	}

	count := min(tab_count, len(tab_rects))
	start := state.display_start
	end := min(count, start + state.visible_tab_count)
	if end == 0 && count > 0 do end = count

	for i in start ..< end {
		if i < len(tab_rects) && tab_rects[i].w > 0 && point_in_rect(x, y, tab_rects[i]) {
			return .Tab_Item, i
		}
	}

	for i in 0 ..< count {
		if tab_rects[i].w > 0 && point_in_rect(x, y, tab_rects[i]) {
			return .Tab_Item, i
		}
	}

	return .None, -1
}

// tabs_dispatch_pointer processes pointer movement and clicks over the tab bar chrome.
tabs_dispatch_pointer :: proc(
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

	prev_target := state.hover_target
	prev_tab := state.hover_tab_idx
	prev_close := state.hover_close_idx
	prev_new := state.hover_new_tab
	prev_detached := state.hover_detached

	state.hover_target = target
	state.hover_tab_idx = idx if target == .Tab_Item else -1
	state.hover_close_idx = idx if target == .Btn_Close else -1
	state.hover_new_tab = (target == .Btn_New_Tab)
	state.hover_overflow = (target == .Btn_Overflow)
	state.hover_detached = (target == .Btn_Detached)

	if state.hover_target != prev_target || state.hover_tab_idx != prev_tab || state.hover_close_idx != prev_close || state.hover_new_tab != prev_new || state.hover_detached != prev_detached {
		tab_bar_anim_activate(state)
	}

	in_bar := point_in_rect(px, py, state.rect)
	if !in_bar do return false, .None, -1

	if is_down {
		if button == 3 && target == .Tab_Item {
			return true, .Context_Menu, idx
		}
		if button == 3 {
			return true, .None, -1
		}
		if button == 2 && target == .Tab_Item {
			return true, .Close_Tab, idx
		}
		if clicks == 2 && button == 1 && target == .None && point_in_rect(px, py, state.drag_rect) {
			return true, .Window_Zoom, -1
		}
		if button == 1 {
			switch target {
			case .Tab_Item:
				return true, .Switch_Tab, idx
			case .Btn_Close:
				return true, .Close_Tab, idx
			case .Btn_Overflow:
				return true, .Show_Overflow, -1
			case .Btn_New_Tab:
				return true, .New_Tab, -1
			case .Btn_Detached:
				return true, .Open_Session_Switcher, -1
			case .None:
				return true, .None, -1
			}
		}
	}

	return true, .None, -1
}

tab_bar_dispatch_pointer :: tabs_dispatch_pointer
