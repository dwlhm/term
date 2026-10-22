package term

// Unit Tests for Working Directory & Launcher Detection
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_config_expand_path :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)

	testing.expect_value(t, config_expand_path(""), "")
	if len(home) > 0 {
		testing.expect_value(t, config_expand_path("~"), home)
		testing.expect_value(t, config_expand_path("home"), home)
		expected_downloads := strings.concatenate({home, "/Downloads"}, context.temp_allocator)
		testing.expect_value(t, config_expand_path("~/Downloads"), expected_downloads)
	}
	testing.expect_value(t, config_expand_path("/tmp"), "/tmp")
	testing.expect_value(t, config_expand_path("/usr/local"), "/usr/local")
}

@(test)
test_config_resolve_working_directory :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)

	cfg_empty := App_Config{}
	testing.expect_value(t, config_resolve_working_directory(&cfg_empty), "")

	if len(home) > 0 {
		cfg_tilde := App_Config{working_directory = "~"}
		testing.expect_value(t, config_resolve_working_directory(&cfg_tilde), home)

		cfg_sub := App_Config{working_directory = "~/dev"}
		expected_dev := strings.concatenate({home, "/dev"}, context.temp_allocator)
		testing.expect_value(t, config_resolve_working_directory(&cfg_sub), expected_dev)
	}

	cfg_abs := App_Config{working_directory = "/var/log"}
	testing.expect_value(t, config_resolve_working_directory(&cfg_abs), "/var/log")
}

@(test)
test_app_resolve_initial_cwd_precedence :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)

	// 1. CLI override has highest priority
	cfg := App_Config{working_directory = "/from/config"}
	opts_cli := Cli_Options{working_dir_override = "/from/cli"}
	res_cli := app_resolve_initial_cwd(&cfg, opts_cli)
	testing.expect_value(t, res_cli, "/from/cli")

	// CLI override expanding tilde
	if len(home) > 0 {
		opts_tilde := Cli_Options{working_dir_override = "~/custom"}
		res_tilde := app_resolve_initial_cwd(&cfg, opts_tilde)
		expected_custom := strings.concatenate({home, "/custom"}, context.temp_allocator)
		testing.expect_value(t, res_tilde, expected_custom)
	}

	// 2. Config has second priority when no CLI override
	opts_empty := Cli_Options{}
	res_cfg := app_resolve_initial_cwd(&cfg, opts_empty)
	testing.expect_value(t, res_cfg, "/from/config")

	// 3. Fallback when neither CLI nor config is set
	cfg_none := App_Config{}
	res_fallback := app_resolve_initial_cwd(&cfg_none, opts_empty)
	testing.expect(t, len(res_fallback) > 0, "Expected non-empty fallback working directory")
	// Must NEVER be root "/"
	testing.expect(t, res_fallback != "/", "Startup directory must never be root '/'")
}
