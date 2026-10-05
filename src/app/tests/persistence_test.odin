package app_test

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import app "../"

@(test)
test_restore_argument_modes :: proc(t: ^testing.T) {
	folder_args := [?]string{"term", "--restore-default-for", "/tmp/folder with spaces/é"}
	folder, folder_ok := app.parse_restore_args(folder_args[:])
	testing.expect(t, folder_ok, "folder restore arguments should parse")
	testing.expect_value(t, folder.mode, app.Restore_Mode.Folder_Default)
	testing.expect_value(t, folder.value, "/tmp/folder with spaces/é")

	file_args := [?]string{"term", "--restore-file", "/tmp/work space.term.json"}
	file, file_ok := app.parse_restore_args(file_args[:])
	testing.expect(t, file_ok, "file restore arguments should parse")
	testing.expect_value(t, file.mode, app.Restore_Mode.Exact_File)

	legacy_args := [?]string{"term", "-r", "dev"}
	legacy, legacy_ok := app.parse_restore_args(legacy_args[:])
	testing.expect(t, legacy_ok, "legacy restore arguments should parse")
	testing.expect_value(t, legacy.mode, app.Restore_Mode.Legacy)
	testing.expect_value(t, legacy.value, "dev")

	default_args := [?]string{"term", "--restore"}
	default_request, default_ok := app.parse_restore_args(default_args[:])
	testing.expect(t, default_ok, "legacy restore without a name should parse")
	testing.expect_value(t, default_request.value, app.DEFAULT_LAYOUT_NAME)

	bad_args := [?]string{"term", "--restore-file"}
	_, bad_ok := app.parse_restore_args(bad_args[:])
	testing.expect(t, !bad_ok, "missing file path should be rejected")

	multiple_args := [?]string{"term", "--restore", "one", "-r", "two"}
	_, multiple_ok := app.parse_restore_args(multiple_args[:])
	testing.expect(t, !multiple_ok, "multiple restore modes should be rejected")

	extra_args := [?]string{"term", "--restore-file", "workspace.odin", "extra"}
	_, extra_ok := app.parse_restore_args(extra_args[:])
	testing.expect(t, !extra_ok, "extra arguments should be rejected")

	missing_value_args := [?]string{"term", "--restore-default-for", "--restore"}
	_, missing_value_ok := app.parse_restore_args(missing_value_args[:])
	testing.expect(t, !missing_value_ok, "option in place of path should be rejected")
}

@(test)
test_persistence_expand_path :: proc(t: ^testing.T) {
	home, hok := os.lookup_env("HOME", context.temp_allocator)
	if hok && len(home) > 0 {
		expanded_tilde := app.persistence_expand_path("~", "/tmp")
		defer delete(expanded_tilde)
		testing.expect_value(t, expanded_tilde, home)

		expanded_sub := app.persistence_expand_path("~/projects", "/tmp")
		defer delete(expanded_sub)
		expected_sub := fmt.tprintf("%s/projects", home)
		testing.expect_value(t, expanded_sub, expected_sub)
	}

	// Environment variable interpolation
	os.set_env("TERM_TEST_VAR", "my_custom_folder")
	defer os.unset_env("TERM_TEST_VAR")

	expanded_env := app.persistence_expand_path("/base/$TERM_TEST_VAR/app", "/tmp")
	defer delete(expanded_env)
	testing.expect_value(t, expanded_env, "/base/my_custom_folder/app")

	expanded_env_braces := app.persistence_expand_path("/base/${TERM_TEST_VAR}/app", "/tmp")
	defer delete(expanded_env_braces)
	testing.expect_value(t, expanded_env_braces, "/base/my_custom_folder/app")

	// Relative path resolution against base_dir
	expanded_rel := app.persistence_expand_path("./frontend", "/var/www/project")
	defer delete(expanded_rel)
	testing.expect_value(t, expanded_rel, "/var/www/project/frontend")

	expanded_dot := app.persistence_expand_path(".", "/var/www/project")
	defer delete(expanded_dot)
	testing.expect_value(t, expanded_dot, "/var/www/project")
}

