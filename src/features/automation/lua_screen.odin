package feature_automation

// A screen in Lua: an immutable userdata over one snapshot. Fields: cols,
// rows, gen, cursor {row, col, visible}, alt, title, process, prompt (OSC 133
// state), status {state, app, kind, msg}. Methods: line(n), lines(), cell(row,
// col) (raw attributes), history(), elements() (marked, then inferred). Rows
// and columns are 1-based. `require "term.screen"` gives load(path) for
// snapshots saved by `term auto snapshot --save`.

import "base:runtime"
import "core:c"
import "core:mem/virtual"
import "core:strings"
import lua "../../platform/lua"
import ipc "../../platform/ipc"

@(private = "file")
SCREEN_MT_KEY :: "term.screen"

// Screen_Ref: what the userdata holds; everything lives in its arena.
@(private = "file")
Screen_Ref :: struct {
	arena:    virtual.Arena,
	screen:   Screen,
	elements: []Element,
	ready:    bool, // elements found (lazily)
}

// lua_push_screen pushes a screen for snap; data is copied into the screen's
// own arena only when owned is false.
lua_push_screen :: proc(L: ^lua.State, snap: ipc.Snapshot, data: []u8 = nil) -> bool {
	ref := (^Screen_Ref)(lua.newuserdatauv(L, size_of(Screen_Ref), 0))
	ref^ = {}
	if virtual.arena_init_growing(&ref.arena) != nil do return false
	a := virtual.arena_allocator(&ref.arena)
	snap := snap
	if data != nil {
		parsed, ok := snapshot_parse(data, a)
		if !ok do return false
		snap = parsed
	}
	ref.screen = screen_build(snap, a)
	_push_screen_mt(L)
	lua.setmetatable(L, -2)
	return true
}

// screen_module_open pushes the `term.screen` module.
screen_module_open :: proc "c" (L: ^lua.State) -> c.int {
	lua.createtable(L, 0, 1)
	lua.pushcfunction(L, _screen_load)
	lua.setfield(L, -2, "load")
	return 1
}

@(private = "file")
_screen_load :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path := lua.tostring(L, 1)
	if !strings.has_suffix(path, ".json") do return _fail(L, "term.screen.load reads a snapshot saved with term auto snapshot --save (.json)")
	data, err := os_read(path)
	if err do return _fail(L, "term.screen.load: cannot read that snapshot")
	defer delete(data)
	if !lua_push_screen(L, {}, data) do return _fail(L, "term.screen.load: not a snapshot")
	return 1
}

@(private = "file")
_push_screen_mt :: proc "c" (L: ^lua.State) {
	if lua.getfield(L, lua.REGISTRYINDEX, SCREEN_MT_KEY) == .Table do return
	lua.pop(L, 1)
	lua.createtable(L, 0, 3)
	lua.pushcfunction(L, _screen_index)
	lua.setfield(L, -2, "__index")
	lua.pushcfunction(L, _screen_gc)
	lua.setfield(L, -2, "__gc")
	lua.pushcfunction(L, _screen_newindex)
	lua.setfield(L, -2, "__newindex")
	lua.pushvalue(L, -1)
	lua.setfield(L, lua.REGISTRYINDEX, SCREEN_MT_KEY)
}

@(private = "file")
_screen_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	ref := (^Screen_Ref)(lua.touserdata(L, 1))
	if ref != nil do virtual.arena_destroy(&ref.arena)
	return 0
}

@(private = "file")
_screen_newindex :: proc "c" (L: ^lua.State) -> c.int {
	return _fail(L, "a screen is read-only")
}

// screen_ref_of: the screen at idx, or nil when it is not one.
screen_ref_of :: proc "c" (L: ^lua.State, idx: c.int) -> ^Screen {
	if lua.getmetatable(L, idx) == 0 do return nil
	_push_screen_mt(L)
	same := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	if !same do return nil
	return &(^Screen_Ref)(lua.touserdata(L, idx)).screen
}

// screen_elements_of: the screen's elements, found once.
screen_elements_of :: proc(L: ^lua.State, idx: c.int) -> []Element {
	ref := (^Screen_Ref)(lua.touserdata(L, idx))
	if !ref.ready {
		ref.elements = screen_elements(&ref.screen, virtual.arena_allocator(&ref.arena))
		ref.ready = true
	}
	return ref.elements
}

@(private = "file")
_screen_index :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := screen_ref_of(L, 1)
	if s == nil do return _fail(L, "not a screen")
	key := lua.tostring(L, 2)
	if push_screen_field(L, s, key) do return 1
	if fn := screen_method(key); fn != nil {
		lua.pushcfunction(L, fn)
		return 1
	}
	lua.pushnil(L)
	return 1
}

_fail :: proc "c" (L: ^lua.State, msg: string) -> c.int {
	lua.pushstring(L, msg)
	return lua.error(L)
}
