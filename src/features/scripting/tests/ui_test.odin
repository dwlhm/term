package feature_scripting_tests

import "core:c"
import "core:testing"
import lua "../../../platform/lua"
import scripting ".."

@test
test_ui_module_osc_surface_builders_and_parser :: proc(t: ^testing.T) {
	vm := scripting.script_vm_create()
	testing.expect(t, vm != nil, "failed to create script VM")
	defer scripting.script_vm_destroy(vm)

	script := `
		local term = require "term"
		local ui = require "term.ui"
		assert(term.ui ~= nil, "term.ui should be attached to term")
		assert(type(ui.split) == "function", "require('term.ui') should provide split")

		assert(ui.probe() == "\x1b]8400;?\x1b\\")
		assert(ui.reset() == "\x1b]8400;0\x1b\\")
		assert(ui.target(0) == "\x1b]8400;1;0\x07")
		assert(ui.target(2, "hello") == "\x1b]8400;1;2\x07hello")

		local sp = ui.split { id = 1, parent = 0, dir = "right", ratio = 40, focus = true }
		assert(sp == "\x1b]8400;2;1;0;0;40;1\x1b\\", "unexpected split: " .. sp)

		local pop = ui.popup {
			id = 5, w = 32, h = 10, anchor = "center",
			x = 0, y = 0, z = 20, chrome = "modal", focus = true, title = "Find"
		}
		assert(pop == "\x1b]8400;3;5;32;10;0;0;0;20;2;1;RmluZA==\x1b\\", "unexpected popup: " .. pop)

		assert(ui.focus(1) == "\x1b]8400;4;1\x1b\\")
		assert(ui.show(5) == "\x1b]8400;5;5;1\x1b\\")
		assert(ui.hide(5) == "\x1b]8400;5;5;0\x1b\\")
		assert(ui.close(5) == "\x1b]8400;6;5\x1b\\")

		local ev_probe = ui.parse_event("\x1b]8400;?1\x1b\\")
		assert(ev_probe and ev_probe.kind == "probe" and ev_probe.supported == true)

		local ev_close = ui.parse_event("\x1b]8400;6;5\x1b\\")
		assert(ev_close and ev_close.kind == "close" and ev_close.id == 5)

		local ev_input = ui.parse_event("\x1b]8400;7;2;68656c6c6f\x1b\\")
		assert(ev_input and ev_input.kind == "input" and ev_input.id == 2 and ev_input.data == "hello")

		local ev_foc = ui.parse_event("\x1b]8400;8;5\x1b\\")
		assert(ev_foc and ev_foc.kind == "focus" and ev_foc.id == 5)

		local ev_res = ui.parse_event("\x1b]8400;9;1;40;24\x1b\\")
		assert(ev_res and ev_res.kind == "resize" and ev_res.id == 1 and ev_res.cols == 40 and ev_res.rows == 24)

		assert(ui.parse_event("plain text") == nil)

		local io_mod = require "term.io"
		assert(type(io_mod.raw_mode) == "function", "io.raw_mode should exist")
		assert(type(io_mod.read_raw) == "function", "io.read_raw should exist")
		-- Non-blocking poll on stdin with 0ms timeout returns string or nil without hanging
		local chunk = io_mod.read_raw(0)
		assert(chunk == nil or type(chunk) == "string")
	`

	if lua.luaL_loadbufferx(vm.L, raw_data(script), c.size_t(len(script)), "test_ui", "t") != lua.OK {
		testing.expectf(t, false, "syntax error: %s", lua.tostring(vm.L, -1))
		return
	}

	if lua.pcall(vm.L, 0, 0, 0) != lua.OK {
		testing.expectf(t, false, "runtime error: %s", lua.tostring(vm.L, -1))
		return
	}
}
