package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import odin_ast "core:odin/ast"
import odin_parser "core:odin/parser"
import odin_tok "core:odin/tokenizer"

DEFAULT_LAYOUT_NAME :: "default"

// Persisted_Pane_Leaf defines configuration for an individual terminal pane.
Persisted_Pane_Leaf :: struct {
	command:        string,
	cwd:            string,
	split_dir_hint: Split_Direction,
}

// Persisted_Pane_Split defines the binary division of a space.
Persisted_Pane_Split :: struct {
	direction: Split_Direction,
	ratio:     f32,
	first:     ^Persisted_Pane_Node,
	second:    ^Persisted_Pane_Node,
}

// Persisted_Pane_Node represents either a Split branch or a Leaf pane.
Persisted_Pane_Node :: struct {
	is_split: bool,
	split:    Persisted_Pane_Split,
	leaf:     Persisted_Pane_Leaf,
}

// Persisted_Layout represents a full multi-pane tab layout.
Persisted_Layout :: struct {
	name:        string,
	title:       string,
	cwd:         string,
	root:        ^Persisted_Pane_Node,
	source_file: string,
}

// persistence_expand_path expands '~' with $HOME, environment variables ($VAR / ${VAR}),
// and resolves relative paths against base_dir.
persistence_expand_path :: proc(raw_path: string, base_dir: string = ".") -> string {
	trimmed := strings.trim_space(raw_path)
	if len(trimmed) == 0 {
		return strings.clone(base_dir)
	}

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)

	// 1. Tilde expansion
	path_str := trimmed
	if trimmed == "~" {
		if home, hok := os.lookup_env("HOME", context.temp_allocator); hok {
			path_str = home
		}
	} else if strings.has_prefix(trimmed, "~/") {
		if home, hok := os.lookup_env("HOME", context.temp_allocator); hok {
			path_str = fmt.tprintf("%s%s", home, trimmed[1:])
		}
	}

	// 2. Environment variable interpolation ($VAR or ${VAR})
	i := 0
	for i < len(path_str) {
		if path_str[i] == '$' {
			i += 1
			var_name := ""
			if i < len(path_str) && path_str[i] == '{' {
				i += 1
				start := i
				for i < len(path_str) && path_str[i] != '}' {
					i += 1
				}
				var_name = path_str[start:i]
				if i < len(path_str) && path_str[i] == '}' {
					i += 1
				}
			} else {
				start := i
				for i < len(path_str) && ((path_str[i] >= 'A' && path_str[i] <= 'Z') ||
				                          (path_str[i] >= 'a' && path_str[i] <= 'z') ||
				                          (path_str[i] >= '0' && path_str[i] <= '9') ||
				                          path_str[i] == '_') {
					i += 1
				}
				var_name = path_str[start:i]
			}

			if val, found := os.lookup_env(var_name, context.temp_allocator); found {
				strings.write_string(&b, val)
			}
		} else {
			strings.write_byte(&b, path_str[i])
			i += 1
		}
	}

	expanded := strings.to_string(b)
	if !filepath.is_abs(expanded) && len(base_dir) > 0 {
		joined, _ := filepath.join({base_dir, expanded}, context.allocator)
		clean, _ := filepath.clean(joined, context.allocator)
		delete(joined)
		return clean
	}

	return strings.clone(expanded)
}

