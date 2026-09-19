package config

import "core:fmt"
import "core:os"
import "core:strings"

// config_resolve_path checks config candidate locations in order:
// 1. $TERM_CONFIG (if set and file exists)
// 2. ~/.config/term/config.odin (if file exists)
// Returns the resolved path and true, or empty string and false if not found.
// The returned string is heap-allocated and caller-owned if ok is true.
config_resolve_path :: proc() -> (string, bool) {
	// (1) $TERM_CONFIG
	if val, found := os.lookup_env("TERM_CONFIG", context.allocator); found {
		if len(val) > 0 && os.exists(val) {
			return val, true
		}
		delete(val)
	}

	// (2) ~/.config/term/config.odin
	if home, hok := os.lookup_env("HOME", context.allocator); hok {
		if len(home) > 0 {
			path := strings.concatenate({home, "/.config/term/config.odin"}, context.allocator)
			delete(home)
			if os.exists(path) {
				return path, true
			}
			delete(path)
		} else {
			delete(home)
		}
	}

	return "", false
}

// config_load locates and loads configuration from disk.
// Returns (Config, ok).
// - If no config file is found, silently returns (config_default(), true).
// - If reading fails or syntax error occurs, logs a warning and returns (config_default(), false).
config_load :: proc() -> (Config, bool) {
	path, found := config_resolve_path()
	if !found {
		// Silent fallback when config file doesn't exist
		return config_default(), true
	}
	defer delete(path)

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintf("[term] Warning: failed to read config file '%s'\n", path)
		return Config{}, false
	}
	defer delete(data)

	cfg, ok, parse_err := parse_config(string(data), path)
	if !ok {
		fmt.eprintf(
			"[term] Config syntax error at %s:%d:%d: %s\n",
			path,
			parse_err.line,
			parse_err.col,
			parse_err.message,
		)
		delete(parse_err.message)
		config_destroy(&cfg)
		return Config{}, false
	}

	return cfg, true
}
