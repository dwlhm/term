package term

// Default configuration template and auto-generation.
// When Term starts without an existing configuration file, it generates
// ~/.config/term/config.json5 (or $XDG_CONFIG_HOME/term/config.json5)
// to provide a discoverable, well-commented starting point.

import "core:os"
import "core:strings"

DEFAULT_CONFIG_JSON5: string : `// Term Configuration (JSON5)
// Documentation: https://github.com/dewala/term
{
  // Window dimensions and native appearance
  window: {
    width: 1280,
    height: 800,
    blur: true,          // macOS vibrancy background blur (default: true on macOS)
    opacity: -1.0,       // Window background opacity (-1.0 = follow system blur)
  },

  // Terminal pane visual options
  pane: {
    opacity: 0.45,       // Pane background opacity (0.0 = fully transparent, 1.0 = solid)
  },

  // Typography settings
  font: {
    size: 13.0,          // Font size in points (default: 13.0)
    family: "",          // Font family name (leave empty for system monospace)
  },

  // Terminal grid internal padding (in points)
  padding: {
    x: 4.0,
    y: 4.0,
  },

  // Scroll multiplier for mouse wheel and trackpad gestures
  scroll_speed: 1.0,

  // Tactile 3D fluid water ripple simulation on file drag & drop
  drop: {
    animation: false,
  },

  // Optional theme overrides (hex color strings)
  // theme: {
  //   background: "#1e1e2e",
  //   foreground: "#cdd6f4",
  // },
}
`

// config_ensure_default_file creates ~/.config/term/config.json5 (or
// $XDG_CONFIG_HOME/term/config.json5) if no config exists.
// Returns the absolute file path and true on success, or ("", false) if cannot write.
config_ensure_default_file :: proc(target_dir: string = "", allocator := context.temp_allocator) -> (path: string, created: bool) {
	dir := target_dir
	if len(dir) == 0 {
		if xdg := os.get_env("XDG_CONFIG_HOME", allocator); len(xdg) > 0 {
			dir = strings.concatenate({xdg, "/term"}, allocator)
		} else if home := os.get_env("HOME", allocator); len(home) > 0 {
			dir = strings.concatenate({home, "/.config/term"}, allocator)
		} else {
			return "", false
		}
	}

	if !os.is_dir(dir) {
		if os.make_directory_all(dir) != nil {
			return "", false
		}
	}

	file_path := strings.concatenate({dir, "/config.json5"}, allocator)
	if os.is_file(file_path) {
		return file_path, true
	}

	if os.write_entire_file(file_path, DEFAULT_CONFIG_JSON5) != nil {
		return "", false
	}

	return file_path, true
}
