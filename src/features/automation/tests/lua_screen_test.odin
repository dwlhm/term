package feature_automation_tests

// A screen as Lua sees it: fields, lines, raw cells and elements, read-only,
// loaded from a saved snapshot the way adapter tests do it.

import "core:strings"
import "core:testing"
import auto ".."

@test
test_lua_screen_from_saved_snapshot :: proc(t: ^testing.T) {
	vm, _ := auto.vm_open()
	defer auto.vm_close(vm)
	src := strings.concatenate({`
local screen = require "term.screen"
local s = screen.load("`, #directory, `testdata/gum_choose.json")
assert(s.cols == 100 and s.rows == 30, "size")
assert(s:line(2) == "> apple", "line: " .. s:line(2))
assert(#s:lines() == 30 and s:lines()[3] == "  banana")
local c = s:cell(2, 1)
assert(c.char == ">" and c.fg == 212 and not c.bold, "raw cell")
assert(s:cell(99, 1) == nil, "outside the screen")
local es = s:elements()
assert(#es == 4 and es[1].ref == "@e1" and es[1].role == "listitem" and es[1].selected and es[1].name == "apple", "elements")
assert(es[1].row == 2 and es[1].col == 1, "1-based")
assert(s.cursor.visible == false and s.prompt == "none" and s.status.state == "clear")
assert(not pcall(function() s.cols = 1 end), "read-only")
assert(not pcall(screen.load, "/etc/passwd"), "only snapshots")
return true`}, context.temp_allocator)
	err, ok := auto.vm_load_chunk(vm, transmute([]u8)src, "screen_test.lua")
	testing.expectf(t, ok, "lua: %s", err)
}
