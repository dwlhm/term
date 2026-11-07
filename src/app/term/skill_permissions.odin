package term

// The agent permission `term auto serve` needs: an agent answers a served
// request by running `term session answer` (and reports with `term session
// progress`). `term skill setup` merges exactly those allow rules into the
// agent's own config, `remove` takes them out, `status` reports them.
// A config is backed up once to <file>.term-backup before the first change;
// one that is not plain JSON (comments, a parse error) is never written.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"

Permission_Format :: enum u8 { Claude, Opencode }

Agent_Permission :: struct {
	name:   string,
	host:   string, // the agent's directory under $HOME (it is installed)
	file:   string, // its config under $HOME
	format: Permission_Format,
}

AGENT_PERMISSIONS := [?]Agent_Permission{
	{"Claude Code", ".claude", ".claude/settings.json", .Claude},
	{"OpenCode", ".config/opencode", ".config/opencode/opencode.json", .Opencode},
}

@(private = "file")
CLAUDE_RULES := [?]string{"Bash(term session answer:*)", "Bash(term session progress:*)"}
@(private = "file")
OPENCODE_RULES := [?]string{"term session answer *", "term session progress *"}

Permission_State :: enum u8 { No_Host, Missing, Installed, Unreadable }

// permission_rules: what to add by hand when the config cannot be edited.
permission_rules :: proc(p: Agent_Permission) -> string {
	switch p.format {
	case .Claude:   return `"permissions": {"allow": ["Bash(term session answer:*)", "Bash(term session progress:*)"]}`
	case .Opencode: return `"permission": {"bash": {"term session answer *": "allow", "term session progress *": "allow"}}`
	}
	return ""
}

permission_state :: proc(home: string, p: Agent_Permission) -> Permission_State {
	host, _ := filepath.join({home, p.host}, context.temp_allocator)
	if !os.exists(host) do return .No_Host
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return .Unreadable
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	root, ok := _load(home, p, context.allocator)
	if !ok do return .Unreadable
	return .Installed if _apply(&root, p.format, install = true, check_only = true) else .Missing
}

// permission_install adds the rules; changed = the config was written.
permission_install :: proc(home: string, p: Agent_Permission) -> (changed: bool, ok: bool) {
	return _edit(home, p, install = true)
}

permission_remove :: proc(home: string, p: Agent_Permission) -> (changed: bool, ok: bool) {
	return _edit(home, p, install = false)
}

@(private = "file")
_edit :: proc(home: string, p: Agent_Permission, install: bool) -> (changed: bool, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return false, false
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	context.allocator = a // the edited JSON lives in the arena too
	root := _load(home, p, a) or_return
	if !_apply(&root, p.format, install, check_only = false) do return false, true
	path, _ := filepath.join({home, p.file}, a)
	backup := fmt.aprintf("%s.term-backup", path, allocator = a)
	if old, err := os.read_entire_file(path, a); err == nil && !os.exists(backup) {
		if os.write_entire_file(backup, old) != nil do return false, false
	}
	data, merr := json.marshal(root, {pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, a)
	if merr != nil do return false, false
	_ = os.make_directory(filepath.dir(path))
	return true, os.write_entire_file(path, data) == nil
}

// _load reads the config as a JSON object (an empty one when it does not exist).
@(private = "file")
_load :: proc(home: string, p: Agent_Permission, a: runtime.Allocator) -> (root: json.Value, ok: bool) {
	path, _ := filepath.join({home, p.file}, a)
	data, err := os.read_entire_file(path, a)
	if err != nil {
		if os.exists(path) do return nil, false
		return make(json.Object, a), true
	}
	v, perr := json.parse(data, json.Specification.JSON, parse_integers = true, allocator = a)
	if perr != nil do return nil, false
	_, is_object := v.(json.Object)
	return v, is_object
}


// _apply adds (install) or removes the rules in root; true = something
// changed (check_only: true = they are all there already).
// The object is written back: a map that grew moved, the old header is stale.
@(private = "file")
_apply :: proc(root: ^json.Value, format: Permission_Format, install, check_only: bool) -> (changed: bool) {
	obj := root.(json.Object)
	switch format {
	case .Claude:   changed = _apply_claude(&obj, install, check_only)
	case .Opencode: changed = _apply_opencode(&obj, install, check_only)
	}
	root^ = obj
	return
}

@(private = "file")
_apply_claude :: proc(root: ^json.Object, install, check_only: bool) -> bool {
	perms, _ := root^["permissions"].(json.Object)
	allow, _ := perms["allow"].(json.Array)
	has :: proc(list: json.Array, rule: string) -> bool {
		for v in list do if s, ok := v.(json.String); ok && s == rule do return true
		return false
	}
	if check_only {
		for rule in CLAUDE_RULES do if !has(allow, rule) do return false
		return true
	}
	changed := false
	if install {
		for rule in CLAUDE_RULES do if !has(allow, rule) {
			append(&allow, json.String(rule))
			changed = true
		}
	} else {
		for i := len(allow) - 1; i >= 0; i -= 1 {
			s, _ := allow[i].(json.String)
			if slice.contains(CLAUDE_RULES[:], string(s)) {
				ordered_remove(&allow, i)
				changed = true
			}
		}
	}
	if !changed do return false
	if perms == nil do perms = make(json.Object)
	perms["allow"] = allow
	root^["permissions"] = perms
	return true
}

@(private = "file")
_apply_opencode :: proc(root: ^json.Object, install, check_only: bool) -> bool {
	perm, _ := root^["permission"].(json.Object)
	bash: json.Object
	switch v in perm["bash"] {
	case json.String:
		if v == "allow" do return check_only // everything is allowed already
		if !install do return false
		bash = make(json.Object)
		bash["*"] = v // the old rule stays for every other command
	case json.Object:
		bash = v
	case json.Null, json.Integer, json.Float, json.Boolean, json.Array:
	}
	if check_only {
		for rule in OPENCODE_RULES do if s, _ := bash[rule].(json.String); s != "allow" do return false
		return true
	}
	changed := false
	for rule in OPENCODE_RULES {
		s, present := bash[rule].(json.String)
		if install && s != "allow" {
			if bash == nil do bash = make(json.Object)
			bash[rule] = json.String("allow")
			changed = true
		} else if !install && present {
			delete_key(&bash, rule)
			changed = true
		}
	}
	if !changed do return false
	if perm == nil do perm = make(json.Object)
	perm["bash"] = bash
	root^["permission"] = perm
	return true
}
