package app_test

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import app "../"

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
test_persistence_resolve_default_layout :: proc(t: ^testing.T) {
	// Create temporary .default.term.odin in current directory
	tmp_path := "./.default.term.odin"
	content := "name = \"default\"\ntitle = \"Default Layout\"\nlayout = Pane { command = \"echo hello\" }\n"
	write_err := os.write_entire_file(tmp_path, transmute([]u8)content)
	testing.expect(t, write_err == nil, "write temporary .default.term.odin must succeed")
	defer os.remove(tmp_path)

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
	tmp_path := "./.mycustom.term.odin"
	content := "name = \"mycustom\"\nlayout = Pane { command = \"echo custom\" }\n"
	write_err := os.write_entire_file(tmp_path, transmute([]u8)content)
	testing.expect(t, write_err == nil, "write temporary .mycustom.term.odin must succeed")
	defer os.remove(tmp_path)

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
