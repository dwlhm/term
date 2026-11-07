package feature_automation

// The `term` module and the shape of a contract. A contract file returns
// term.contract{...}: its functions (any key that is not reserved) take params
// and return steps; the reserved keys configure it. contract_check validates
// the shape without running anything.

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import lua "../../platform/lua"

CONTRACT_API :: 1

@(private = "file")
CONTRACT_MT_KEY :: "term.contract"

@(private = "file")
_ON_KEYS := [?]string{"human", "interrupt", "unexpected", "finally", "release"}
@(private = "file")
_TIMEOUT_KEYS := [?]string{"expect", "settle", "run"}
@(private = "file")
_PARAM_TYPES := [?]string{"string", "number", "boolean"}

Contract_Info :: struct {
	functions: [dynamic]string, // sorted
	serves:    bool,            // has a serve function (term auto serve)
}

contract_info_destroy :: proc(info: ^Contract_Info) {
	for f in info.functions do delete(f)
	delete(info.functions)
}

@(private = "file")
TERM_PRELUDE :: #load("term_prelude.lua", string)

// term_module_open pushes the `term` module: contract and api from here,
// step builders and matching from term_prelude.lua.
term_module_open :: proc "c" (L: ^lua.State) -> c.int {
	lua.createtable(L, 0, 24)
	lua.pushinteger(L, CONTRACT_API)
	lua.setfield(L, -2, "api")
	lua.pushcfunction(L, _contract_new)
	lua.setfield(L, -2, "contract")
	src := TERM_PRELUDE
	if lua.luaL_loadbufferx(L, raw_data(src), c.size_t(len(src)), "=term", "t") != lua.OK do return lua.error(L)
	lua.insert(L, -2)
	if lua.pcall(L, 1, 1, 0) != lua.OK do return lua.error(L)
	return 1
}

// term.contract(t) marks t as a contract and returns it.
@(private = "file")
_contract_new :: proc "c" (L: ^lua.State) -> c.int {
	if lua.type(L, 1) != .Table {
		lua.pushstring(L, "term.contract expects a table")
		return lua.error(L)
	}
	lua.settop(L, 1)
	_push_contract_mt(L)
	lua.setmetatable(L, 1)
	return 1
}

@(private = "file")
_push_contract_mt :: proc "c" (L: ^lua.State) {
	if lua.getfield(L, lua.REGISTRYINDEX, CONTRACT_MT_KEY) == .Table do return
	lua.pop(L, 1)
	lua.createtable(L, 0, 1)
	lua.pushstring(L, "term.contract")
	lua.setfield(L, -2, "__name")
	lua.pushvalue(L, -1)
	lua.setfield(L, lua.REGISTRYINDEX, CONTRACT_MT_KEY)
}

// contract_check validates the contract on top of the stack (left there).
// err is in the temp allocator.
contract_check :: proc(vm: ^Vm) -> (info: Contract_Info, err: string, ok: bool) {
	L := vm.L
	t := lua.absindex(L, -1)
	if !_is_contract(L, t) do return info, "the file must return term.contract{...}", false
	lua.pushnil(L)
	for lua.next(L, t) != 0 {
		// -2 key, -1 value
		if lua.type(L, -2) != .String {
			lua.pop(L, 2)
			contract_info_destroy(&info)
			return {}, "contract keys must be names", false
		}
		key := lua.tostring(L, -2)
		if e := _check_entry(L, key, &info); e != "" {
			lua.pop(L, 2)
			contract_info_destroy(&info)
			return {}, e, false
		}
		lua.pop(L, 1)
	}
	if e := _check_params(L, t, &info); e != "" {
		contract_info_destroy(&info)
		return {}, e, false
	}
	if len(info.functions) == 0 && !info.serves {
		contract_info_destroy(&info)
		return {}, "the contract has no function", false
	}
	slice.sort(info.functions[:])
	return info, "", true
}

@(private = "file")
_is_contract :: proc(L: ^lua.State, t: c.int) -> bool {
	if lua.type(L, t) != .Table || lua.getmetatable(L, t) == 0 do return false
	_push_contract_mt(L)
	same := lua.rawequal(L, -1, -2) != 0
	lua.pop(L, 2)
	return same
}

