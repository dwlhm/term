package pty_test

import "core:slice"
import "core:testing"
import pty "../"

@(test)
test_shell_detect_family :: proc(t: ^testing.T) {
	testing.expect_value(t, pty.shell_detect_family("/bin/zsh"), pty.Shell_Family.Zsh)
	testing.expect_value(t, pty.shell_detect_family("/opt/homebrew/bin/zsh"), pty.Shell_Family.Zsh)
	testing.expect_value(t, pty.shell_detect_family("-zsh"), pty.Shell_Family.Zsh)
	testing.expect_value(t, pty.shell_detect_family("zsh"), pty.Shell_Family.Zsh)
	testing.expect_value(t, pty.shell_detect_family("/bin/zsh-5.8"), pty.Shell_Family.Zsh)

	testing.expect_value(t, pty.shell_detect_family("/bin/bash"), pty.Shell_Family.Bash)
	testing.expect_value(t, pty.shell_detect_family("-bash"), pty.Shell_Family.Bash)
	testing.expect_value(t, pty.shell_detect_family("bash"), pty.Shell_Family.Bash)
	testing.expect_value(t, pty.shell_detect_family("/usr/local/bin/bash-5.2"), pty.Shell_Family.Bash)

	testing.expect_value(t, pty.shell_detect_family("/usr/local/bin/fish"), pty.Shell_Family.Fish)
	testing.expect_value(t, pty.shell_detect_family("fish"), pty.Shell_Family.Fish)

	testing.expect_value(t, pty.shell_detect_family("/usr/bin/nu"), pty.Shell_Family.Nushell)
	testing.expect_value(t, pty.shell_detect_family("/usr/local/bin/nushell"), pty.Shell_Family.Nushell)

	testing.expect_value(t, pty.shell_detect_family("/bin/sh"), pty.Shell_Family.Posix_Sh)
	testing.expect_value(t, pty.shell_detect_family("/bin/dash"), pty.Shell_Family.Posix_Sh)
	testing.expect_value(t, pty.shell_detect_family("/bin/ash"), pty.Shell_Family.Posix_Sh)

	testing.expect_value(t, pty.shell_detect_family(""), pty.Shell_Family.Unknown)
	testing.expect_value(t, pty.shell_detect_family("/usr/bin/python3"), pty.Shell_Family.Unknown)
	testing.expect_value(t, pty.shell_detect_family("custom_daemon"), pty.Shell_Family.Unknown)
}

@(test)
test_shell_builtin_descriptors :: proc(t: ^testing.T) {
	testing.expect_value(t, pty.SHELL_DESCRIPTOR_ZSH.family, pty.Shell_Family.Zsh)
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_ZSH.interactive_argv, []string{"-l", "-o", "COMBINING_CHARS"}))
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_ZSH.headless_argv, []string{"--no-rcs"}))

	testing.expect_value(t, pty.SHELL_DESCRIPTOR_BASH.family, pty.Shell_Family.Bash)
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_BASH.interactive_argv, []string{"-l"}))
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_BASH.headless_argv, []string{"--norc", "--noprofile"}))

	testing.expect_value(t, pty.SHELL_DESCRIPTOR_FISH.family, pty.Shell_Family.Fish)
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_FISH.interactive_argv, []string{"-l"}))
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_FISH.headless_argv, []string{"--no-config"}))

	testing.expect_value(t, pty.SHELL_DESCRIPTOR_NUSHELL.family, pty.Shell_Family.Nushell)
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_NUSHELL.interactive_argv, []string{"--login"}))
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_NUSHELL.headless_argv, []string{"--no-config-file"}))

	testing.expect_value(t, pty.SHELL_DESCRIPTOR_POSIX_SH.family, pty.Shell_Family.Posix_Sh)
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_POSIX_SH.interactive_argv, []string{"-l"}))
	testing.expect_value(t, len(pty.SHELL_DESCRIPTOR_POSIX_SH.headless_argv), 0)

	testing.expect_value(t, pty.SHELL_DESCRIPTOR_FALLBACK.family, pty.Shell_Family.Unknown)
	testing.expect(t, slice.equal(pty.SHELL_DESCRIPTOR_FALLBACK.interactive_argv, []string{"-l"}))
	testing.expect_value(t, len(pty.SHELL_DESCRIPTOR_FALLBACK.headless_argv), 0)
}