@(test)
test_persistence_parse_odin_split_tree :: proc(t: ^testing.T) {
	src := `
name  = "dev"
title = "Fullstack Workspace"
cwd   = "/tmp/project"

layout = Split {
    direction = .Vertical,
    ratio     = 0.6,
    first = Pane {
        command = "npm run dev",
        cwd     = "./web",
    },
    second = Split {
        direction = .Horizontal,
        ratio     = 0.4,
        first = Pane {
            command = "cargo run",
            cwd     = "./api",
        },
        second = Pane {
            command = "git status",
            cwd     = ".",
        },
    },
}
`
	layout, ok, err_msg := app.parse_layout_odin(src, "dev.odin")
	defer app.persistence_free_layout(&layout)

	testing.expect(t, ok, fmt.tprintf("parse_layout_odin failed: %s", err_msg))
	testing.expect_value(t, layout.name, "dev")
	testing.expect_value(t, layout.title, "Fullstack Workspace")
	testing.expect_value(t, layout.cwd, "/tmp/project")

	testing.expect(t, layout.root != nil, "root node must not be nil")
	testing.expect(t, layout.root.is_split, "root node must be split")
	testing.expect_value(t, layout.root.split.direction, app.Split_Direction.Vertical)
	testing.expect(t, layout.root.split.ratio > 0.59 && layout.root.split.ratio < 0.61, "ratio must be ~0.6")

	// First branch: leaf 1
	first := layout.root.split.first
	testing.expect(t, first != nil, "first child must not be nil")
	testing.expect(t, !first.is_split, "first child must be leaf")
	testing.expect_value(t, first.leaf.command, "npm run dev")
	testing.expect_value(t, first.leaf.cwd, "./web")

	// Second branch: split 2
	second := layout.root.split.second
	testing.expect(t, second != nil, "second child must not be nil")
	testing.expect(t, second.is_split, "second child must be split")
	testing.expect_value(t, second.split.direction, app.Split_Direction.Horizontal)
	testing.expect(t, second.split.ratio > 0.39 && second.split.ratio < 0.41, "ratio must be ~0.4")

	second_first := second.split.first
	testing.expect(t, second_first != nil && !second_first.is_split, "second_first must be leaf")
	testing.expect_value(t, second_first.leaf.command, "cargo run")
	testing.expect_value(t, second_first.leaf.cwd, "./api")

	second_second := second.split.second
	testing.expect(t, second_second != nil && !second_second.is_split, "second_second must be leaf")
	testing.expect_value(t, second_second.leaf.command, "git status")
	testing.expect_value(t, second_second.leaf.cwd, ".")
}

@(test)
test_persistence_parse_odin_flat_list :: proc(t: ^testing.T) {
	src := `
name  = "flat_stack"
title = "Trio"

panes = {
    Pane { command = "echo 1", cwd = "./pane1" },
    Pane { command = "echo 2", cwd = "./pane2", split = .Vertical },
    Pane { command = "echo 3", cwd = "./pane3", split = .Horizontal },
}
`
	layout, ok, err_msg := app.parse_layout_odin(src, "flat.odin")
	defer app.persistence_free_layout(&layout)

	testing.expect(t, ok, fmt.tprintf("parse_layout_odin failed: %s", err_msg))
	testing.expect_value(t, layout.name, "flat_stack")
	testing.expect_value(t, layout.title, "Trio")
	testing.expect(t, layout.root != nil, "root must not be nil")
	testing.expect(t, layout.root.is_split, "root must be split for 3 panes")

	leaf1 := app._find_first_persisted_leaf(layout.root)
	testing.expect(t, leaf1 != nil, "first leaf must exist")
	testing.expect_value(t, leaf1.command, "echo 1")
}

@(test)
test_persistence_exact_file_loader :: proc(t: ^testing.T) {
	path := "./restore exact.term.json"
	src := `{"name":"exact","layout":{"command":"echo exact"}}`
	err := os.write_entire_file(path, transmute([]u8)src)
	testing.expect(t, err == nil, "temporary exact file should be written")
	defer os.remove(path)
	layout, ok := app.persistence_load_layout_file(path)
	defer app.persistence_free_layout(&layout)
	testing.expect(t, ok, "exact workspace file should load")
	testing.expect_value(t, layout.name, "exact")

	odin_path := "./restore exact workspace.odin"
	odin_src := `name = "exact_odin"
layout = Pane { command = "echo exact" }
`
	err = os.write_entire_file(odin_path, transmute([]u8)odin_src)
	testing.expect(t, err == nil, "temporary exact Odin file should be written")
	defer os.remove(odin_path)
	odin_layout, odin_ok := app.persistence_load_layout_file(odin_path)
	defer app.persistence_free_layout(&odin_layout)
	testing.expect(t, odin_ok, "exact Odin workspace file should load")

	_, missing_ok := app.persistence_load_layout_file("./missing.term.json")
	testing.expect(t, !missing_ok, "missing exact file should fail")
	_, suffix_ok := app.persistence_load_layout_file("./restore exact.txt")
	testing.expect(t, !suffix_ok, "unsupported exact file suffix should fail")
}

