package pty

import "core:strings"
import "core:sync"

// ============================================================================
// 1. Shell Launch Types & Descriptors
// ============================================================================

// Shell_Launch_Mode indicates whether a shell is spawned for an interactive session
// or a headless command/test context.
Shell_Launch_Mode :: enum u8 {
	Interactive,
	Headless,
}

// Shell_Family identifies the canonical shell flavor.
Shell_Family :: enum u8 {
	Unknown,
	Zsh,
	Bash,
	Fish,
	Nushell,
	Posix_Sh,
}

// Shell_Descriptor holds launch arguments for a specific shell family or name.
Shell_Descriptor :: struct {
	name:             string,
	family:           Shell_Family,
	interactive_argv: []string,
	headless_argv:    []string,
}

// SHELL_REGISTRY_MAX_CUSTOM is the maximum number of dynamically registered or patched shells.
SHELL_REGISTRY_MAX_CUSTOM :: 16

// ============================================================================
// 2. Default Shell Launch Flags (Why Each Flag Exists)
// ============================================================================
//
// - Login Shell Flag (`-l` or `--login`):
//   Terminal emulators launch shells as login shells. On macOS and Linux desktop
//   environments, GUI applications do not inherit user profile configurations.
//   Passing `-l` ensures the shell executes user login scripts (`.zprofile`,
//   `.bash_profile`, `config.fish`, `env.nu`), populating `$PATH` with package
//   managers (e.g. Homebrew at `/opt/homebrew/bin`, Cargo, Nix, pyenv). Without
//   this flag, standard developer tools are often missing from `$PATH`.
//
// - Unicode Combining Characters (`-o COMBINING_CHARS` for zsh):
//   By default, zsh may treat combining Unicode characters (accents, emojis,
//   zero-width joiners) as separate glyphs or miscalculate cursor advance width.
//   Enabling `COMBINING_CHARS` ensures zsh groups base characters and modifiers
//   into single visual cells matching terminal grid geometry.
//
// - Headless Isolation Flags (`--no-rcs`, `--norc`, `--no-config`):
//   In headless mode (used for benchmarks, headless PTY testing, and CI), user
//   dotfiles can cause unpredictable delays, interactive prompts, or aliases
//   that break automation. These flags suppress startup configs for deterministic,
//   reproducible execution.

@(private="file")
_ARGV_ZSH_INTERACTIVE := []string{"-l", "-o", "COMBINING_CHARS"}
@(private="file")
_ARGV_ZSH_HEADLESS := []string{"--no-rcs"}
@(private="file")
_ARGV_BASH_INTERACTIVE := []string{"-l"}
@(private="file")
_ARGV_BASH_HEADLESS := []string{"--norc", "--noprofile"}
@(private="file")
_ARGV_FISH_INTERACTIVE := []string{"-l"}
@(private="file")
_ARGV_FISH_HEADLESS := []string{"--no-config"}
@(private="file")
_ARGV_NUSHELL_INTERACTIVE := []string{"--login"}
@(private="file")
_ARGV_NUSHELL_HEADLESS := []string{"--no-config-file"}
@(private="file")
_ARGV_POSIX_SH_INTERACTIVE := []string{"-l"}
@(private="file")
_ARGV_POSIX_SH_HEADLESS := []string{}
@(private="file")
_ARGV_FALLBACK_INTERACTIVE := []string{"-l"}
@(private="file")
_ARGV_FALLBACK_HEADLESS := []string{}

// ============================================================================
// 3. Static Built-in Descriptors
// ============================================================================

// Static/built-in descriptors for known shell families.
SHELL_DESCRIPTOR_ZSH := Shell_Descriptor{
	name             = "zsh",
	family           = .Zsh,
	interactive_argv = _ARGV_ZSH_INTERACTIVE,
	headless_argv    = _ARGV_ZSH_HEADLESS,
}

SHELL_DESCRIPTOR_BASH := Shell_Descriptor{
	name             = "bash",
	family           = .Bash,
	interactive_argv = _ARGV_BASH_INTERACTIVE,
	headless_argv    = _ARGV_BASH_HEADLESS,
}

