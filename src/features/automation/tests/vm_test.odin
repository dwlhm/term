package feature_automation_tests

// The sandbox: only pure libraries, text chunks, bounded memory and time, and
// `require` limited to term modules and adapter files.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import auto ".."

@(private = "file")
_run :: proc(vm: ^auto.Vm, src: string) -> (err: string, ok: bool) {
	return auto.vm_load_chunk(vm, transmute([]u8)src, "test.lua")
}

@test
test_vm_has_only_pure_libraries :: proc(t: ^testing.T) {
	vm, ok := auto.vm_open()
	testing.expect(t, ok)
	defer auto.vm_close(vm)
	_, ran := _run(vm, `return string.upper("ok") .. table.concat({1, 2}) .. math.floor(2.5) .. utf8.char(72)`)
	testing.expect(t, ran)
	for name in ([?]string{"io", "os", "debug", "package", "load", "loadfile", "dofile", "print", "collectgarbage"}) {
		_, ran = _run(vm, strings.concatenate({"assert(", name, " == nil, '", name, "')"}, context.temp_allocator))
		testing.expectf(t, ran, "%s is not in the sandbox", name)
	}
	_, ran = _run(vm, `assert(string.dump == nil and math.random == nil)`)
	testing.expect(t, ran, "no bytecode dumps and no randomness")
}

@test
test_vm_rejects_bytecode :: proc(t: ^testing.T) {
	vm, _ := auto.vm_open()
	defer auto.vm_close(vm)
	err, ok := _run(vm, "\x1bLua\x54\x00garbage")
	testing.expect(t, !ok && strings.contains(err, "binary"), "a precompiled chunk is refused")
}

@test
test_vm_bounds_memory_and_time :: proc(t: ^testing.T) {
	vm, _ := auto.vm_open()
	defer auto.vm_close(vm)
	err, ok := _run(vm, `local s = string.rep("x", 1 << 20) local t = {} for i = 1, 1000 do t[i] = s .. i end`)
	testing.expect(t, !ok && strings.contains(err, "memory"), err)
	testing.expect(t, vm.mem_used <= vm.mem_cap)
	err, ok = _run(vm, `while true do end`)
	testing.expect(t, !ok && strings.contains(err, "time budget") && vm.over_budget, err)
	_, ok = _run(vm, `return 1 + 1`)
	testing.expect(t, ok, "the state is usable after both")
}

@test
test_vm_require_is_limited :: proc(t: ^testing.T) {
	dir := _temp_dir("req")
	defer os.remove_all(dir)
	_write(dir, "good.lua", `return {name = "good"}`)
	_write(dir, "loop.lua", `return require("term.adapter.loop")`)
	vm, _ := auto.vm_open({dir})
	defer auto.vm_close(vm)
	_, ok := _run(vm, `local a = require("term.adapter.good") assert(a.name == "good" and require("term.adapter.good") == a)`)
	testing.expect(t, ok, "adapters load once from the adapter dirs")
	_, ok = _run(vm, `assert(require("term").api == 1)`)
	testing.expect(t, ok, "the term module is built in")
	cases := [?]struct{ src, want: string }{
		{`require("os")`, "not available"},
		{`require("term.adapter.../etc/passwd")`, "not available"},
		{`require("term.adapter.missing")`, "not found"},
		{`require("term.adapter.loop")`, "require loop"},
	}
	for c in cases {
		err, loaded := _run(vm, c.src)
		testing.expectf(t, !loaded && strings.contains(err, c.want), "%s: %s", c.src, err)
	}
}

_temp_dir :: proc(tag: string) -> string {
	dir, _ := filepath.join({os.get_env("TMPDIR", context.temp_allocator), strings.concatenate({"term-auto-", tag}, context.temp_allocator)}, context.temp_allocator)
	os.remove_all(dir)
	os.make_directory(dir)
	return dir
}

_write :: proc(dir, name, body: string) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)body)
}