@(test)
test_persistence_folder_default_patterns_and_precedence :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "term restore layouts *", context.allocator)
	if !testing.expect(t, root_err == nil) do return
	defer delete(root)
	defer os.remove_all(root)

	patterns := [?]string{
		".default.term.odin",
		".term/default.odin",
		"default.term.odin",
		".default.term.json",
		".term/default.json",
		"default.term.json",
	}
	for pattern, i in patterns {
		folder, _ := filepath.join({root, fmt.tprintf("pattern-%d", i)}, context.allocator)
		defer delete(folder)
		path, _ := filepath.join({folder, pattern}, context.allocator)
		defer delete(path)
		if !testing.expect(t, os.mkdir_all(filepath.dir(path)) == nil) do return
		src := `{"name":"pattern","layout":{"command":"echo pattern"}}` if strings.has_suffix(path, ".json") else `name = "pattern"
layout = Pane { command = "echo pattern" }
`
		if !testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil) do return
		resolved, found := app.persistence_resolve_default_for_folder(folder)
		if !testing.expect(t, found, "folder default pattern should resolve") do return
		defer delete(resolved)
		loaded, ok := app.persistence_load_layout_file(resolved)
		defer app.persistence_free_layout(&loaded)
		testing.expect(t, ok, "resolved folder default should load")
	}

	global_dir, _ := filepath.join({root, "global"}, context.allocator)
	defer delete(global_dir)
	global_path, _ := filepath.join({global_dir, "default.odin"}, context.allocator)
	defer delete(global_path)
	_ = os.mkdir_all(global_dir)
	global_src := `name = "global"
layout = Pane { command = "echo global" }
`
	_ = os.write_entire_file(global_path, transmute([]u8)global_src)
	os.set_env("TERM_PERSISTENCE_DIR", global_dir)
	defer os.unset_env("TERM_PERSISTENCE_DIR")

	local_dir, _ := filepath.join({root, "local"}, context.allocator)
	defer delete(local_dir)
	local_path, _ := filepath.join({local_dir, ".term/default.odin"}, context.allocator)
	defer delete(local_path)
	_ = os.mkdir_all(filepath.dir(local_path))
	local_src := `name = "local"
layout = Pane { command = "echo local" }
`
	_ = os.write_entire_file(local_path, transmute([]u8)local_src)
	resolved, found := app.persistence_resolve_default_for_folder(local_dir)
	defer if found do delete(resolved)
	testing.expect(t, found, "configured global fallback should resolve")
	testing.expect_value(t, resolved, local_path)

	loaded_local, loaded_local_ok := app.persistence_load_default_for_folder(local_dir)
	defer app.persistence_free_layout(&loaded_local)
	testing.expect(t, loaded_local_ok, "valid local default should load ahead of global")
	testing.expect_value(t, loaded_local.name, "local")

	later_local_dir, _ := filepath.join({root, "later-local"}, context.allocator)
	defer delete(later_local_dir)
	first_local, _ := filepath.join({later_local_dir, ".term/default.odin"}, context.allocator)
	defer delete(first_local)
	later_local, _ := filepath.join({later_local_dir, "default.term.json"}, context.allocator)
	defer delete(later_local)
	_ = os.mkdir_all(filepath.dir(first_local))
	_ = os.write_entire_file(first_local, "invalid")
	_ = os.write_entire_file(later_local, `{"name":"later-local","layout":{"command":"echo later"}}`)
	loaded_later, loaded_later_ok := app.persistence_load_default_for_folder(later_local_dir)
	defer app.persistence_free_layout(&loaded_later)
	testing.expect(t, loaded_later_ok, "malformed local candidate should not block a later local candidate")
	testing.expect_value(t, loaded_later.name, "later-local")

	global_fallback_dir, _ := filepath.join({root, "global-fallback"}, context.allocator)
	defer delete(global_fallback_dir)
	bad_local, _ := filepath.join({global_fallback_dir, ".default.term.odin"}, context.allocator)
	defer delete(bad_local)
	_ = os.write_entire_file(bad_local, "invalid")
	loaded_global, loaded_global_ok := app.persistence_load_default_for_folder(global_fallback_dir)
	defer app.persistence_free_layout(&loaded_global)
	testing.expect(t, loaded_global_ok, "malformed local candidate should fall back to valid global default")
	testing.expect_value(t, loaded_global.name, "global")

	invalid_global_dir, _ := filepath.join({root, "all-invalid"}, context.allocator)
	defer delete(invalid_global_dir)
	invalid_config_dir, _ := filepath.join({root, "invalid-global"}, context.allocator)
	defer delete(invalid_config_dir)
	_ = os.mkdir_all(invalid_config_dir)
	invalid_global_path, _ := filepath.join({invalid_config_dir, "default.odin"}, context.allocator)
	defer delete(invalid_global_path)
	_ = os.write_entire_file(invalid_global_path, "invalid")
	os.set_env("TERM_PERSISTENCE_DIR", invalid_config_dir)
	bad_local_all, _ := filepath.join({invalid_global_dir, ".default.term.json"}, context.allocator)
	defer delete(bad_local_all)
	_ = os.write_entire_file(bad_local_all, "null")
	_, all_invalid_ok := app.persistence_load_default_for_folder(invalid_global_dir)
	os.set_env("TERM_PERSISTENCE_DIR", global_dir)
	testing.expect(t, !all_invalid_ok, "all malformed local and global candidates should fail")

	missing_dir, _ := filepath.join({root, "missing"}, context.allocator)
	defer delete(missing_dir)
	resolved_global, global_found := app.persistence_resolve_default_for_folder(missing_dir)
	defer if global_found do delete(resolved_global)
	testing.expect(t, global_found, "missing folder default should use global fallback")
	testing.expect_value(t, resolved_global, global_path)
}