SHELL_DESCRIPTOR_FISH := Shell_Descriptor{
	name             = "fish",
	family           = .Fish,
	interactive_argv = _ARGV_FISH_INTERACTIVE,
	headless_argv    = _ARGV_FISH_HEADLESS,
}

SHELL_DESCRIPTOR_NUSHELL := Shell_Descriptor{
	name             = "nu",
	family           = .Nushell,
	interactive_argv = _ARGV_NUSHELL_INTERACTIVE,
	headless_argv    = _ARGV_NUSHELL_HEADLESS,
}

SHELL_DESCRIPTOR_POSIX_SH := Shell_Descriptor{
	name             = "sh",
	family           = .Posix_Sh,
	interactive_argv = _ARGV_POSIX_SH_INTERACTIVE,
	headless_argv    = _ARGV_POSIX_SH_HEADLESS,
}

SHELL_DESCRIPTOR_FALLBACK := Shell_Descriptor{
	name             = "unknown",
	family           = .Unknown,
	interactive_argv = _ARGV_FALLBACK_INTERACTIVE,
	headless_argv    = _ARGV_FALLBACK_HEADLESS,
}

// ============================================================================
// 4. Dynamic Custom Shell Registry
// ============================================================================
//
// How to Register or Patch Custom Shells in 3 Easy Steps:
//
// 1. Identify the shell binary or alias:
//    Choose the lookup name (e.g., "xonsh", "elvish", or "my-shell").
//
// 2. Specify interactive and headless argument slices:
//    Choose argv for user sessions (e.g., `[]string{"-l"}`) and headless
//    contexts (e.g., `[]string{"--no-rc"}`).
//
// 3. Register the descriptor:
//    Call `pty.shell_registry_register("xonsh", interactive_argv, headless_argv)`.
//    Registered descriptors take precedence during `shell_resolve_argv`.

@(private="file")
_custom_registry: [SHELL_REGISTRY_MAX_CUSTOM]Shell_Descriptor

@(private="file")
_custom_count: int

@(private="file")
_registry_mutex: sync.Mutex

// ============================================================================
// 5. Path Parsing & Family Detection
// ============================================================================

// shell_basename extracts the executable name from prog_path, stripping directory
// prefixes, login shell leading dashes, and Windows .exe suffixes.
shell_basename :: proc(path: string) -> string {
	trimmed := strings.trim_space(path)
	trimmed = strings.trim_right(trimmed, "/\\")
	if len(trimmed) == 0 {
		return ""
	}
	idx := -1
	for i := len(trimmed) - 1; i >= 0; i -= 1 {
		if trimmed[i] == '/' || trimmed[i] == '\\' {
			idx = i
			break
		}
	}
	name := trimmed
	if idx >= 0 && idx + 1 < len(trimmed) {
		name = trimmed[idx + 1:]
	}
	for len(name) > 0 && name[0] == '-' {
		name = name[1:]
	}
	if strings.has_suffix(name, ".exe") {
		name = name[:len(name) - 4]
	}
	return name
}

// shell_detect_family detects the shell family based on the basename of prog_path.
shell_detect_family :: proc(prog_path: string) -> Shell_Family {
	name := shell_basename(prog_path)
	if len(name) == 0 {
		return .Unknown
	}

	if strings.equal_fold(name, "zsh") || strings.has_prefix(name, "zsh-") {
		return .Zsh
	}
	if strings.equal_fold(name, "bash") || strings.has_prefix(name, "bash-") {
		return .Bash
	}
	if strings.equal_fold(name, "fish") {
		return .Fish
	}
	if strings.equal_fold(name, "nu") || strings.equal_fold(name, "nushell") {
		return .Nushell
	}
	if strings.equal_fold(name, "sh") || strings.equal_fold(name, "dash") || strings.equal_fold(name, "ash") {
		return .Posix_Sh
	}

	return .Unknown
}

