package term

import "core:os"
import "core:path/filepath"

// app_onboarding_check runs on every GUI launch. First launch (no
// ~/.local/bin/term): install the CLI link and the agent skill everywhere.
// Later launches only refresh skills an older build installed.
app_onboarding_check :: proc(app: ^Term_App) {
	if app == nil do return
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 do return

	bin_path, _ := filepath.join({home, ".local/bin/term"}, context.temp_allocator)
	if !os.exists(bin_path) do _ = app_cli_skill_setup()
	else do app_skill_refresh(home)
}