@(test)
test_persistence_exact_file_rejects_unreadable_and_invalid_content :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "term restore invalid *", context.allocator)
	if !testing.expect(t, root_err == nil) do return
	defer delete(root)
	defer os.remove_all(root)

	invalid_path, _ := filepath.join({root, "invalid.json"}, context.allocator)
	defer delete(invalid_path)
	_ = os.write_entire_file(invalid_path, "null")
	_, invalid_ok := app.persistence_load_layout_file(invalid_path)
	testing.expect(t, !invalid_ok, "invalid layout content should fail")

	unreadable_path, _ := filepath.join({root, "directory.json"}, context.allocator)
	defer delete(unreadable_path)
	_ = os.mkdir_all(unreadable_path)
	_, unreadable_ok := app.persistence_load_layout_file(unreadable_path)
	testing.expect(t, !unreadable_ok, "unreadable exact path should fail")
}

@(test)
test_persistence_restore_context_cwd_resolution :: proc(t: ^testing.T) {
	context_dir := "/tmp/workspace folder/é"
	layout_cwd := app.persistence_expand_path("./project", context_dir)
	defer delete(layout_cwd)
	testing.expect_value(t, layout_cwd, "/tmp/workspace folder/é/project")

	pane_cwd := app.persistence_expand_path("../pane", layout_cwd)
	defer delete(pane_cwd)
	testing.expect_value(t, pane_cwd, "/tmp/workspace folder/é/pane")

	absolute_cwd := app.persistence_expand_path("/opt/authoritative", layout_cwd)
	defer delete(absolute_cwd)
	testing.expect_value(t, absolute_cwd, "/opt/authoritative")
}

@(test)
test_persistence_resolve_default_layout :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "term default layout *", context.allocator)
	if !testing.expect(t, root_err == nil, "temporary directory must be created") do return
	defer delete(root)
	defer os.remove_all(root)

	original_cwd, cwd_err := os.getwd(context.allocator)
	if !testing.expect(t, cwd_err == nil, "current directory must be read") do return
	defer delete(original_cwd)
	if !testing.expect(t, os.setwd(root) == nil, "temporary directory must become current") do return
	defer os.setwd(original_cwd)

	tmp_path := "./.default.term.odin"
	content := "name = \"default\"\ntitle = \"Default Layout\"\nlayout = Pane { command = \"echo hello\" }\n"
	write_err := os.write_entire_file(tmp_path, transmute([]u8)content)
	testing.expect(t, write_err == nil, "write temporary .default.term.odin must succeed")

	path, found := app.persistence_resolve_layout_path("")
	defer if found do delete(path)
	testing.expect(t, found, "persistence_resolve_layout_path('') must find .default.term.odin")
	testing.expect_value(t, path, "./.default.term.odin")

	path_def, found_def := app.persistence_resolve_layout_path("default")
	defer if found_def do delete(path_def)
	testing.expect(t, found_def, "persistence_resolve_layout_path('default') must find .default.term.odin")
	testing.expect_value(t, path_def, "./.default.term.odin")
}