// persistence_resolve_layout_path locates the layout file across candidate locations.
persistence_resolve_layout_path :: proc(name: string) -> (path: string, ok: bool) {
	eff_name := name if len(name) > 0 else DEFAULT_LAYOUT_NAME

	// Candidate list ordered from project-local to global:
	candidates := make([dynamic]string, context.temp_allocator)

	// 1. Root dotfile: ./.<name>.term.odin
	append(&candidates, fmt.tprintf("./.%s.term.odin", eff_name))
	// 2. 1-level folder: ./.term/<name>.odin
	append(&candidates, fmt.tprintf("./.term/%s.odin", eff_name))
	// 3. Visible root file: ./<name>.term.odin
	append(&candidates, fmt.tprintf("./%s.term.odin", eff_name))

	// 4. $TERM_PERSISTENCE_DIR
	if env_dir, found := os.lookup_env("TERM_PERSISTENCE_DIR", context.temp_allocator); found && len(env_dir) > 0 {
		append(&candidates, fmt.tprintf("%s/%s.odin", env_dir, eff_name))
		append(&candidates, fmt.tprintf("%s/.%s.term.odin", env_dir, eff_name))
	}

	// 5. Global user config
	if home, hok := os.lookup_env("HOME", context.temp_allocator); hok && len(home) > 0 {
		append(&candidates, fmt.tprintf("%s/.config/term/%s.odin", home, eff_name))
		append(&candidates, fmt.tprintf("%s/.config/term/persistence/%s.odin", home, eff_name))
		append(&candidates, fmt.tprintf("%s/.config/term/.%s.term.odin", home, eff_name))
	}

	// JSON fallbacks
	append(&candidates, fmt.tprintf("./.%s.term.json", eff_name))
	append(&candidates, fmt.tprintf("./.term/%s.json", eff_name))
	append(&candidates, fmt.tprintf("./%s.term.json", eff_name))
	if env_dir, found := os.lookup_env("TERM_PERSISTENCE_DIR", context.temp_allocator); found && len(env_dir) > 0 {
		append(&candidates, fmt.tprintf("%s/%s.json", env_dir, eff_name))
	}
	if home, hok := os.lookup_env("HOME", context.temp_allocator); hok && len(home) > 0 {
		append(&candidates, fmt.tprintf("%s/.config/term/%s.json", home, eff_name))
		append(&candidates, fmt.tprintf("%s/.config/term/persistence/%s.json", home, eff_name))
	}

	for cand in candidates {
		if os.exists(cand) {
			return strings.clone(cand), true
		}
	}

	return "", false
}

// persistence_list_available discovers all unique layout names in project and config locations.
persistence_list_available :: proc() -> [dynamic]string {
	results := make([dynamic]string)

	_scan_dir :: proc(results: ^[dynamic]string, dir_path: string) {
		fd, err := os.open(dir_path)
		if err != nil do return
		defer os.close(fd)

		infos, read_err := os.read_dir(fd, -1, context.temp_allocator)
		if read_err != nil do return

		for fi in infos {
			full_path, _ := filepath.join({dir_path, fi.name}, context.temp_allocator)
			if os.is_dir(full_path) do continue
			name := fi.name
			layout_name := ""

			// Pattern 1: .<name>.term.odin or .<name>.term.json
			if strings.has_prefix(name, ".") && strings.contains(name, ".term.") {
				sub := name[1:]
				if idx := strings.index(sub, ".term."); idx > 0 {
					layout_name = sub[:idx]
				}
			} else if strings.has_suffix(name, ".term.odin") {
				layout_name = name[:len(name) - len(".term.odin")]
			} else if strings.has_suffix(name, ".term.json") {
				layout_name = name[:len(name) - len(".term.json")]
			} else if strings.has_suffix(name, ".odin") {
				layout_name = name[:len(name) - len(".odin")]
			} else if strings.has_suffix(name, ".json") {
				layout_name = name[:len(name) - len(".json")]
			}

			if len(layout_name) > 0 {
				already := false
				for r in results^ {
					if r == layout_name {
						already = true
						break
					}
				}
				if !already {
					append(results, strings.clone(layout_name))
				}
			}
		}
	}

	// 1. Current directory
	_scan_dir(&results, ".")
	// 2. ./.term directory
	_scan_dir(&results, "./.term")
	// 3. $TERM_PERSISTENCE_DIR
	if env_dir, found := os.lookup_env("TERM_PERSISTENCE_DIR", context.temp_allocator); found && len(env_dir) > 0 {
		_scan_dir(&results, env_dir)
	}
	// 4. ~/.config/term/persistence and ~/.config/term
	if home, hok := os.lookup_env("HOME", context.temp_allocator); hok && len(home) > 0 {
		_scan_dir(&results, fmt.tprintf("%s/.config/term/persistence", home))
		_scan_dir(&results, fmt.tprintf("%s/.config/term", home))
	}

	return results
}

