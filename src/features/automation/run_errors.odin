package feature_automation

// How a run ends, and the exit code `term auto run` gives for it.

Run_Code :: enum u8 {
	Ok,
	Contract,     // the contract is invalid, or its Lua failed
	No_Core,      // no term session core runs
	Timeout,      // the run, an ask or a handoff ran out of time
	Exited,       // the program ended first
	Rejected,     // the session is leased by another automation, or busy
	Unexpected,   // an expected screen did not come
	Unsupported,  // the program did not ask for that input (mouse reports)
	Failed,       // the contract said so (t.fail) or a precondition does not hold
	Interrupted,  // a person took the session back in its window
	Cancelled,    // a person pressed Esc or ^C, or the runner got SIGINT
}

run_exit_code :: proc(code: Run_Code) -> int {
	switch code {
	case .Ok:                                  return 0
	case .Contract:                            return 1
	case .No_Core:                             return 2
	case .Timeout:                             return 3
	case .Exited:                              return 4
	case .Rejected:                            return 5
	case .Unexpected, .Unsupported, .Failed:   return 6
	case .Interrupted, .Cancelled:             return 7
	}
	return 1
}
