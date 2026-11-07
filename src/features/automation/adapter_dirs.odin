package feature_automation

// Where `require "term.adapter.<name>"` looks, first match wins: the project
// (./.term/adapters), then the user (~/.config/term/adapters, or
// $XDG_CONFIG_HOME/term/adapters).

import "core:os"
import "core:path/filepath"

adapter_dirs :: proc(allocator := context.temp_allocator) -> []string {
	dirs := make([dynamic]string, 0, 2, allocator)
	append(&dirs, filepath.join({".term", "adapters"}, allocator) or_else "")
	if config := os.get_env("XDG_CONFIG_HOME", allocator); len(config) > 0 {
		append(&dirs, filepath.join({config, "term", "adapters"}, allocator) or_else "")
	} else if home := os.get_env("HOME", allocator); len(home) > 0 {
		append(&dirs, filepath.join({home, ".config", "term", "adapters"}, allocator) or_else "")
	}
	return dirs[:]
}
