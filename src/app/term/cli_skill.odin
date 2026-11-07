package term

import "core:fmt"
import "core:os"
import "core:path/filepath"

Agent_Host :: struct {
	name:        string,
	detect_dir:  string,
	skills_path: string,
}

@(private = "file")
AGENT_HOSTS := []Agent_Host{
	{"Gemini CLI / AGY", ".gemini", ".gemini/config/skills/term"},
	{"Claude Code",      ".claude", ".claude/skills/term"},
	{"Codex",            ".codex",  ".codex/skills/term"},
	{"OpenCode",         ".config/opencode", ".config/opencode/skills/term"},
	{"Pi Agent",         ".pi",     ".pi/agent/skills/term"},
	{"Global AI Skills", ".config/ai", ".config/ai/skills/term"},
	{"Agents Standard",  ".agents", ".agents/skills/term"},
}

app_cli_skill :: proc(args: []string) -> int {
	if len(args) == 0 do return _skill_usage()
	switch args[0] {
	case "setup", "install", "enable": return app_cli_skill_setup()
	case "status":                     return app_cli_skill_status()
	case "show":                       return app_cli_skill_show()
	case "remove", "disable":          return app_cli_skill_remove()
	case "--help", "-h", "help":       return _skill_usage()
	case:                              return _skill_usage()
	}
}

app_cli_skill_setup :: proc() -> int {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 do return 1
	fmt.println("Configuring term skill for local AI agents...")
	count := 0
	for h in AGENT_HOSTS {
		detect_full, _ := filepath.join({home, h.detect_dir}, context.temp_allocator)
		if !os.exists(detect_full) do continue
		skill_dir, _ := filepath.join({home, h.skills_path}, context.temp_allocator)
		_ = os.make_directory(skill_dir)
		skill_file, _ := filepath.join({skill_dir, "SKILL.md"}, context.temp_allocator)
		if os.write_entire_file(skill_file, TERM_SKILL_CONTENT) == nil {
			fmt.printfln("  ✔ %-20s -> ~/%s/SKILL.md", h.name, h.skills_path)
			count += 1
		}
	}
	_ensure_local_bin_symlink(home)
	fmt.printfln("Setup complete: %d agent host(s) updated.", count)
	return 0
}

app_cli_skill_status :: proc() -> int {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 do return 1
	fmt.println("Term Agent Skill Status:")
	for h in AGENT_HOSTS {
		detect_full, _ := filepath.join({home, h.detect_dir}, context.temp_allocator)
		if !os.exists(detect_full) {
			fmt.printfln("  - %-20s [host not detected]", h.name)
			continue
		}
		switch _skill_state(home, h) {
		case .Current:  fmt.printfln("  ✔ %-20s [installed: ~/%s/SKILL.md]", h.name, h.skills_path)
		case .Outdated: fmt.printfln("  ! %-20s [outdated: run term skill setup]", h.name)
		case .Missing:  fmt.printfln("  ! %-20s [host active, skill missing]", h.name)
		}
	}
	bin_path, _ := filepath.join({home, ".local/bin/term"}, context.temp_allocator)
	if os.exists(bin_path) {
		fmt.printfln("  ✔ %-20s [installed: %s]", "CLI Binary", bin_path)
	} else {
		fmt.printfln("  ! %-20s [missing: ~/.local/bin/term]", "CLI Binary")
	}
	return 0
}

app_cli_skill_show :: proc() -> int {
	fmt.println(TERM_SKILL_CONTENT)
	return 0
}

app_cli_skill_remove :: proc() -> int {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) == 0 do return 1
	fmt.println("Removing term skill from local AI agents...")
	for h in AGENT_HOSTS {
		skill_file, _ := filepath.join({home, h.skills_path, "SKILL.md"}, context.temp_allocator)
		if os.exists(skill_file) {
			_ = os.remove(skill_file)
			fmt.printfln("  ✔ Removed ~/%s/SKILL.md", h.skills_path)
		}
	}
	return 0
}

Skill_State :: enum { Missing, Current, Outdated }

@(private = "file")
_skill_state :: proc(home: string, h: Agent_Host) -> Skill_State {
	skill_file, _ := filepath.join({home, h.skills_path, "SKILL.md"}, context.temp_allocator)
	data, err := os.read_entire_file(skill_file, context.temp_allocator)
	if err != nil do return .Missing
	return .Current if string(data) == TERM_SKILL_CONTENT else .Outdated
}

// app_skill_refresh rewrites installed skills that an older build wrote
// (a removed skill stays removed).
app_skill_refresh :: proc(home: string) {
	for h in AGENT_HOSTS {
		if _skill_state(home, h) != .Outdated do continue
		skill_file, _ := filepath.join({home, h.skills_path, "SKILL.md"}, context.temp_allocator)
		_ = os.write_entire_file(skill_file, TERM_SKILL_CONTENT)
	}
}

@(private = "file")
_ensure_local_bin_symlink :: proc(home: string) {
	local_bin, _ := filepath.join({home, ".local/bin"}, context.temp_allocator)
	_ = os.make_directory(local_bin)
	target_symlink, _ := filepath.join({local_bin, "term"}, context.temp_allocator)

	src := os.args[0]
	if !filepath.is_abs(src) {
		cwd := app_get_process_cwd(context.temp_allocator)
		joined, _ := filepath.join({cwd, src}, context.temp_allocator)
		src, _ = filepath.clean(joined, context.temp_allocator)
	}
	_ = os.remove(target_symlink)
	if os.symlink(src, target_symlink) == os.ERROR_NONE {
		fmt.printfln("  ✔ Created CLI symlink -> %s", target_symlink)
	}
}

@(private = "file")
_skill_usage :: proc() -> int {
	fmt.println("usage: term skill <setup | status | show | remove>")
	fmt.println()
	fmt.println("Manage AI agent skill integration for term:")
	fmt.println("  setup     Scan machine and install term skill to all detected AI agents")
	fmt.println("  status    Show active agent hosts and skill installation status")
	fmt.println("  show      Print bundled SKILL.md specification to stdout")
	fmt.println("  remove    Uninstall term skill from all detected AI agents")
	return 1
}