@(test)
test_shell_resolve_argv_builtins :: proc(t: ^testing.T) {
	pty.shell_registry_reset()
	defer pty.shell_registry_reset()

	// Zsh
	zsh_i := pty.shell_resolve_argv("/bin/zsh", .Interactive)
	testing.expect(t, slice.equal(zsh_i, []string{"-l", "-o", "COMBINING_CHARS"}))
	zsh_h := pty.shell_resolve_argv("/bin/zsh", .Headless)
	testing.expect(t, slice.equal(zsh_h, []string{"--no-rcs"}))

	// Bash
	bash_i := pty.shell_resolve_argv("/bin/bash", .Interactive)
	testing.expect(t, slice.equal(bash_i, []string{"-l"}))
	bash_h := pty.shell_resolve_argv("/bin/bash", .Headless)
	testing.expect(t, slice.equal(bash_h, []string{"--norc", "--noprofile"}))

	// Fish
	fish_i := pty.shell_resolve_argv("/usr/local/bin/fish", .Interactive)
	testing.expect(t, slice.equal(fish_i, []string{"-l"}))
	fish_h := pty.shell_resolve_argv("/usr/local/bin/fish", .Headless)
	testing.expect(t, slice.equal(fish_h, []string{"--no-config"}))

	// Nushell
	nu_i := pty.shell_resolve_argv("/opt/homebrew/bin/nu", .Interactive)
	testing.expect(t, slice.equal(nu_i, []string{"--login"}))
	nu_h := pty.shell_resolve_argv("/opt/homebrew/bin/nu", .Headless)
	testing.expect(t, slice.equal(nu_h, []string{"--no-config-file"}))

	// Posix Sh
	sh_i := pty.shell_resolve_argv("/bin/sh", .Interactive)
	testing.expect(t, slice.equal(sh_i, []string{"-l"}))
	sh_h := pty.shell_resolve_argv("/bin/sh", .Headless)
	testing.expect_value(t, len(sh_h), 0)

	// Fallback for unknown
	fallback_i := pty.shell_resolve_argv("/usr/bin/unknown_shell", .Interactive)
	testing.expect(t, slice.equal(fallback_i, []string{"-l"}))
	fallback_h := pty.shell_resolve_argv("/usr/bin/unknown_shell", .Headless)
	testing.expect_value(t, len(fallback_h), 0)
}

@(test)
test_shell_resolve_argv_explicit :: proc(t: ^testing.T) {
	pty.shell_registry_reset()
	defer pty.shell_registry_reset()

	explicit := []string{"-c", "echo hello"}
	resolved := pty.shell_resolve_argv("/bin/zsh", .Interactive, explicit)
	testing.expect(t, slice.equal(resolved, explicit))

	resolved_h := pty.shell_resolve_argv("/bin/bash", .Headless, explicit)
	testing.expect(t, slice.equal(resolved_h, explicit))
}

@(test)
test_shell_registry_patch_and_override :: proc(t: ^testing.T) {
	pty.shell_registry_reset()
	defer pty.shell_registry_reset()

	// Patch zsh with custom arguments
	ok := pty.shell_registry_register("zsh", {"-l", "--custom-interactive"}, {"--custom-headless"})
	testing.expect(t, ok)

	resolved_i := pty.shell_resolve_argv("/bin/zsh", .Interactive)
	testing.expect(t, slice.equal(resolved_i, []string{"-l", "--custom-interactive"}))

	resolved_h := pty.shell_resolve_argv("/opt/homebrew/bin/zsh", .Headless)
	testing.expect(t, slice.equal(resolved_h, []string{"--custom-headless"}))

	// Disallow duplicate if override is false
	dup_rejected := pty.shell_registry_register("zsh", {"-l"}, {}, override = false)
	testing.expect(t, !dup_rejected)

	// Allow duplicate update if override is true
	dup_accepted := pty.shell_registry_register("zsh", {"--new-args"}, {}, override = true)
	testing.expect(t, dup_accepted)

	resolved_updated := pty.shell_resolve_argv("/bin/zsh", .Interactive)
	testing.expect(t, slice.equal(resolved_updated, []string{"--new-args"}))

	// Reset restores builtins
	pty.shell_registry_reset()
	restored_i := pty.shell_resolve_argv("/bin/zsh", .Interactive)
	testing.expect(t, slice.equal(restored_i, []string{"-l", "-o", "COMBINING_CHARS"}))
}

@(test)
test_shell_registry_capacity_limit :: proc(t: ^testing.T) {
	pty.shell_registry_reset()
	defer pty.shell_registry_reset()

	names := [16]string{
		"s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8",
		"s9", "s10", "s11", "s12", "s13", "s14", "s15", "s16",
	}

	for name in names {
		ok := pty.shell_registry_register(name, {"-i"}, {"-h"})
		testing.expect(t, ok)
	}

	// 17th should fail because fixed pool capacity is 16
	fail_ok := pty.shell_registry_register("s17", {"-i"}, {"-h"})
	testing.expect(t, !fail_ok)

	// Empty name should fail
	empty_ok := pty.shell_registry_register("", {"-i"}, {"-h"})
	testing.expect(t, !empty_ok)
}
