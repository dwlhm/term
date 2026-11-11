package term

// One table describes every `term session` verb: the overview, per-verb help
// and usage errors all print from it.

import "core:fmt"

Verb_Help :: struct {
	name:    string,
	args:    string,
	summary: string,
	detail:  string,
}

SESSION_VERBS := [?]Verb_Help{
	{
		"new",
		"[-d dir] [-s COLSxROWS] [-e K=V]… [--name name] [-- prog args…]",
		"Start a background session; prints its id",
		"The program keeps running after the CLI exits. " +
			"Its environment has\nTERM_SESSION_ID=<id> " +
			"(and TERM_PROGRAM=term).",
	},
	{
		"kill",
		"<id>",
		"End the program and remove the session",
		"",
	},
	{
		"ls",
		"[--output text|json]",
		"List sessions (state, pid, cwd, size, held-by, title)",
		"",
	},
	{
		"attach",
		"<id>",
		"Show a background session in the running window",
		"",
	},
	{
		"resize",
		"<id> <COLSxROWS>",
		"Resize a session no window shows",
		"",
	},
	{
		"whoami",
		"",
		"Print the id of the session this shell runs in ($TERM_SESSION_ID)",
		"",
	},
	{
		"read",
		"[id] [-n lines] [--last] [--clean] [--elements] [--tail] " +
			"[--output text|json]",
		"Read screen text, command output, or interactive UI elements",
		"Never alters session, size, scroll or focus. -n adds history; " +
			"--last reads\nlast command output; --clean strips box drawing; " +
			"--elements lists UI elements;\n--tail follows updates until " +
			"condition (--until, --prompt, --exit, --idle).",
	},
	{
		"send",
		"<id> [text] [--key K] [--click P] [--raw S]…",
		"Send keystrokes, text, mouse events or raw bytes into session",
		"Batched atomic input into the session's PTY. " +
			"Never alters scroll or focus.",
	},
	{
		"signal",
		"<id> <INT|TERM|HUP|9…>",
		"Signal the session's foreground process group (like ^C)",
		"",
	},
	{
		"cancel",
		"<id> [-t sec]",
		"Interrupt a running command (SIGINT) and wait for the prompt",
		"",
	},
}

APP_CLI_USAGE :: "usage: term session <verb> … (term session --help lists the verbs)"

app_cli_help :: proc() -> int {
	fmt.println("term — GPU terminal emulator with persistent sessions\n")
	fmt.println("  term                         open a window (or show the running one)")
	fmt.println("  term studio [--demo]         native multi-surface GPU compositor TUI cockpit")
	fmt.println("  term session <verb> …        sessions (below)")
	fmt.println("  term run <script.lua> …      run a term Lua script")
	fmt.println("  term auto <check|snapshot> …          automation contracts (term auto --help)")
	fmt.println("  term skill <setup|status|show|remove>   agent skill for AI coding agents")
	fmt.println("  term show | term split <right|down> [id] | term tab [id]")
	fmt.println("  term quit [-f] | term kill\n")
	fmt.println("SESSION VERBS:")
	for v in SESSION_VERBS do fmt.printfln("  %-8s %s", v.name, v.summary)
	fmt.println("\nInside a term session, $TERM_SESSION_ID is your own id (term session whoami).")
	fmt.println("Exit codes: 0 ok · 1 error · 2 no session core · 3 timed out · 4 wait --text ended first · 5 rejected")
	fmt.println("Details: term session <verb> --help")
	return 0
}

app_cli_session_help :: proc(args: []string) -> int {
	if len(args) == 0 do return app_cli_help()
	for v in SESSION_VERBS {
		if v.name != args[0] do continue
		fmt.printfln("usage: term session %s %s\n\n%s", v.name, v.args, v.summary)
		if len(v.detail) > 0 do fmt.printfln("\n%s", v.detail)
		return 0
	}
	fmt.eprintfln("term: unknown session verb %q (term session --help)", args[0])
	return 1
}