// _free_persisted_node recursively frees node heap allocations.
_free_persisted_node :: proc(node: ^Persisted_Pane_Node) {
	if node == nil do return
	if node.is_split {
		_free_persisted_node(node.split.first)
		_free_persisted_node(node.split.second)
	} else {
		delete(node.leaf.command)
		delete(node.leaf.cwd)
	}
	free(node)
}

// persistence_free_layout releases all memory associated with a Persisted_Layout.
persistence_free_layout :: proc(layout: ^Persisted_Layout) {
	if layout == nil do return
	delete(layout.name)
	delete(layout.title)
	delete(layout.cwd)
	delete(layout.source_file)
	if layout.root != nil {
		_free_persisted_node(layout.root)
		layout.root = nil
	}
}

// _ast_expr_to_string extracts string value from Basic_Lit or Ident.
@(private="file")
_ast_expr_to_string :: proc(expr: ^odin_ast.Expr) -> (string, bool) {
	if expr == nil do return "", false
	#partial switch e in expr.derived {
	case ^odin_ast.Basic_Lit:
		text := e.tok.text
		if e.tok.kind == .String && len(text) >= 2 {
			if (text[0] == '"' && text[len(text)-1] == '"') ||
			   (text[0] == '`' && text[len(text)-1] == '`') {
				return text[1:len(text)-1], true
			}
		}
		return text, true
	case ^odin_ast.Ident:
		return e.name, true
	}
	return "", false
}

// _ast_expr_to_f32 extracts float value from Basic_Lit.
@(private="file")
_ast_expr_to_f32 :: proc(expr: ^odin_ast.Expr) -> (f32, bool) {
	if expr == nil do return 0, false
	#partial switch e in expr.derived {
	case ^odin_ast.Basic_Lit:
		if v, ok := strconv.parse_f32(e.tok.text); ok {
			return v, true
		}
		if iv, iok := strconv.parse_int(e.tok.text); iok {
			return f32(iv), true
		}
	}
	return 0, false
}

// _ast_expr_to_direction extracts Split_Direction from selector or ident.
@(private="file")
_ast_expr_to_direction :: proc(expr: ^odin_ast.Expr) -> (Split_Direction, bool) {
	if expr == nil do return .Vertical, false
	#partial switch e in expr.derived {
	case ^odin_ast.Implicit_Selector_Expr:
		if e.field != nil {
			name := strings.to_lower(e.field.name, context.temp_allocator)
			if name == "horizontal" || name == "h" do return .Horizontal, true
			if name == "vertical" || name == "v" do return .Vertical, true
		}
	case ^odin_ast.Ident:
		name := strings.to_lower(e.name, context.temp_allocator)
		if name == "horizontal" || name == "h" do return .Horizontal, true
		if name == "vertical" || name == "v" do return .Vertical, true
	case ^odin_ast.Selector_Expr:
		if e.field != nil {
			name := strings.to_lower(e.field.name, context.temp_allocator)
			if name == "horizontal" || name == "h" do return .Horizontal, true
			if name == "vertical" || name == "v" do return .Vertical, true
		}
	case ^odin_ast.Basic_Lit:
		if s, ok := _ast_expr_to_string(expr); ok {
			name := strings.to_lower(s, context.temp_allocator)
			if name == "horizontal" || name == "h" do return .Horizontal, true
			if name == "vertical" || name == "v" do return .Vertical, true
		}
	}
	return .Vertical, false
}

