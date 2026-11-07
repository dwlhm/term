package feature_automation_tests

// contract_check: what a valid contract looks like and what each mistake says.

import "core:strings"
import "core:testing"
import auto ".."

@(private = "file")
_check :: proc(src: string) -> (info: auto.Contract_Info, err: string, ok: bool) {
	vm, _ := auto.vm_open()
	defer auto.vm_close(vm)
	if e, loaded := auto.vm_load_chunk(vm, transmute([]u8)src, "c.lua"); !loaded do return {}, e, false
	return auto.contract_check(vm)
}

@test
test_contract_valid :: proc(t: ^testing.T) {
	info, err, ok := _check(`
local t = require "term"
return t.contract {
  api = 1,
  timeouts = { expect = 5, run = 60 },
  params = { commit = { msg = "string", amend = "boolean" } },
  on = { human = function(input) return "hold" end, finally = {}, release = "flush" },
  commit = function(msg, amend) return {} end,
  branch = function() return {} end,
}`)
	defer auto.contract_info_destroy(&info)
	testing.expectf(t, ok, "valid contract: %s", err)
	testing.expect(t, len(info.functions) == 2 && info.functions[0] == "branch" && info.functions[1] == "commit", "sorted function names")
	testing.expect(t, !info.serves)
}

@test
test_contract_mistakes :: proc(t: ^testing.T) {
	cases := [?]struct{ src, want: string }{
		{`return {}`, "must return term.contract"},
		{`return 42`, "must return term.contract"},
		{`return require("term").contract {}`, "no function"},
		{`return require("term").contract { api = 2, f = function() end }`, "api 2 is not supported"},
		{`return require("term").contract { f = 1 }`, "f must be a function"},
		{`return require("term").contract { ["bad name"] = function() end }`, "is not a function name"},
		{`return require("term").contract { [1] = function() end }`, "keys must be names"},
		{`return require("term").contract { f = function() end, on = { oops = 1 } }`, "on.oops is unknown"},
		{`return require("term").contract { f = function() end, on = { human = "hold" } }`, "on.human must be a function"},
		{`return require("term").contract { f = function() end, on = { release = "keep" } }`, "on.release must be"},
		{`return require("term").contract { f = function() end, timeouts = { expect = -1 } }`, "timeouts.expect must be a positive"},
		{`return require("term").contract { f = function() end, timeouts = { forever = 1 } }`, "timeouts.forever"},
		{`return require("term").contract { f = function() end, params = { g = {} } }`, "no function \"g\""},
		{`return require("term").contract { f = function() end, params = { f = { x = "table" } } }`, "params.f.x must be"},
		{`return require("term").contract { serve = 1 }`, "serve must be a function"},
		{`syntax error here`, "c.lua"},
	}
	for c in cases {
		info, err, ok := _check(c.src)
		auto.contract_info_destroy(&info)
		testing.expectf(t, !ok && strings.contains(err, c.want), "%s → %q (want %q)", c.src, err, c.want)
	}
	info, err, ok := _check(`return require("term").contract { serve = function(text) return {} end }`)
	defer auto.contract_info_destroy(&info)
	testing.expectf(t, ok && info.serves, "a serve-only contract is valid: %s", err)
}
