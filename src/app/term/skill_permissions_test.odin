package term

// Agent permissions in a scratch $HOME: merged, kept, removed, never forced
// into a config that is not plain JSON.

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
_home :: proc(tag: string) -> string {
	home, _ := filepath.join({os.get_env("TMPDIR", context.temp_allocator), strings.concatenate({"term-perm-", tag}, context.temp_allocator)}, context.temp_allocator)
	os.remove_all(home)
	os.make_directory(home)
	return home
}

@(private = "file")
_put :: proc(home, rel, body: string) {
	path, _ := filepath.join({home, rel}, context.temp_allocator)
	os.make_directory_all(filepath.dir(path))
	_ = os.write_entire_file(path, transmute([]u8)body)
}

@(private = "file")
_get :: proc(home, rel: string) -> string {
	path, _ := filepath.join({home, rel}, context.temp_allocator)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@test
test_claude_permission_merge_keep_remove :: proc(t: ^testing.T) {
	home := _home("claude")
	defer os.remove_all(home)
	claude := AGENT_PERMISSIONS[0]
	testing.expect_value(t, permission_state(home, claude), Permission_State.No_Host)
	_put(home, ".claude/settings.json", `{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]}, "hooks": {"Stop": []}}`)
	testing.expect_value(t, permission_state(home, claude), Permission_State.Missing)
	changed, ok := permission_install(home, claude)
	testing.expect(t, ok && changed)
	testing.expect_value(t, permission_state(home, claude), Permission_State.Installed)
	v, err := json.parse(transmute([]u8)_get(home, ".claude/settings.json"), allocator = context.temp_allocator)
	testing.expect(t, err == nil, "still JSON")
	root := v.(json.Object)
	allow := root["permissions"].(json.Object)["allow"].(json.Array)
	testing.expect(t, len(allow) == 3 && allow[0].(json.String) == "Bash(ls:*)", "the user's rules stay, first")
	testing.expect(t, root["model"].(json.String) == "opus" && root["permissions"].(json.Object)["deny"] != nil && root["hooks"] != nil, "everything else stays")
	testing.expect(t, strings.contains(_get(home, ".claude/settings.json.term-backup"), `"Bash(ls:*)"]`), "the original is backed up")
	changed, ok = permission_install(home, claude)
	testing.expect(t, ok && !changed, "installing twice writes nothing")
	changed, ok = permission_remove(home, claude)
	testing.expect(t, ok && changed && permission_state(home, claude) == .Missing)
	testing.expect(t, strings.contains(_get(home, ".claude/settings.json"), "Bash(ls:*)"), "removing keeps the user's rules")
}

@test
test_opencode_permission_forms :: proc(t: ^testing.T) {
	home := _home("opencode")
	defer os.remove_all(home)
	oc := AGENT_PERMISSIONS[1]
	os.make_directory_all(filepath.join({home, ".config/opencode"}, context.temp_allocator) or_else "")
	testing.expect_value(t, permission_state(home, oc), Permission_State.Missing) // no config yet
	changed, ok := permission_install(home, oc)
	testing.expectf(t, ok && changed && permission_state(home, oc) == .Installed, "a config is created: ok=%v changed=%v state=%v file=%q", ok, changed, permission_state(home, oc), _get(home, ".config/opencode/opencode.json"))

	_put(home, ".config/opencode/opencode.json", `{"permission": {"bash": "ask"}}`)
	changed, ok = permission_install(home, oc)
	testing.expect(t, ok && changed)
	text := _get(home, ".config/opencode/opencode.json")
	testing.expect(t, strings.contains(text, `"*": "ask"`) && strings.contains(text, `"term session answer *": "allow"`), "ask stays for every other command")

	_put(home, ".config/opencode/opencode.json", `{"permission": {"bash": "allow"}}`)
	testing.expect_value(t, permission_state(home, oc), Permission_State.Installed) // everything is allowed already
	changed, _ = permission_install(home, oc)
	testing.expect(t, !changed)

	commented := "{\n  // mine\n  \"permission\": {}\n}"
	_put(home, ".config/opencode/opencode.json", commented)
	testing.expect_value(t, permission_state(home, oc), Permission_State.Unreadable)
	_, ok = permission_install(home, oc)
	testing.expect(t, !ok && _get(home, ".config/opencode/opencode.json") == commented, "a config with comments is never rewritten")
}
