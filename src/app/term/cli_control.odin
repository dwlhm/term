package term

// `term` control subcommands (client side; never creates a window).
//   term session ls | term session attach <id> | term session kill <id>
//   term show | term quit
// Exit codes: 0 ok · 1 error reply / bad usage · 2 Term is not running.

// app_run_control_cli: handled = false when args[1] is not "session",
// "show" or "quit" (normal GUI startup continues). Otherwise sends the request
// with ipc_client_request to ipc_default_socket_path and prints:
//   ls     → "No background sessions" or an aligned table with header
//            ID  STATE  PID  ELAPSED  PROCESS  CWD  STATUS (ELAPSED as 1h02m / 3m12s / 45s)
//   others → nothing on success
//   err reply → stderr "term: <message or code>", exit 1
//   Not_Running → stderr "term: Term is not running", exit 2
//   Timeout/Busy/other → stderr "term: control socket <reason>", exit 1
//   usage error (unknown/missing args) → stderr usage text, exit 1
app_run_control_cli :: proc(args: []string) -> (handled: bool, exit_code: int) {
	unimplemented("T7")
}
