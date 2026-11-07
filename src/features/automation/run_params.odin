package feature_automation

// A function's params from the command line: positional, or --name value by
// the names in its Lua signature. contract.params[fn] types them (string by
// default); a param not given is asked for (t.ask's channel).

import "core:fmt"
import "core:strconv"
import "core:strings"
import lua "../../platform/lua"

RUN_PARAMS_MAX :: 16

// run_push_params pushes the params of the function on top of the stack.
run_push_params :: proc(r: ^Runner, function: string, args: []string) -> bool {
	L := r.vm.L
	names: [RUN_PARAMS_MAX]string
	n := 0
	for n < RUN_PARAMS_MAX {
		name := lua.getlocal(L, nil, i32(n + 1))
		if name == nil do break
		names[n] = strings.clone(string(name), context.temp_allocator)
		n += 1
	}
	values: [RUN_PARAMS_MAX]string
	given: [RUN_PARAMS_MAX]bool
	if !_bind_args(r, names[:n], args, values[:], given[:]) do return false
	for i in 0 ..< n {
		kind := _param_type(r, function, names[i])
		value := values[i]
		if !given[i] {
			answer, ok := run_ask(r, fmt.tprintf("%s: %s (%s)?", function, names[i], kind), kind, nil)
			if !ok do return false
			value = answer
		}
		if !_push_typed(r, names[i], kind, value) do return false
	}
	return true
}

// _bind_args matches positional and --name value args to names.
@(private = "file")
_bind_args :: proc(r: ^Runner, names: []string, args: []string, values: []string, given: []bool) -> bool {
	pos := 0
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if strings.has_prefix(a, "--") && len(a) > 2 {
			idx := -1
			for name, j in names do if name == a[2:] do idx = j
			if idx < 0 || i + 1 >= len(args) {
				run_stop(r, .Contract, fmt.tprintf("unknown or valueless param %s (params: %s)", a, strings.join(names, ", ", context.temp_allocator)))
				return false
			}
			values[idx], given[idx] = args[i + 1], true
			i += 1
			continue
		}
		for pos < len(names) && given[pos] do pos += 1
		if pos >= len(names) {
			run_stop(r, .Contract, fmt.tprintf("too many params: the function takes %d", len(names)))
			return false
		}
		values[pos], given[pos] = a, true
	}
	return true
}

// _param_type: contract.params[function][name], "string" when not declared.
@(private = "file")
_param_type :: proc(r: ^Runner, function, name: string) -> string {
	L := r.vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	if lua.getfield(L, -1, "params") != .Table do return "string"
	if lua.getfield(L, -1, strings.clone_to_cstring(function, context.temp_allocator)) != .Table do return "string"
	if lua.getfield(L, -1, strings.clone_to_cstring(name, context.temp_allocator)) != .String do return "string"
	return strings.clone(lua.tostring(L, -1), context.temp_allocator)
}

@(private = "file")
_push_typed :: proc(r: ^Runner, name, kind, value: string) -> bool {
	L := r.vm.L
	switch kind {
	case "number":
		n, ok := strconv.parse_f64(value)
		if !ok {
			run_stop(r, .Contract, fmt.tprintf("param %s must be a number, not %q", name, value))
			return false
		}
		lua.pushnumber(L, n)
	case "boolean":
		switch value {
		case "true", "yes", "1":  lua.pushboolean(L, 1)
		case "false", "no", "0": lua.pushboolean(L, 0)
		case:
			run_stop(r, .Contract, fmt.tprintf("param %s must be true or false, not %q", name, value))
			return false
		}
	case:
		lua.pushstring(L, value)
	}
	return true
}