// _parse_ast_node recursively converts Odin AST Comp_Lit into Persisted_Pane_Node.
@(private="file")
_parse_ast_node :: proc(expr: ^odin_ast.Expr) -> (^Persisted_Pane_Node, bool) {
	if expr == nil do return nil, false

	comp_lit, is_cl := expr.derived.(^odin_ast.Comp_Lit)
	if !is_cl {
		return nil, false
	}

	type_name := ""
	if comp_lit.type != nil {
		if id, ok := comp_lit.type.derived.(^odin_ast.Ident); ok {
			type_name = id.name
		}
	}

	node := new(Persisted_Pane_Node)
	node.split.ratio = 0.5
	node.split.direction = .Vertical
	node.leaf.split_dir_hint = .Vertical

	is_explicit_split := (type_name == "Split")

	for elem in comp_lit.elems {
		fv, is_fv := elem.derived.(^odin_ast.Field_Value)
		if is_fv && fv.field != nil {
			field_id, fok := fv.field.derived.(^odin_ast.Ident)
			if fok {
				key := strings.to_lower(field_id.name, context.temp_allocator)
				switch key {
				case "direction", "dir":
					if dir, dok := _ast_expr_to_direction(fv.value); dok {
						node.split.direction = dir
						node.leaf.split_dir_hint = dir
					}
				case "ratio":
					if r, rok := _ast_expr_to_f32(fv.value); rok {
						node.split.ratio = r
					}
				case "command", "cmd", "run":
					if s, sok := _ast_expr_to_string(fv.value); sok {
						node.leaf.command = strings.clone(s)
					}
				case "cwd", "dir_path", "working_dir":
					if s, sok := _ast_expr_to_string(fv.value); sok {
						node.leaf.cwd = strings.clone(s)
					}
				case "split":
					if dir, dok := _ast_expr_to_direction(fv.value); dok {
						node.leaf.split_dir_hint = dir
						node.split.direction = dir
					}
				case "first":
					if child, cok := _parse_ast_node(fv.value); cok {
						node.split.first = child
						is_explicit_split = true
					}
				case "second":
					if child, cok := _parse_ast_node(fv.value); cok {
						node.split.second = child
						is_explicit_split = true
					}
				}
			}
		} else {
			// Positional values: first string is command, second is cwd
			if str, sok := _ast_expr_to_string(elem); sok {
				if len(node.leaf.command) == 0 {
					node.leaf.command = strings.clone(str)
				} else if len(node.leaf.cwd) == 0 {
					node.leaf.cwd = strings.clone(str)
				}
			}
		}
	}

	if is_explicit_split || node.split.first != nil || node.split.second != nil {
		node.is_split = true
	} else {
		node.is_split = false
	}

	return node, true
}

// _parse_ast_panes_list converts flat array of Pane { ... } into a balanced binary split tree.
@(private="file")
_parse_ast_panes_list :: proc(expr: ^odin_ast.Expr) -> (^Persisted_Pane_Node, bool) {
	comp_lit, is_cl := expr.derived.(^odin_ast.Comp_Lit)
	if !is_cl || len(comp_lit.elems) == 0 {
		return nil, false
	}

	leaves := make([dynamic]^Persisted_Pane_Node, context.temp_allocator)
	for elem in comp_lit.elems {
		if node, ok := _parse_ast_node(elem); ok {
			append(&leaves, node)
		}
	}

	if len(leaves) == 0 do return nil, false
	if len(leaves) == 1 do return leaves[0], true

	// Build binary tree sequentially:
	root := leaves[0]
	for i in 1 ..< len(leaves) {
		split_node := new(Persisted_Pane_Node)
		split_node.is_split = true
		split_node.split.direction = leaves[i].leaf.split_dir_hint
		split_node.split.ratio = 0.5
		split_node.split.first = root
		split_node.split.second = leaves[i]
		root = split_node
	}

	return root, true
}

