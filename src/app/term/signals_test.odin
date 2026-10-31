package term

import "base:intrinsics"
import "core:sys/posix"
import "core:testing"
import "core:time"

@test
test_signal_router_quit_and_stop :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)

	signals_block_quit_set()

	r: Signal_Router
	started := signals_start(&r, app)
	testing.expect(t, started, "signals_start should return true")
	testing.expect(t, r.running, "r.running should be true")

	posix.pthread_kill(r.thread, .SIGHUP)

	quit_received := false
	for _ in 0..<200 { // 200 * 5ms = 1000 ms
		if intrinsics.atomic_load(&app.quit_requested) {
			quit_received = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, quit_received, "atomic_load(&app.quit_requested) must be true within 1000 ms")

	stop_start := time.now()
	signals_stop(&r)
	stop_elapsed := time.duration_milliseconds(time.since(stop_start))
	testing.expect(t, stop_elapsed < 1000, "signals_stop(&r) must return within 1000 ms")
	testing.expect(t, !r.running, "r.running must be false")

	// signals_stop again is a no-op
	signals_stop(&r)
	testing.expect(t, !r.running, "signals_stop again must be a no-op and r.running remain false")
}
