package platform_lua

// The part of the Lua 5.4 C API `term auto` uses, linked against the vendored
// build (third_party/lua-5.4.9 → build/lua/liblua.a, `make lua`). Odin's
// vendor:lua links a system or prebuilt 5.4.2 library instead.

import "core:c"

foreign import lua "../../../build/lua/liblua.a"

State    :: struct {}
Number   :: f64
Integer  :: i64
CFunction :: #type proc "c" (L: ^State) -> c.int
Alloc    :: #type proc "c" (ud, ptr: rawptr, osize, nsize: c.size_t) -> rawptr
Hook     :: #type proc "c" (L: ^State, ar: rawptr)

OK        :: 0
YIELD     :: 1
ERRRUN    :: 2
ERRSYNTAX :: 3
ERRMEM    :: 4
ERRERR    :: 5

MULTRET :: -1
REGISTRYINDEX :: -1_000_000 - 1000 // -LUAI_MAXSTACK - 1000 (32-bit int build)

Type :: enum c.int {
	None = -1, Nil = 0, Boolean, Light_Userdata, Number, String, Table, Function, Userdata, Thread,
}

MASKCOUNT :: c.int(1 << 3)

@(default_calling_convention = "c", link_prefix = "lua_")
foreign lua {
	newstate     :: proc(f: Alloc, ud: rawptr) -> ^State ---
	close        :: proc(L: ^State) ---
	gettop       :: proc(L: ^State) -> c.int ---
	settop       :: proc(L: ^State, idx: c.int) ---
	absindex     :: proc(L: ^State, idx: c.int) -> c.int ---
	pushvalue    :: proc(L: ^State, idx: c.int) ---
	rotate       :: proc(L: ^State, idx, n: c.int) ---
	type         :: proc(L: ^State, idx: c.int) -> Type ---
	typename     :: proc(L: ^State, tp: Type) -> cstring ---
	tolstring    :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> [^]u8 ---
	tonumberx    :: proc(L: ^State, idx: c.int, isnum: ^c.int) -> Number ---
	tointegerx   :: proc(L: ^State, idx: c.int, isnum: ^c.int) -> Integer ---
	toboolean    :: proc(L: ^State, idx: c.int) -> c.int ---
	isinteger    :: proc(L: ^State, idx: c.int) -> c.int ---
	rawlen       :: proc(L: ^State, idx: c.int) -> c.ulonglong ---
	pushnil      :: proc(L: ^State) ---
	pushnumber   :: proc(L: ^State, n: Number) ---
	pushinteger  :: proc(L: ^State, n: Integer) ---
	pushlstring  :: proc(L: ^State, s: [^]u8, len: c.size_t) -> cstring ---
	pushboolean  :: proc(L: ^State, b: c.int) ---
	pushcclosure :: proc(L: ^State, fn: CFunction, n: c.int) ---
	pushlightuserdata :: proc(L: ^State, p: rawptr) ---
	touserdata   :: proc(L: ^State, idx: c.int) -> rawptr ---
	newuserdatauv :: proc(L: ^State, size: c.size_t, nuvalue: c.int) -> rawptr ---
	createtable  :: proc(L: ^State, narr, nrec: c.int) ---
	getfield     :: proc(L: ^State, idx: c.int, k: cstring) -> Type ---
	setfield     :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawget       :: proc(L: ^State, idx: c.int) -> Type ---
	rawset       :: proc(L: ^State, idx: c.int) ---
	rawgeti      :: proc(L: ^State, idx: c.int, n: Integer) -> Type ---
	rawseti      :: proc(L: ^State, idx: c.int, n: Integer) ---
	next         :: proc(L: ^State, idx: c.int) -> c.int ---
	getglobal    :: proc(L: ^State, name: cstring) -> Type ---
	setglobal    :: proc(L: ^State, name: cstring) ---
	getmetatable :: proc(L: ^State, idx: c.int) -> c.int ---
	setmetatable :: proc(L: ^State, idx: c.int) -> c.int ---
	pcallk       :: proc(L: ^State, nargs, nresults, errfunc: c.int, ctx: c.intptr_t, k: rawptr) -> c.int ---
	error        :: proc(L: ^State) -> c.int ---
	sethook      :: proc(L: ^State, f: Hook, mask, count: c.int) ---
	rawequal     :: proc(L: ^State, idx1, idx2: c.int) -> c.int ---
	getlocal     :: proc(L: ^State, ar: rawptr, n: c.int) -> cstring --- // ar nil: parameter names of the function on top
	newthread    :: proc(L: ^State) -> ^State ---
	closethread  :: proc(L: ^State, from: ^State) -> c.int ---
	yieldk       :: proc(L: ^State, nresults: c.int, ctx: c.intptr_t, k: rawptr) -> c.int ---
	resume       :: proc(L: ^State, from: ^State, narg: c.int, nres: ^c.int) -> c.int ---
	status       :: proc(L: ^State) -> c.int ---
	isyieldable  :: proc(L: ^State) -> c.int ---
	xmove        :: proc(from, to: ^State, n: c.int) ---
}

@(default_calling_convention = "c")
foreign lua {
	luaL_newstate    :: proc() -> ^State ---
	luaL_loadbufferx :: proc(L: ^State, buff: [^]u8, sz: c.size_t, name, mode: cstring) -> c.int ---
	luaL_requiref    :: proc(L: ^State, modname: cstring, openf: CFunction, glb: c.int) ---
	luaL_traceback   :: proc(L: ^State, L1: ^State, msg: cstring, level: c.int) ---
	luaopen_base     :: proc(L: ^State) -> c.int ---
	luaopen_string   :: proc(L: ^State) -> c.int ---
	luaopen_table    :: proc(L: ^State) -> c.int ---
	luaopen_math     :: proc(L: ^State) -> c.int ---
	luaopen_utf8     :: proc(L: ^State) -> c.int ---
	luaopen_coroutine :: proc(L: ^State) -> c.int ---
}

// The C API's macros.
pop :: proc "c" (L: ^State, n: c.int) { settop(L, -n - 1) }
newtable :: proc "c" (L: ^State) { createtable(L, 0, 0) }
pcall :: proc "c" (L: ^State, nargs, nresults, errfunc: c.int) -> c.int { return pcallk(L, nargs, nresults, errfunc, 0, nil) }
pushcfunction :: proc "c" (L: ^State, fn: CFunction) { pushcclosure(L, fn, 0) }
insert :: proc "c" (L: ^State, idx: c.int) { rotate(L, idx, 1) }
upvalueindex :: proc "c" (i: c.int) -> c.int { return REGISTRYINDEX - i }
yield :: proc "c" (L: ^State, n: c.int) -> c.int { return yieldk(L, n, 0, nil) }

pushstring :: proc "c" (L: ^State, s: string) { pushlstring(L, raw_data(s), c.size_t(len(s))) }

// tostring: the string at idx (a view into Lua memory, valid while it stays on
// the stack), or "" when it is neither a string nor a number.
tostring :: proc "c" (L: ^State, idx: c.int) -> string {
	n: c.size_t
	p := tolstring(L, idx, &n)
	return string(p[:n]) if p != nil else ""
}