// parse_layout_odin parses Odin layout configuration syntax.
parse_layout_odin :: proc(source: string, file_path: string = "") -> (layout: Persisted_Layout, ok: bool, err_msg: string) {
	trimmed := strings.trim_space(source)
	if len(trimmed) == 0 {
		return Persisted_Layout{}, false, "empty source"
	}

	arena: mem.Arena
	arena_buf := make([]u8, 512 * 1024)
	defer delete(arena_buf)
	mem.arena_init(&arena, arena_buf)

	wrapped := strings.concatenate({
		"package persistence\n_term_layout :: proc() {\n",
		source,
		"\n}\n",
	}, context.temp_allocator)

	file := odin_ast.File{
		src      = wrapped,
		fullpath = file_path if len(file_path) > 0 else "layout.odin",
	}

	p := odin_parser.default_parser()
	parse_ok: bool
	{
		old_context := context
		context.allocator = mem.arena_allocator(&arena)
		parse_ok = odin_parser.parse_file(&p, &file)
		context = old_context
	}

	if !parse_ok || file.syntax_error_count > 0 {
		return Persisted_Layout{}, false, "syntax error in layout odin file"
	}

	layout.name = strings.clone(DEFAULT_LAYOUT_NAME)
	layout.title = strings.clone("")
	layout.cwd = strings.clone(".")
	layout.source_file = strings.clone(file_path)

	for decl in file.decls {
		vd, is_vd := decl.derived.(^odin_ast.Value_Decl)
		if !is_vd do continue

		for val in vd.values {
			proc_lit, is_proc := val.derived.(^odin_ast.Proc_Lit)
			if !is_proc || proc_lit.body == nil do continue

			block, is_block := proc_lit.body.derived.(^odin_ast.Block_Stmt)
			if !is_block do continue

			for stmt in block.stmts {
				#partial switch s in stmt.derived {
				case ^odin_ast.Assign_Stmt:
					if len(s.lhs) > 0 && len(s.rhs) > 0 {
						if id, fok := s.lhs[0].derived.(^odin_ast.Ident); fok {
							k := strings.to_lower(id.name, context.temp_allocator)
							switch k {
							case "name":
								if str, sok := _ast_expr_to_string(s.rhs[0]); sok {
									delete(layout.name)
									layout.name = strings.clone(str)
								}
							case "title":
								if str, sok := _ast_expr_to_string(s.rhs[0]); sok {
									delete(layout.title)
									layout.title = strings.clone(str)
								}
							case "cwd":
								if str, sok := _ast_expr_to_string(s.rhs[0]); sok {
									delete(layout.cwd)
									layout.cwd = strings.clone(str)
								}
							case "layout":
								if node, nok := _parse_ast_node(s.rhs[0]); nok {
									layout.root = node
								}
							case "panes":
								if node, nok := _parse_ast_panes_list(s.rhs[0]); nok {
									layout.root = node
								}
							}
						}
					}
				case ^odin_ast.Value_Decl:
					if len(s.names) > 0 && len(s.values) > 0 {
						if id, fok := s.names[0].derived.(^odin_ast.Ident); fok {
							k := strings.to_lower(id.name, context.temp_allocator)
							switch k {
							case "name":
								if str, sok := _ast_expr_to_string(s.values[0]); sok {
									delete(layout.name)
									layout.name = strings.clone(str)
								}
							case "title":
								if str, sok := _ast_expr_to_string(s.values[0]); sok {
									delete(layout.title)
									layout.title = strings.clone(str)
								}
							case "cwd":
								if str, sok := _ast_expr_to_string(s.values[0]); sok {
									delete(layout.cwd)
									layout.cwd = strings.clone(str)
								}
							case "layout":
								if node, nok := _parse_ast_node(s.values[0]); nok {
									layout.root = node
								}
							case "panes":
								if node, nok := _parse_ast_panes_list(s.values[0]); nok {
									layout.root = node
								}
							}
						}
					}
				}
			}
		}
	}

	if layout.root == nil {
		persistence_free_layout(&layout)
		return Persisted_Layout{}, false, "missing layout or panes definition"
	}

	return layout, true, ""
}

