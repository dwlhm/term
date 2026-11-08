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
	{"ls", "[--json]", "List sessions (state, pid, cwd, request, title)", ""},
	{"new", "[-d dir] [-s COLSxROWS] [-e K=V]… [-- prog args…] | --endpoint <name>", "Start a background session (or a virtual endpoint); prints its id",
		"The program keeps running after the CLI exits. Its environment has\nTERM_SESSION_ID=<id> (and TERM_PROGRAM=term). --endpoint makes a session with no\nprogram, for an app that takes its requests (`next --as <id>`); it lives until killed."},
	{"whoami", "", "Print the id of the session this shell runs in ($TERM_SESSION_ID)", ""},
	{"run", "<id> <command> [-t sec] [-n lines] [--json]", "Run a command at the session's shell prompt; print its output and [exit N]",
		"`tell` for the shell adapter only (OSC 133). Waits for the first prompt of a\nnew shell; a shell running something rejects it (exit 5). Prints what the command\nprinted (-n: its last lines). ^C or -t (default 600) ends it and stops the command."},
	{"observe", "[id] [-n lines] [--json]", "Snapshot: prompt state, cmd_seq, last exit code, screen text",
		"Never resizes, focuses or scrolls the session. prompt_state is None (no shell\nintegration seen), Prompt, Input (waiting at the prompt) or Executing."},
	{"watch", "<id> [--prompt | --executing | --exit] [--since SEQ] [-t sec] [--json]", "Block until the next prompt, command start or exit",
		"Default events: --prompt --exit. --since SEQ answers at once when a command\nfinished after cmd_seq SEQ (from observe). An exited session answers at once."},
	{"tell", "<id> <text|-> [--async] [-t sec] [--parent request] [--json]", "Ask a session to process text; exactly one result comes back",
		"A worker waiting in `next` takes it, or the shell adapter types it at a shell\nprompt (OSC 133) and returns the command's output and exit. Otherwise it is\nrejected at once (exit 5): no queue. Waits and prints progress (stderr) and the\nresult; --async prints the request id instead (read it with `result`). A\nrequest sent while working on another one is its child and ends with it."},
	{"result", "<request>… [--wait [-t sec]] [--follow] [--json]", "Read a request's result, or wait until one of several ends",
		"Without --wait: the state now (running + progress, or the result). The sender\nreading its own finished result takes it; unfetched results expire after 10 min."},
	{"cancel", "<request>", "Cancel a running request and the requests its work sent", ""},
	{"next", "[-t sec] [--as session] [--json]", "Worker: wait for the next request to this session",
		"Prints \"#<id> from <session>\" and the request. Each waiting `next` is one free\nslot: run several to take several requests at once."},
	{"progress", "<request> <text|-> [--as session]", "Worker: report progress on a request it took", ""},
	{"answer", "<request> <text|-> [--failed] [--as session]", "Worker: answer a request it took (ends it)", ""},
	{"read", "[id] [-n lines] [--last] [--clean] [--elements] [--output text|json]", "Read screen text, command output, or interactive UI elements",
		"Never alters session, size, scroll or focus. -n adds history; --last reads\nlast command output; --clean strips box drawing; --elements lists UI elements."},
	{"send", "<id> <text>", "Type raw keystrokes into the PTY (escapes: \\n \\r \\t \\e \\\\ \\xHH)", ""},
	{"wait", "<id> [-t sec] [--exit | --text substr | --listening [--quiet sec]]", "Wait until idle/exited, text shows, or a worker listens",
		"--listening ends at once when the session exits (4); --quiet gives up (3) when\nit neither listens nor prints anything for that long."},
	{"signal", "<id> <INT|TERM|HUP|9…>", "Signal the session's foreground process group (like ^C)", ""},
	{"resize", "<id> <COLSxROWS>", "Resize a session no window shows", ""},
	{"kill", "<id>", "End the program and remove the session", ""},
	{"attach", "<id>", "Show a background session in the running window", ""},
}

APP_CLI_USAGE :: "usage: term session <verb> … (term session --help lists the verbs)"

app_cli_help :: proc() -> int {
	fmt.println("term — GPU terminal emulator with persistent sessions\n")
	fmt.println("  term                         open a window (or show the running one)")
	fmt.println("  term session <verb> …        sessions (below)")
	fmt.println("  term auto <check|snapshot> …          automation contracts (term auto --help)")
	fmt.println("  term skill <setup|status|show|remove>   agent skill for AI coding agents")
	fmt.println("  term show | term quit\n")
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
