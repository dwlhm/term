package term

// Quit-signal routing (SIGTERM / SIGINT / SIGHUP → app_request_quit)
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: SDL's own signal handlers are disabled (SDL_HINT_NO_SIGNAL_HANDLERS)
// because SDL maps signals to SDL_EVENT_QUIT, which now means "hide". The quit
// set is blocked in every thread and consumed by one sigwait thread; PTY
// children reset their signal mask after fork so shells keep working ^C.

import "base:intrinsics"
import "base:runtime"
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
	set := _quit_set()
	return posix.pthread_sigmask(.BLOCK, &set, nil) == .NONE
}

@(private = "file")
_quit_set :: proc "contextless" () -> (set: posix.sigset_t) {
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGTERM)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGHUP)
	posix.sigaddset(&set, SIGNAL_SHUTDOWN_SENTINEL)
	return
}

@(private = "file")
_signal_thread_entry :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	r := cast(^Signal_Router)arg
	if r == nil || r.app == nil do return nil
	set := _quit_set()

	for {
		sig: posix.Signal
		if posix.sigwait(&set, &sig) != .NONE {
			continue
		}
		if sig == SIGNAL_SHUTDOWN_SENTINEL do break
		intrinsics.atomic_store(&r.app.quit_requested, true)
		app_pty_wakeup_callback(r.app)
	}
	return nil
}

// signals_start spawns a pthread looping on sigwait(quit set):
// SIGTERM/SIGINT/SIGHUP → atomic store app.quit_requested = true, then
// app_pty_wakeup_callback(app); SIGUSR2 → leave the loop.
signals_start :: proc(r: ^Signal_Router, app: ^Term_App) -> bool {
	if r == nil || app == nil do return false
	if r.running do return true
	r.app = app
	if posix.pthread_create(&r.thread, nil, _signal_thread_entry, r) != .NONE {
		// Nobody would consume the blocked set: restore default delivery so
		// SIGTERM/SIGINT still terminate the process.
		set := _quit_set()
		posix.pthread_sigmask(.UNBLOCK, &set, nil)
		return false
	}
	r.running = true
	return true
}

// signals_stop: no-op unless running; pthread_kill(thread, SIGUSR2), join.
signals_stop :: proc(r: ^Signal_Router) {
	if r == nil || !r.running do return
	posix.pthread_kill(r.thread, SIGNAL_SHUTDOWN_SENTINEL)
	posix.pthread_join(r.thread, nil)
	r.running = false
}
