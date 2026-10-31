package term

// Quit-signal routing (SIGTERM / SIGINT / SIGHUP → app_request_quit)
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: SDL's own signal handlers are disabled (SDL_HINT_NO_SIGNAL_HANDLERS)
// because SDL maps signals to SDL_EVENT_QUIT, which now means "hide". The quit
// set is blocked in every thread and consumed by one sigwait thread; PTY
// children reset their signal mask after fork so shells keep working ^C.

import "core:sys/posix"

SIGNAL_SHUTDOWN_SENTINEL :: posix.Signal.SIGUSR2

Signal_Router :: struct {
	thread:  posix.pthread_t,
	running: bool,
	app:     ^Term_App,
}

// signals_block_quit_set blocks {SIGTERM, SIGINT, SIGHUP, SIGUSR2} in the
// calling thread with pthread_sigmask. MUST be the first call in main(),
// before SDL or any PTY/font thread exists, so every later thread inherits it.
signals_block_quit_set :: proc() -> bool {
	unimplemented("T4b")
}

// signals_start spawns a pthread looping on sigwait(quit set):
// SIGTERM/SIGINT/SIGHUP → atomic store app.quit_requested = true, then
// app_pty_wakeup_callback(app); SIGUSR2 → leave the loop.
signals_start :: proc(r: ^Signal_Router, app: ^Term_App) -> bool {
	unimplemented("T4b")
}

// signals_stop: no-op unless running; pthread_kill(thread, SIGUSR2), join.
signals_stop :: proc(r: ^Signal_Router) {
	unimplemented("T4b")
}
