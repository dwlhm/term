package feature_automation_tests

// The bundled adapters on snapshots of their programs (adapters are tested
// this way: saved snapshot + plain Lua asserts), and the adapter contract.

import "core:strings"
import "core:testing"
import auto ".."

@(private = "file")
_lua :: proc(t: ^testing.T, body: string) {
	vm, _ := auto.vm_open()
	defer auto.vm_close(vm)
	src := strings.concatenate({"local t = require 'term'\nlocal dir = '", #directory, "testdata/'\nlocal load = require('term.screen').load\n", body, "\nreturn true"}, context.temp_allocator)
	err, ok := auto.vm_load_chunk(vm, transmute([]u8)src, "adapter_test.lua")
	testing.expectf(t, ok, "lua: %s", err)
}

@test
test_adapter_lazygit :: proc(t: ^testing.T) {
	_lua(t, `
local lg = require "term.adapter.lazygit"
assert(t.is_adapter(lg) and lg.name == "lazygit")
local s = load(dir .. "lazygit.json")
assert(lg.detect(s), "detects lazygit")
assert(not lg.detect(load(dir .. "fzf.json")) and not lg.detect(load(dir .. "vim.json")), "only lazygit")
t._adapter = lg
local files = t.match(s, lg.state.files)
assert(files and files.name == "Files - Worktrees - Submodules", "panel names lose their number: " .. tostring(files and files.name))
assert(t.match(s, { role = "dialog" }).focused, "the green-bordered popup is focused")
assert(not files.focused, "the files panel is not")
local tab = t.match(s, { role = "tab", name = "Files" })
assert(tab and tab.selected and tab.parent == files.ref, "the active tab of the Files panel")
assert(not t.match(s, { role = "tab", name = "Worktrees" }).selected)
assert(t.match(s, "Thanks for using lazygit!"), "the welcome popup an interrupt waits for")`)
}

@test
test_adapter_fzf :: proc(t: ^testing.T) {
	_lua(t, `
local fzf = require "term.adapter.fzf"
local s = load(dir .. "fzf.json")
assert(fzf.detect(s) and not fzf.detect(load(dir .. "nano.json")))
t._adapter = fzf
local cur = t.match(s, { role = "listitem", selected = true })
assert(cur and cur.name == "1" and cur.row == 10, "the current item: " .. tostring(cur and cur.name))
assert(t.match(s, { role = "listitem", name = "10" }).row == 1)
local n = 0
for _, e in ipairs(t.elements(s)) do if e.role == "listitem" then n = n + 1 end end
assert(n == 10, "ten items on screen, got " .. n)
assert(t.match(s, { role = "statusbar" }).name == "200/200")
assert(fzf.state.has(200)(s) and not fzf.state.has(3)(s))
for _, e in ipairs(t.elements(s)) do assert(e.ref and e.source, "refs and sources for adapter elements") end`)
}

@test
test_adapter_contract :: proc(t: ^testing.T) {
	_lua(t, `
local function fails(f, want)
  local ok, err = pcall(f)
  assert(not ok and string.find(err, want, 1, true), tostring(err))
end
fails(function() t.adapter { detect = function() end } end, "needs a name")
fails(function() t.adapter { name = "x", detect = function() end, oops = 1 } end, "'oops' is unknown")
fails(function() t.adapter { name = "x", detect = function() end, api = 2 } end, "api 2")
fails(function() t.adapter { name = "x", detect = function() end, interrupts = { 1 } } end, "interrupts[1]")
-- elements from an adapter need a place; marked elements stay as they were
local bad = t.adapter { name = "bad", detect = function() return true end, elements = function() return { { role = "x" } } end }
t._adapter = bad
fails(function() t.elements(load(dir .. "vim.json")) end, "needs role, row and col")
fails(function() require "term.adapter.nope" end, "not found")`)
}
