package config

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import odin_ast "core:odin/ast"
import odin_parser "core:odin/parser"
import odin_tok "core:odin/tokenizer"
import termgrid "../terminal"

// Config_Parse_Error contains error location and diagnostic message.
Config_Parse_Error :: struct {
	line:    int,
	col:     int,
	message: string,
}

@(private="file")
@(thread_local)
_captured_error: Config_Parse_Error

@(private="file")
_config_parse_error_handler :: proc(pos: odin_tok.Pos, format: string, args: ..any) {
	if _captured_error.message == "" {
		_captured_error.line = max(1, pos.line - 2)
		_captured_error.col = pos.column
		_captured_error.message = fmt.aprintf(format, ..args)
	}
}

// parse_config parses Odin configuration syntax from source.
// Returns the resulting Config, success boolean, and error diagnostic on failure.
parse_config :: proc(source: string, file_path: string = "") -> (Config, bool, Config_Parse_Error) {
	trimmed := strings.trim_space(source)
	if len(trimmed) == 0 {
		return config_default(), true, Config_Parse_Error{}
	}

	arena: mem.Arena
	arena_buf := make([]u8, 512 * 1024)
	defer delete(arena_buf)
	mem.arena_init(&arena, arena_buf)

	wrapped := strings.concatenate({
		"package config\n_term_cfg :: proc() {\n",
		source,
		"\n}\n",
	}, context.temp_allocator)

	file := odin_ast.File{
		src      = wrapped,
		fullpath = file_path if len(file_path) > 0 else "config.odin",
	}

	p := odin_parser.default_parser()
	_captured_error = Config_Parse_Error{}
	p.err = _config_parse_error_handler
	p.warn = nil

	parse_ok: bool
	{
		old_context := context
		context.allocator = mem.arena_allocator(&arena)
		parse_ok = odin_parser.parse_file(&p, &file)
		context = old_context
	}

	if !parse_ok || file.syntax_error_count > 0 {
		err := _captured_error
		if err.message == "" {
			err.line = 1
			err.col = 1
			err.message = strings.clone("syntax error")
		} else {
			err.message = strings.clone(err.message)
		}
		return Config{}, false, err
	}

	cfg := config_default()

	for decl in file.decls {
		value_decl, is_vd := decl.derived.(^odin_ast.Value_Decl)
		if !is_vd {
			continue
		}
		for val in value_decl.values {
			proc_lit, is_proc := val.derived.(^odin_ast.Proc_Lit)
			if !is_proc || proc_lit.body == nil {
				continue
			}
			block, is_block := proc_lit.body.derived.(^odin_ast.Block_Stmt)
			if !is_block {
				continue
			}
			for stmt in block.stmts {
				#partial switch s in stmt.derived {
				case ^odin_ast.Assign_Stmt:
					if len(s.lhs) > 0 && len(s.rhs) > 0 {
						if ident, ok := s.lhs[0].derived.(^odin_ast.Ident); ok {
							_apply_key_value(&cfg, ident.name, s.rhs[0])
						}
					}
				case ^odin_ast.Value_Decl:
					if len(s.names) > 0 && len(s.values) > 0 {
						if ident, ok := s.names[0].derived.(^odin_ast.Ident); ok {
							_apply_key_value(&cfg, ident.name, s.values[0])
						}
					}
				}
			}
		}
	}

	return cfg, true, Config_Parse_Error{}
}

@(private="file")
_expr_to_string :: proc(expr: ^odin_ast.Expr) -> (string, bool) {
	if expr == nil {
		return "", false
	}
	#partial switch e in expr.derived {
	case ^odin_ast.Basic_Lit:
		if e.tok.kind == .String {
			text := e.tok.text
			if len(text) >= 2 {
				if (text[0] == '"' && text[len(text)-1] == '"') ||
				   (text[0] == '`' && text[len(text)-1] == '`') {
					return text[1:len(text)-1], true
				}
			}
			return text, true
		}
	case ^odin_ast.Ident:
		return e.name, true
	}
	return "", false
}