// _parse_json_node recursively parses a JSON object into Persisted_Pane_Node.
@(private="file")
_parse_json_node :: proc(v: json.Value) -> (^Persisted_Pane_Node, bool) {
	obj, ok := v.(json.Object)
	if !ok do return nil, false

	node := new(Persisted_Pane_Node)
	node.split.ratio = 0.5
	node.split.direction = .Vertical
	node.leaf.split_dir_hint = .Vertical

	if cmd_v, cok := obj["command"]; cok {
		if s, is_str := cmd_v.(json.String); is_str {
			node.leaf.command = strings.clone(s)
		}
	} else if cmd_v2, cok2 := obj["cmd"]; cok2 {
		if s, is_str := cmd_v2.(json.String); is_str {
			node.leaf.command = strings.clone(s)
		}
	}

	if cwd_v, dok := obj["cwd"]; dok {
		if s, is_str := cwd_v.(json.String); is_str {
			node.leaf.cwd = strings.clone(s)
		}
	}

	is_split := false
	if dir_v, dirok := obj["direction"]; dirok {
		if s, is_str := dir_v.(json.String); is_str {
			dir_lower := strings.to_lower(s, context.temp_allocator)
			if dir_lower == "horizontal" || dir_lower == "h" {
				node.split.direction = .Horizontal
				node.leaf.split_dir_hint = .Horizontal
			} else {
				node.split.direction = .Vertical
				node.leaf.split_dir_hint = .Vertical
			}
			is_split = true
		}
	} else if split_v, sok := obj["split"]; sok {
		if s, is_str := split_v.(json.String); is_str {
			dir_lower := strings.to_lower(s, context.temp_allocator)
			if dir_lower == "horizontal" || dir_lower == "h" {
				node.split.direction = .Horizontal
				node.leaf.split_dir_hint = .Horizontal
			} else {
				node.split.direction = .Vertical
				node.leaf.split_dir_hint = .Vertical
			}
		}
	}

	if ratio_v, rok := obj["ratio"]; rok {
		if f, is_float := ratio_v.(json.Float); is_float {
			node.split.ratio = f32(f)
		} else if i, is_int := ratio_v.(json.Integer); is_int {
			node.split.ratio = f32(i)
		}
	}

	if first_v, fok := obj["first"]; fok {
		if first_node, f_ok := _parse_json_node(first_v); f_ok {
			node.split.first = first_node
			is_split = true
		}
	}

	if second_v, sok := obj["second"]; sok {
		if second_node, s_ok := _parse_json_node(second_v); s_ok {
			node.split.second = second_node
			is_split = true
		}
	}

	node.is_split = is_split
	return node, true
}

// parse_layout_json parses JSON layout configuration syntax.
parse_layout_json :: proc(source: string, file_path: string = "") -> (layout: Persisted_Layout, ok: bool) {
	parsed, err := json.parse_string(source, allocator = context.allocator)
	if err != nil do return Persisted_Layout{}, false
	defer json.destroy_value(parsed)

	root_obj, is_obj := parsed.(json.Object)
	if !is_obj do return Persisted_Layout{}, false

	layout.name = strings.clone(DEFAULT_LAYOUT_NAME)
	layout.title = strings.clone("")
	layout.cwd = strings.clone(".")
	layout.source_file = strings.clone(file_path)

	if nv, nok := root_obj["name"]; nok {
		if s, is_str := nv.(json.String); is_str {
			delete(layout.name)
			layout.name = strings.clone(s)
		}
	}
	if tv, tok := root_obj["title"]; tok {
		if s, is_str := tv.(json.String); is_str {
			delete(layout.title)
			layout.title = strings.clone(s)
		}
	}
	if cv, cok := root_obj["cwd"]; cok {
		if s, is_str := cv.(json.String); is_str {
			delete(layout.cwd)
			layout.cwd = strings.clone(s)
		}
	}

	if lv, lok := root_obj["layout"]; lok {
		if node, nok := _parse_json_node(lv); nok {
			layout.root = node
		}
	} else if pv, pok := root_obj["panes"]; pok {
		if arr, is_arr := pv.(json.Array); is_arr && len(arr) > 0 {
			leaves := make([dynamic]^Persisted_Pane_Node, context.temp_allocator)
			for item in arr {
				if node, nok := _parse_json_node(item); nok {
					append(&leaves, node)
				}
			}
			if len(leaves) == 1 {
				layout.root = leaves[0]
			} else if len(leaves) > 1 {
				tree_root := leaves[0]
				for i in 1 ..< len(leaves) {
					split_node := new(Persisted_Pane_Node)
					split_node.is_split = true
					split_node.split.direction = leaves[i].leaf.split_dir_hint
					split_node.split.ratio = 0.5
					split_node.split.first = tree_root
					split_node.split.second = leaves[i]
					tree_root = split_node
				}
				layout.root = tree_root
			}
		}
	}

	if layout.root == nil {
		persistence_free_layout(&layout)
		return Persisted_Layout{}, false
	}

	return layout, true
}

