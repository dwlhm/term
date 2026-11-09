package feature_scripting_tests

import "core:c"
import "core:testing"
import lua "../../../platform/lua"
import scripting ".."

@test
test_window_module_loading_and_fallback :: proc(t: ^testing.T) {
	vm := scripting.script_vm_create()
	testing.expect(t, vm != nil, "failed to create script VM")
	defer scripting.script_vm_destroy(vm)

	script := `
		local term = require "term"
		local w = require "term.window"
		assert(term.window ~= nil, "term.window should be present on term")
		assert(type(term.window.split) == "function", "split function should exist")
		assert(type(term.window.tab) == "function", "tab function should exist")
		assert(type(term.window.show) == "function", "show function should exist")
		assert(type(term.window.attach) == "function", "attach function should exist")

		-- In headless test environment, calls should return (false, err_string) safely
		local ok, err = w.show()
		assert(ok == false, "show should fail gracefully when no gui is running")
		assert(type(err) == "string", "error reason should be returned")

		local ok_split, err_split = w.split { direction = "right" }
		assert(ok_split == false, "split should fail gracefully when no gui is running")
		assert(type(err_split) == "string", "error reason should be returned")

		local ok_tab, err_tab = w.tab()
		assert(ok_tab == false, "tab should fail gracefully when no gui is running")
		assert(type(err_tab) == "string", "error reason should be returned")
	`

	if lua.luaL_loadbufferx(vm.L, raw_data(script), c.size_t(len(script)), "test_window", "t") != lua.OK {
		testing.expectf(t, false, "syntax error: %s", lua.tostring(vm.L, -1))
		return
	}

	if lua.pcall(vm.L, 0, 0, 0) != lua.OK {
		testing.expectf(t, false, "runtime error: %s", lua.tostring(vm.L, -1))
		return
	}
}