@(private="file")
_expr_to_lit_text :: proc(expr: ^odin_ast.Expr) -> (string, bool) {
	if expr == nil {
		return "", false
	}
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

@(private="file")
_parse_u32 :: proc(text: string) -> (u32, bool) {
	s := strings.trim_space(text)
	if strings.has_prefix(s, "#") {
		s = s[1:]
		val, ok := strconv.parse_u64_of_base(s, 16)
		if !ok {
			return 0, false
		}
		if len(s) <= 6 {
			return u32(val | 0xFF000000), true
		}
		return u32(val), true
	}
	val, ok := strconv.parse_u64(s)
	if !ok {
		return 0, false
	}
	if val <= 0x00FFFFFF {
		return u32(val | 0xFF000000), true
	}
	return u32(val), true
}

@(private="file")
_parse_f32 :: proc(text: string) -> (f32, bool) {
	s := strings.trim_space(text)
	val, ok := strconv.parse_f32(s)
	if ok {
		return val, true
	}
	ival, iok := strconv.parse_int(s)
	if iok {
		return f32(ival), true
	}
	return 0, false
}

@(private="file")
_parse_int :: proc(text: string) -> (int, bool) {
	s := strings.trim_space(text)
	val, ok := strconv.parse_int(s)
	if ok {
		return val, true
	}
	return 0, false
}

@(private="file")
_parse_bool :: proc(text: string) -> (bool, bool) {
	s := strings.trim_space(text)
	if s == "true" || s == "1" {
		return true, true
	}
	if s == "false" || s == "0" {
		return false, true
	}
	return false, false
}

@(private="file")
_apply_key_value :: proc(cfg: ^Config, key: string, val_expr: ^odin_ast.Expr) {
	switch key {
	case "cols", "window_cols":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v > 0 {
				cfg.cols = v
			}
		}
	case "rows", "window_rows":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v > 0 {
				cfg.rows = v
			}
		}
	case "title":
		if s, ok := _expr_to_string(val_expr); ok {
			delete(cfg.title)
			cfg.title = strings.clone(s)
		}
	case "font_family":
		if s, ok := _expr_to_string(val_expr); ok {
			delete(cfg.font_family)
			cfg.font_family = strings.clone(s)
		}
	case "font_size":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_f32(lit); vok && v > 0 {
				cfg.font_size = v
			}
		}
	case "shell":
		if s, ok := _expr_to_string(val_expr); ok {
			delete(cfg.shell)
			cfg.shell = strings.clone(s)
		}
	case "working_directory", "working_dir", "cwd", "initial_dir":
		if s, ok := _expr_to_string(val_expr); ok {
			delete(cfg.working_directory)
			cfg.working_directory = strings.clone(s)
		}
	case "locale":
		if s, ok := _expr_to_string(val_expr); ok {
			delete(cfg.locale)
			cfg.locale = strings.clone(s)
		}
	case "cursor_blink":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_bool(lit); vok {
				cfg.cursor_blink = v
			}
		}
	case "cursor_blink_interval_ms":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v > 0 {
				cfg.cursor_blink_interval_ms = u64(v)
			}
		}
	case "theme", "theme_name":
		if s, ok := _expr_to_string(val_expr); ok {
			delete(cfg.theme_name)
			cfg.theme_name = strings.clone(s)
			if strings.equal_fold(s, "catppuccin mocha") || strings.equal_fold(s, "catppuccin") {
				cfg.foreground = termgrid.CATPPUCCIN_MOCHA_TEXT
				cfg.background = termgrid.CATPPUCCIN_MOCHA_BASE
				cfg.selection_foreground = termgrid.CATPPUCCIN_MOCHA_BASE
				cfg.selection_background = termgrid.CATPPUCCIN_MOCHA_SURFACE2
				cfg.ansi16 = termgrid.THEME_CATPPUCCIN_MOCHA.ansi16
			}
		}
	case "foreground", "fg":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_u32(lit); vok {
				cfg.foreground = v
			}
		}
	case "background", "bg":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_u32(lit); vok {
				cfg.background = v
			}
		}
	case "selection_foreground", "selection_fg":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_u32(lit); vok {
				cfg.selection_foreground = v
			}
		}
	case "selection_background", "selection_bg":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_u32(lit); vok {
				cfg.selection_background = v
			}
		}
	case "cursor_color":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_u32(lit); vok {
				cfg.cursor_color = v
			}
		}
	case "scrollback_max_lines":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v >= 0 {
				cfg.scrollback_max_lines = v
			}
		}
	case "alt_screen_wheel_lines":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v > 0 {
				cfg.alt_screen_wheel_lines = v
			}
		}
	case "scroll_multiplier":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_f32(lit); vok && v > 0 {
				cfg.scroll_multiplier = v
			} else if vi, viok := _parse_int(lit); viok && vi > 0 {
				cfg.scroll_multiplier = f32(vi)
			}
		}
	case "padding_x":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v >= 0 {
				cfg.padding_x = v
			}
		}
	case "padding_y":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v >= 0 {
				cfg.padding_y = v
			}
		}
	case "tab_max_title_len", "tab_title_max_len":
		if lit, ok := _expr_to_lit_text(val_expr); ok {
			if v, vok := _parse_int(lit); vok && v > 0 {
				cfg.tab_max_title_len = v
			}
		}
	case "ansi16":
		if comp, ok := val_expr.derived.(^odin_ast.Comp_Lit); ok {
			for elem, idx in comp.elems {
				if idx >= 16 {
					break
				}
				if lit, lok := _expr_to_lit_text(elem); lok {
					if v, vok := _parse_u32(lit); vok {
						cfg.ansi16[idx] = v
					}
				}
			}
		}
	case:
		// Indexed colors: color0..color15, ansi0..ansi15, ansi16_0..ansi16_15
		idx := -1
		if strings.has_prefix(key, "color") {
			idx, _ = strconv.parse_int(key[5:])
		} else if strings.has_prefix(key, "ansi") {
			idx, _ = strconv.parse_int(key[4:])
		} else if strings.has_prefix(key, "ansi16_") {
			idx, _ = strconv.parse_int(key[7:])
		}
		if idx >= 0 && idx < 16 {
			if lit, ok := _expr_to_lit_text(val_expr); ok {
				if v, vok := _parse_u32(lit); vok {
					cfg.ansi16[idx] = v
				}
			}
		}
	}
}