// persistence_load_layout resolves path, loads file, and parses layout.
persistence_load_layout :: proc(name: string = DEFAULT_LAYOUT_NAME) -> (layout: Persisted_Layout, ok: bool) {
	path, found := persistence_resolve_layout_path(name)
	if !found do return Persisted_Layout{}, false
	defer delete(path)

	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil do return Persisted_Layout{}, false
	defer delete(data)

	src := string(data)
	if strings.has_suffix(path, ".json") {
		return parse_layout_json(src, path)
	}

	parsed_layout, pok, _ := parse_layout_odin(src, path)
	return parsed_layout, pok
}

// _find_first_persisted_leaf locates the first leaf in depth-first order.
_find_first_persisted_leaf :: proc(node: ^Persisted_Pane_Node) -> ^Persisted_Pane_Leaf {
	if node == nil do return nil
	if !node.is_split do return &node.leaf
	if first := _find_first_persisted_leaf(node.split.first); first != nil do return first
	return _find_first_persisted_leaf(node.split.second)
}

// _reconstruct_node splits panes recursively matching the persisted layout tree.
_reconstruct_node :: proc(a: ^App, tab: ^Tab_Session, target_id: Pane_Id, node: ^Persisted_Pane_Node, base_dir: string) {
	if a == nil || tab == nil || node == nil || target_id == 0 do return

	if !node.is_split {
		// Terminal leaf: apply command if present
		target := pane_tree_find_pane(&tab.tree, target_id)
		if target != nil && target.backend != nil && len(node.leaf.command) > 0 {
			_ = _app_send_paste(target.backend, fmt.tprintf("%s\n", node.leaf.command))
		}
		return
	}

	// Split node: spawn backend for second branch
	second_leaf := _find_first_persisted_leaf(node.split.second)
	second_cwd := base_dir
	second_cwd_alloc := false
	if second_leaf != nil && len(second_leaf.cwd) > 0 {
		second_cwd = persistence_expand_path(second_leaf.cwd, base_dir)
		second_cwd_alloc = true
	}
	defer if second_cwd_alloc do delete(second_cwd)

	new_b := _app_spawn_pane_backend(a, 0, 0, second_cwd)
	if new_b == nil do return

	new_id, split_ok := pane_tree_split(&tab.tree, target_id, node.split.direction, new_b)
	if !split_ok || new_id == 0 {
		backend_destroy(new_b)
		free(new_b)
		return
	}

	// Configure split ratio
	first_child := pane_tree_find_pane(&tab.tree, target_id)
	if first_child != nil && first_child.parent != nil {
		first_child.parent.ratio = clamp(node.split.ratio, MIN_RATIO, MAX_RATIO)
	}

	// Recurse first and second children
	_reconstruct_node(a, tab, target_id, node.split.first, base_dir)
	_reconstruct_node(a, tab, new_id, node.split.second, base_dir)
}