// shell_descriptor_for_family returns the static descriptor for the given shell family.
shell_descriptor_for_family :: proc(family: Shell_Family) -> Shell_Descriptor {
	switch family {
	case .Zsh:
		return SHELL_DESCRIPTOR_ZSH
	case .Bash:
		return SHELL_DESCRIPTOR_BASH
	case .Fish:
		return SHELL_DESCRIPTOR_FISH
	case .Nushell:
		return SHELL_DESCRIPTOR_NUSHELL
	case .Posix_Sh:
		return SHELL_DESCRIPTOR_POSIX_SH
	case .Unknown:
		return SHELL_DESCRIPTOR_FALLBACK
	}
	return SHELL_DESCRIPTOR_FALLBACK
}

// ============================================================================
// 6. Registry Operations & Resolution Helpers
// ============================================================================

// shell_registry_register registers or patches a shell descriptor in the dynamic pool.
// Returns true on success, false if the registry is full or override is false for an existing entry.
shell_registry_register :: proc(
	name:             string,
	interactive_argv: []string,
	headless_argv:    []string,
	override:         bool = true,
) -> bool {
	if len(name) == 0 {
		return false
	}

	sync.mutex_lock(&_registry_mutex)
	defer sync.mutex_unlock(&_registry_mutex)

	for i in 0 ..< _custom_count {
		if strings.equal_fold(_custom_registry[i].name, name) {
			if !override {
				return false
			}
			_custom_registry[i].family = shell_detect_family(name)
			_custom_registry[i].interactive_argv = interactive_argv
			_custom_registry[i].headless_argv = headless_argv
			return true
		}
	}

	if _custom_count >= SHELL_REGISTRY_MAX_CUSTOM {
		return false
	}

	_custom_registry[_custom_count] = Shell_Descriptor{
		name             = name,
		family           = shell_detect_family(name),
		interactive_argv = interactive_argv,
		headless_argv    = headless_argv,
	}
	_custom_count += 1
	return true
}

// shell_registry_patch is an alias for shell_registry_register.
shell_registry_patch :: proc(
	name:             string,
	interactive_argv: []string,
	headless_argv:    []string,
	override:         bool = true,
) -> bool {
	return shell_registry_register(name, interactive_argv, headless_argv, override)
}

// shell_registry_reset clears all dynamically registered custom shells.
shell_registry_reset :: proc() {
	sync.mutex_lock(&_registry_mutex)
	defer sync.mutex_unlock(&_registry_mutex)
	_custom_count = 0
}

// shell_registry_clear is an alias for shell_registry_reset.
shell_registry_clear :: shell_registry_reset

// _find_custom_descriptor searches the dynamic custom registry for an entry matching
// either the full program path or the basename. Thread-safe under _registry_mutex.
@(private="file")
_find_custom_descriptor :: proc(name: string, base: string) -> (desc: Shell_Descriptor, found: bool) {
	sync.mutex_lock(&_registry_mutex)
	defer sync.mutex_unlock(&_registry_mutex)

	for i in 0 ..< _custom_count {
		entry := _custom_registry[i]
		if strings.equal_fold(entry.name, name) || (len(base) > 0 && strings.equal_fold(entry.name, base)) {
			return entry, true
		}
	}
	return {}, false
}

// shell_resolve_argv resolves the appropriate argv for spawning a shell.
// If explicit_argv is non-empty, it takes precedence over all registry lookups.
// Otherwise, custom patches are checked first, then built-in family, then fallback.
shell_resolve_argv :: proc(
	prog_path:     string,
	mode:          Shell_Launch_Mode,
	explicit_argv: []string = nil,
) -> []string {
	if len(explicit_argv) > 0 {
		return explicit_argv
	}

	base := shell_basename(prog_path)

	// Check custom patches first
	if custom, found := _find_custom_descriptor(prog_path, base); found {
		switch mode {
		case .Interactive:
			return custom.interactive_argv
		case .Headless:
			return custom.headless_argv
		}
	}

	// Built-in family fallback
	family := shell_detect_family(prog_path)
	desc := shell_descriptor_for_family(family)
	switch mode {
	case .Interactive:
		return desc.interactive_argv
	case .Headless:
		return desc.headless_argv
	}
	return desc.interactive_argv
}