@(test)
test_persistence_resolve_named_layout_dotfile :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "term named layout *", context.allocator)
	if !testing.expect(t, root_err == nil, "temporary directory must be created") do return
	defer delete(root)
	defer os.remove_all(root)

	original_cwd, cwd_err := os.getwd(context.allocator)
	if !testing.expect(t, cwd_err == nil, "current directory must be read") do return
	defer delete(original_cwd)
	if !testing.expect(t, os.setwd(root) == nil, "temporary directory must become current") do return
	defer os.setwd(original_cwd)

	tmp_path := "./.mycustom.term.odin"
	content := "name = \"mycustom\"\nlayout = Pane { command = \"echo custom\" }\n"
	write_err := os.write_entire_file(tmp_path, transmute([]u8)content)
	testing.expect(t, write_err == nil, "write temporary .mycustom.term.odin must succeed")

	path, found := app.persistence_resolve_layout_path("mycustom")
	defer if found do delete(path)
	testing.expect(t, found, "persistence_resolve_layout_path('mycustom') must find .mycustom.term.odin")
	testing.expect_value(t, path, "./.mycustom.term.odin")
}

@(test)
test_persistence_json_fallback :: proc(t: ^testing.T) {
	json_src := `{
		"name": "json_dev",
		"title": "JSON Dev Stack",
		"cwd": "/tmp/json_proj",
		"layout": {
			"direction": "vertical",
			"ratio": 0.5,
			"first": {
				"command": "npm run build",
				"cwd": "./web"
			},
			"second": {
				"command": "cargo check",
				"cwd": "./core"
			}
		}
	}`

	layout, ok := app.parse_layout_json(json_src, "layout.json")
	defer app.persistence_free_layout(&layout)

	testing.expect(t, ok, "parse_layout_json must succeed")
	testing.expect_value(t, layout.name, "json_dev")
	testing.expect_value(t, layout.title, "JSON Dev Stack")
	testing.expect_value(t, layout.cwd, "/tmp/json_proj")
	testing.expect(t, layout.root != nil, "root must exist")
	testing.expect(t, layout.root.is_split, "root must be split")
	testing.expect_value(t, layout.root.split.direction, app.Split_Direction.Vertical)

	first := layout.root.split.first
	testing.expect(t, first != nil && !first.is_split, "first must be leaf")
	testing.expect_value(t, first.leaf.command, "npm run build")
	testing.expect_value(t, first.leaf.cwd, "./web")

	second := layout.root.split.second
	testing.expect(t, second != nil && !second.is_split, "second must be leaf")
	testing.expect_value(t, second.leaf.command, "cargo check")
	testing.expect_value(t, second.leaf.cwd, "./core")
}

@(test)
test_persistence_save_tab_odin :: proc(t: ^testing.T) {
	var_tab := new(app.Tab_Session)
	defer {
		app.pane_tree_destroy(&var_tab.tree)
		free(var_tab)
	}
	var_tab.id = 1
	var_tab.tree.root = nil
	var_tab.backend.cwd = strings.clone(".")
	defer delete(var_tab.backend.cwd)
	_ = app.pane_tree_init(&var_tab.tree, &var_tab.backend)

	// Split root
	b2 := new(app.Backend)
	defer free(b2)
	b2.cwd = strings.clone(".")
	defer delete(b2.cwd)
	_, ok_split := app.pane_tree_split(&var_tab.tree, var_tab.tree.root.id, .Vertical, b2)
	testing.expect(t, ok_split, "pane_tree_split must succeed")

	tmp_save_path := "/tmp/test_saved_layout.odin"
	defer os.remove(tmp_save_path)

	saved_ok := app.persistence_save_tab_odin(var_tab, tmp_save_path, "saved_test")
	testing.expect(t, saved_ok, "persistence_save_tab_odin must succeed")

	// Read and parse saved file
	data, rerr := os.read_entire_file(tmp_save_path, context.allocator)
	testing.expect(t, rerr == nil, "saved file must be readable")
	defer delete(data)

	loaded_layout, pok, err_msg := app.parse_layout_odin(string(data), tmp_save_path)
	defer app.persistence_free_layout(&loaded_layout)

	testing.expect(t, pok, fmt.tprintf("loaded layout parse error: %s", err_msg))
	testing.expect_value(t, loaded_layout.name, "saved_test")
	testing.expect(t, loaded_layout.root != nil, "loaded root must not be nil")
	testing.expect(t, loaded_layout.root.is_split, "loaded root must be split")
	testing.expect_value(t, loaded_layout.root.split.direction, app.Split_Direction.Vertical)
}
