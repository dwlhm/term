package app_test

import "core:testing"
import app "../"
import input "../../platform/input"
import instance "../../render/instance"
import render "../../render"
import win "../../platform/window"

_fx_count :: proc(s: ^app.Drop_Fx_State) -> int {
	n := 0
	for w in s.splashes { if w.active { n += 1 } }
	return n
}

@test
test_drop_fx_fixed_origins_and_resampling :: proc(t: ^testing.T) {
	a, b: app.Drop_Fx_State
	app.drop_fx_handle(&a, {kind = .Begin, x = 100, y = 100})
	app.drop_fx_handle(&b, {kind = .Begin, x = 100, y = 100})
	app.drop_fx_handle(&a, {kind = .Position, x = 150, y = 100})
	for x in ([5]f32{109, 120, 132, 145, 150}) {
		app.drop_fx_handle(&b, {kind = .Position, x = x, y = 100})
	}
	testing.expect_value(t, _fx_count(&a), 3)
	testing.expect_value(t, a.splashes[0].x, f32(100))
	testing.expect_value(t, a.splashes[1].x, f32(122))
	testing.expect_value(t, a.splashes[2].x, f32(144))
	for w, i in a.splashes { testing.expect_value(t, w.x, b.splashes[i].x) }
	testing.expect_value(t, a.path_remainder, f64(6))
	testing.expect_value(t, a.path_remainder, b.path_remainder)
	app.drop_fx_handle(&a, {kind = .Position, x = 150, y = 100})
	testing.expect_value(t, _fx_count(&a), 3)
	app.drop_fx_handle(&a, {kind = .Position, x = 166, y = 100})
	testing.expect_value(t, a.splashes[3].x, f32(166))
	testing.expect_value(t, a.splashes[0].x, f32(100))
}

@test
test_drop_fx_saturation_retains_latest_samples :: proc(t: ^testing.T) {
	s: app.Drop_Fx_State
	app.drop_fx_handle(&s, {kind = .Begin})
	endpoint := f32(app.DROP_WAKE_SPACING * 1000)
	app.drop_fx_handle(&s, {kind = .Position, x = endpoint})
	testing.expect_value(t, _fx_count(&s), instance.WATER_MAX_WAVES)
	for j in 0..<instance.WATER_MAX_WAVES {
		expected := endpoint - f32(j) * f32(app.DROP_WAKE_SPACING)
		found := false
		for w in s.splashes { found = found || w.x == expected }
		testing.expect(t, found, "latest equally-aged samples must all survive saturation")
	}
	// A short-lived older wave must be replaced before younger normalized ages.
	s.splashes[7].time = s.splashes[7].max_t * 0.9
	app.drop_fx_handle(&s, {kind = .Position, x = endpoint + f32(app.DROP_WAKE_SPACING)})
	testing.expect_value(t, s.splashes[7].x, endpoint + f32(app.DROP_WAKE_SPACING))
}

@test
test_drop_fx_invalid_recovery_payload_latch_and_settle :: proc(t: ^testing.T) {
	s: app.Drop_Fx_State
	app.drop_fx_handle(&s, {kind = .Begin, x = 50})
	bad := transmute(f32)u32(0x7fc00000)
	app.drop_fx_handle(&s, {kind = .Position, x = bad})
	testing.expect(t, !s.anchor_valid)
	app.drop_fx_handle(&s, {kind = .Position, x = 500})
	testing.expect_value(t, _fx_count(&s), 2)
	testing.expect_value(t, s.splashes[1].x, f32(500))
	app.drop_fx_handle(&s, {kind = .File, x = 510})
	app.drop_fx_handle(&s, {kind = .Text, x = 510})
	testing.expect_value(t, _fx_count(&s), 3)
	testing.expect(t, !s.hovering && s.impact_emitted)
	app.drop_fx_handle(&s, {kind = .Complete, x = bad})
	testing.expect(t, !s.impact_emitted && !s.hovering && app.drop_fx_active(&s))
	active, changed := app.drop_fx_tick(&s, app.DROP_IMPACT_LIFETIME)
	testing.expect(t, !active && changed, "expiry requests exactly one clean frame")
	active, changed = app.drop_fx_tick(&s, 0.1)
	testing.expect(t, !active && !changed, "settled surface idles")
	app.drop_fx_handle(&s, {kind = .File, x = 77})
	testing.expect_value(t, _fx_count(&s), 1)
	active, changed = app.drop_fx_tick(&s, bad)
	testing.expect(t, active && !changed)
}

@test
test_drop_fx_modal_and_normal_share_emitter :: proc(t: ^testing.T) {
	a := new(app.App)
	b := new(app.App)
	defer free(a)
	defer free(b)
	b.confirm_dialog.visible = true
	events := []input.Input_Event{
		{event_type = .Drop, drop = {kind = .Begin, x = 80, y = 90}},
		{event_type = .Drop, drop = {kind = .Position, x = 124, y = 90}},
		{event_type = .Drop, drop = {kind = .File, x = 124, y = 90}},
		{event_type = .Drop, drop = {kind = .Text, x = 124, y = 90}},
		{event_type = .Drop, drop = {kind = .Complete}},
	}
	_, _ = app.app_dispatch_input_events(a, events)
	_, _ = app.app_dispatch_input_events(b, events)
	testing.expect_value(t, _fx_count(&a.drop_fx), 4)
	testing.expect_value(t, _fx_count(&a.drop_fx), _fx_count(&b.drop_fx))
	for w, i in a.drop_fx.splashes {
		testing.expect_value(t, w.x, b.drop_fx.splashes[i].x)
		testing.expect_value(t, w.strength, b.drop_fx.splashes[i].strength)
	}
}

@test
test_drop_fx_real_ui_stage_keeps_logical_origins :: proc(t: ^testing.T) {
	_dummy_video()
	a := new(app.App)
	defer free(a)
	if !_dummy_window(t, &a.window, "water staging", 400, 300) {
		testing.expect(t, false, "dummy window required for production staging")
		return
	}
	defer win.window_destroy(&a.window)
	a.window.width = 400
	a.window.pixel_w = 800
	a.renderer.screen_w = 800
	a.renderer.screen_h = 600
	app.drop_fx_handle(&a.drop_fx, {kind = .Begin, x = 100, y = 150})
	app.drop_fx_handle(&a.drop_fx, {kind = .Position, x = 144, y = 150})
	app._app_stage_ui(a)
	testing.expect_value(t, a.renderer.instances.uniform_data.water_meta[0], f32(3))
	testing.expect_value(t, a.renderer.instances.uniform_data.water_meta[1], f32(2))
	testing.expect_value(t, a.renderer.instances.uniform_data.waves[0].origin_age_strength[0], f32(100))
	count := 0
	overlay := render.UI_Layer.Overlay
	for quad in a.renderer.ui_bg_data[overlay][:a.renderer.ui_layer_bg_count[overlay]] {
		if quad.v1 == -3 { count += 1 }
	}
	testing.expect_value(t, count, 1)
}