// _check_entry checks the value on top of the stack under key.
@(private = "file")
_check_entry :: proc(L: ^lua.State, key: string, info: ^Contract_Info) -> string {
	tp := lua.type(L, -1)
	switch key {
	case "api":
		if tp != .Number || lua.isinteger(L, -1) == 0 || lua.tointegerx(L, -1, nil) != CONTRACT_API {
			return fmt.tprintf("api %s is not supported: this term runs api %d", lua.tostring(L, -1), CONTRACT_API)
		}
	case "adapter":
		if tp != .Table do return "adapter must be an adapter table (require \"term.adapter.<name>\")"
	case "on":       return _check_on(L)
	case "timeouts": return _check_timeouts(L)
	case "params":
		if tp != .Table do return "params must be a table: function name → {param = type}"
	case "serve":
		if tp != .Function do return "serve must be a function (request text → steps)"
		info.serves = true
	case:
		if !_is_name(key) do return fmt.tprintf("%q is not a function name (letters, digits and _)", key)
		if tp != .Function do return fmt.tprintf("%s must be a function (params → steps), not %s", key, lua.typename(L, tp))
		append(&info.functions, strings.clone(key))
	}
	return ""
}

@(private = "file")
_check_on :: proc(L: ^lua.State) -> string {
	if lua.type(L, -1) != .Table do return "on must be a table"
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		key := lua.tostring(L, -2) if lua.type(L, -2) == .String else ""
		tp := lua.type(L, -1)
		e := ""
		switch {
		case !slice.contains(_ON_KEYS[:], key):
			e = fmt.tprintf("on.%s is unknown: on takes %s", key, strings.join(_ON_KEYS[:], ", ", context.temp_allocator))
		case key == "human" && tp != .Function:
			e = "on.human must be a function (input → \"hold\" | \"cancel\")"
		case key == "interrupt" && tp != .Table:
			e = "on.interrupt must be a table: state → steps"
		case (key == "unexpected" || key == "finally") && tp != .Function && tp != .Table:
			e = fmt.tprintf("on.%s must be steps or a function returning steps", key)
		case key == "release" && !(tp == .String && (lua.tostring(L, -1) == "discard" || lua.tostring(L, -1) == "flush")):
			e = "on.release must be \"discard\" or \"flush\""
		}
		if e != "" {
			lua.pop(L, 2)
			return e
		}
		lua.pop(L, 1)
	}
	return ""
}

@(private = "file")
_check_timeouts :: proc(L: ^lua.State) -> string {
	if lua.type(L, -1) != .Table do return "timeouts must be a table of seconds"
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		key := lua.tostring(L, -2) if lua.type(L, -2) == .String else ""
		ok := slice.contains(_TIMEOUT_KEYS[:], key) && lua.type(L, -1) == .Number && lua.tonumberx(L, -1, nil) > 0
		lua.pop(L, 1)
		if !ok {
			lua.pop(L, 1)
			return fmt.tprintf("timeouts.%s must be a positive number of seconds (keys: expect, settle, run)", key)
		}
	}
	return ""
}

// _check_params: params[fn] names a function of the contract and maps its
// parameters to string, number or boolean.
@(private = "file")
_check_params :: proc(L: ^lua.State, t: c.int, info: ^Contract_Info) -> string {
	if lua.getfield(L, t, "params") != .Table {
		lua.pop(L, 1)
		return ""
	}
	defer lua.pop(L, 1)
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		fn := lua.tostring(L, -2) if lua.type(L, -2) == .String else ""
		e := ""
		if !slice.contains(info.functions[:], fn) do e = fmt.tprintf("params.%s: the contract has no function %q", fn, fn)
		else if lua.type(L, -1) != .Table do e = fmt.tprintf("params.%s must be a table: param → type", fn)
		else do e = _check_param_types(L, fn)
		lua.pop(L, 1)
		if e != "" {
			lua.pop(L, 1)
			return e
		}
	}
	return ""
}

@(private = "file")
_check_param_types :: proc(L: ^lua.State, fn: string) -> string {
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		name := lua.tostring(L, -2) if lua.type(L, -2) == .String else ""
		ok := _is_name(name) && lua.type(L, -1) == .String && slice.contains(_PARAM_TYPES[:], lua.tostring(L, -1))
		lua.pop(L, 1)
		if !ok {
			lua.pop(L, 1)
			return fmt.tprintf("params.%s.%s must be \"string\", \"number\" or \"boolean\"", fn, name)
		}
	}
	return ""
}

@(private = "file")
_is_name :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 || (s[0] >= '0' && s[0] <= '9') do return false
	for ch in s {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		case: return false
		}
	}
	return true
}