// persistence_restore_tab creates a new tab divided into panes according to layout,
// starts backends in their respective directories, and dispatches initial commands.
persistence_restore_tab :: proc(a: ^App, layout: Persisted_Layout) -> (tab_idx: int, ok: bool) {
	if a != nil && a.frontend.use_pinnacle && layout.root != nil && layout.root.is_split {
		fmt.eprintln("layout restore rejected: experimental Pinnacle renderer supports one terminal")
		return -1, false
	}
	if a == nil || layout.root == nil do return -1, false

	base_dir := layout.cwd
	base_alloc := false
	if len(base_dir) == 0 {
		curr, err := os.get_working_directory(context.allocator)
		if err == nil {
			base_dir = curr
			base_alloc = true
		} else {
			base_dir = "."
		}
	}
	defer if base_alloc do delete(base_dir)

	expanded_base := persistence_expand_path(base_dir, ".")
	defer delete(expanded_base)

	first_leaf := _find_first_persisted_leaf(layout.root)
	root_cwd := expanded_base
	root_cwd_alloc := false
	if first_leaf != nil && len(first_leaf.cwd) > 0 {
		root_cwd = persistence_expand_path(first_leaf.cwd, expanded_base)
		root_cwd_alloc = true
	}
	defer if root_cwd_alloc do delete(root_cwd)

	shell, shell_allocated := _resolve_shell()
	defer if shell_allocated do delete(shell)
	shell_argv := _resolve_shell_argv(shell)

	rows := a.renderer.rows > 0 ? int(a.renderer.rows) : APP_DEFAULT_ROWS
	cols := a.renderer.cols > 0 ? int(a.renderer.cols) : APP_DEFAULT_COLS

	cfg_copy := a.config
	cfg_copy.working_directory = root_cwd

	new_idx, spawn_ok := session_spawn(&a.session_mgr, shell, shell_argv, rows, cols, &cfg_copy, a.renderer.theme)
	if !spawn_ok do return -1, false

	tab := &a.session_mgr.tabs[new_idx]
	if len(layout.title) > 0 {
		_ = session_set_title_override(tab, layout.title)
	}

	if layout.root.is_split {
		_reconstruct_node(a, tab, tab.tree.root.id, layout.root, expanded_base)
	} else if first_leaf != nil && len(first_leaf.command) > 0 {
		_ = _app_send_paste(&tab.backend, fmt.tprintf("%s\n", first_leaf.command))
	}

	_app_layout_ui(a)
	a.renderer.full_redraw_pending = true
	return new_idx, true
}

// _serialize_node_odin recursively prints Pane_Node into Odin DSL representation.
@(private="file")
_serialize_node_odin :: proc(b: ^strings.Builder, node: ^Pane_Node, indent: int) {
	if node == nil do return

	pad: [64]u8
	pad_len := min(indent * 4, len(pad))
	for i in 0 ..< pad_len do pad[i] = ' '
	p_str := string(pad[:pad_len])

	if node.kind == .Leaf {
		cwd_val := (node.backend != nil && len(node.backend.cwd) > 0) ? node.backend.cwd : "."
		strings.write_string(b, fmt.tprintf("Pane {{\n%s    cwd = \"%s\",\n%s}}", p_str, cwd_val, p_str))
	} else if node.kind == .Split {
		dir_str := ".Vertical" if node.direction == .Vertical else ".Horizontal"
		strings.write_string(b, fmt.tprintf("Split {{\n%s    direction = %s,\n%s    ratio = %.2f,\n%s    first = ", p_str, dir_str, p_str, node.ratio, p_str))
		_serialize_node_odin(b, node.first, indent + 1)
		strings.write_string(b, fmt.tprintf(",\n%s    second = ", p_str))
		_serialize_node_odin(b, node.second, indent + 1)
		strings.write_string(b, fmt.tprintf(",\n%s}}", p_str))
	}
}

// persistence_save_tab_odin serializes the active tab layout and panes to an Odin DSL file.
persistence_save_tab_odin :: proc(tab: ^Tab_Session, target_path: string, name: string = DEFAULT_LAYOUT_NAME) -> bool {
	if tab == nil || tab.tree.root == nil || len(target_path) == 0 do return false

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)

	title := session_title_display(tab)
	active_b := tab_active_backend(tab)
	root_cwd := active_b != nil ? active_b.cwd : "."

	strings.write_string(&b, fmt.tprintf("name = \"%s\"\n", name))
	strings.write_string(&b, fmt.tprintf("title = \"%s\"\n", title))
	strings.write_string(&b, fmt.tprintf("cwd = \"%s\"\n\n", root_cwd))
	strings.write_string(&b, "layout = ")
	_serialize_node_odin(&b, tab.tree.root, 0)
	strings.write_string(&b, "\n")

	payload := strings.to_string(b)
	err := os.write_entire_file(target_path, transmute([]u8)payload)
	return err == nil
}
