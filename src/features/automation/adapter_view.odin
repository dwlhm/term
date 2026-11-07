package feature_automation

// What an adapter makes of a screen, for `term auto snapshot --adapter`, and
// the adapters a contract can require (`term auto adapters`).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import lua "../../platform/lua"

// adapter_elements describes a snapshot payload's elements as the adapter
// refines them; detected says whether its detect accepts the screen.
adapter_elements :: proc(payload: []u8, name: string) -> (text: string, detected: bool, err: string) {
	vm, ok := vm_open(adapter_dirs())
	if !ok do return "", false, "cannot start Lua"
	defer vm_close(vm)
	L := vm.L
	// Not a format string: Lua's braces would read as fmt's.
	src := strings.concatenate({`local t = require "term"
local a = require("term.adapter.`, name, `")
t._adapter = a
return function(s)
  local out = {}
  for _, e in ipairs(t.elements(s)) do
    local flags = (e.selected and " selected" or "") .. (e.focused and " focused" or "") .. (e.checked and " checked" or "")
    local text = e.text ~= "" and string.format(" text=%q", e.text) or ""
    local parent = e.parent and (" in " .. e.parent) or ""
    out[#out + 1] = string.format("%s %s %q [%d,%d %dx%d]%s%s%s %s", e.ref, e.role, e.name, e.row, e.col, e.width, e.height, text, parent, flags, e.source)
  end
  return table.concat(out, "\n"), a.detect(s) and true or false
end`}, context.temp_allocator)
	if e, loaded := vm_load_chunk(vm, transmute([]u8)src, "snapshot"); !loaded do return "", false, e
	if !lua_push_screen(L, payload) do return "", false, "malformed snapshot"
	if e, called := vm_call(vm, 1, 2); !called do return "", false, e
	return strings.clone(lua.tostring(L, -2), context.temp_allocator), lua.toboolean(L, -1) != 0, ""
}

Adapter_Info :: struct {
	name:  string,
	source: string, // "bundled" or the file
}

// adapter_list: every adapter a contract can require, the one that wins
// first (a project or user file over a bundled one of the same name).
adapter_list :: proc() -> []Adapter_Info {
	out: [dynamic]Adapter_Info
	out.allocator = context.temp_allocator
	seen := make(map[string]bool, 16, context.temp_allocator)
	for dir in adapter_dirs() {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do continue
		for e in entries {
			if !strings.has_suffix(e.name, ".lua") do continue
			name := e.name[:len(e.name) - 4]
			if seen[name] do continue
			seen[name] = true
			path, _ := filepath.join({dir, e.name}, context.temp_allocator)
			append(&out, Adapter_Info{name, path})
		}
	}
	for name in bundled_adapter_names() {
		if seen[name] do continue
		append(&out, Adapter_Info{name, "bundled"})
	}
	return out[:]
}
