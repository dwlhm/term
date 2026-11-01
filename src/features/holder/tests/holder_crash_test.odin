package feature_holder_tests

import "core:testing"
import ipc "../../../platform/ipc"

// Every core link that ends without GOODBYE counts as a crash; WELCOME reports
// those of the last 5 minutes so a core can stop replaying tails that crash it.
@(test)
test_welcome_counts_recent_core_crashes :: proc(t: ^testing.T) {
	f := fixture_start()
	a := client_connect(f.path)
	client_spawn(a, 3, {"/bin/sh", "-c", "sleep 30"})
	testing.expect(t, client_wait_kind(a, ipc.MSG_SPAWNED, 3, 3000) >= 0, "spawned")
	client_close(a)
	for want in u32(1)..=3 {
		c := client_connect(f.path)
		wi := client_wait_kind(c, ipc.MSG_WELCOME, 0, 3000)
		testing.expect(t, wi >= 0, "WELCOME")
		if wi >= 0 {
			r := ipc.wire_reader(c.log[wi].data)
			w := ipc.dec_welcome(&r)
			testing.expect_value(t, w.previous, u8(2))
			testing.expect_value(t, w.crashes, want)
		}
		client_close(c) // drop again: one more crash
	}
	testing.expect_value(t, fixture_stop(f), 0)
}
