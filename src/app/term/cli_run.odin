package term

// CLI entrypoint for `term run <script.lua> [args...]`.

import "core:fmt"
import scripting "../../features/scripting"

app_cli_run :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.println("usage: term run <script.lua> [args...]")
		return 0
	}
	script_path := args[0]
	script_args := args[1:]
	return scripting.run_script(script_path, script_args)
}
