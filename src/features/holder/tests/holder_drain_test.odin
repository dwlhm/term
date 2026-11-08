package feature_holder_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import holder ".."
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// A burst far larger than one drain arrives complete and in order, every
// frame within the drain budget, before EXITED.
@(test)
test_drained_burst_is_complete :: proc(t: ^testing.T) {
	LINES :: 200_000
	f := fixture_start()
	c := client_connect(f.path)
	client_spawn(c, 1, {"/usr/bin/seq", "1", fmt.tprint(LINES)})
	i := client_wait_kind(c, proto.MSG_EXITED, 1, 10_000)
	testing.expect(t, i >= 0, "EXITED")
	want := strings.builder_make(context.temp_allocator)
	for n in 1..=LINES do fmt.sbprintf(&want, "%d\r\n", n)
	if i >= 0 do testing.expect(t, client_output(c, 1, i) == strings.to_string(want), "output complete and ordered")
	testing.expectf(t, c.max_f <= holder.HOLDER_READ_CHUNK, "frame %d > budget", c.max_f)
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

// Two flooding sessions both make progress: a drain is bounded per round.
@(test)
test_flooding_sessions_share_rounds :: proc(t: ^testing.T) {
	f := fixture_start()
	c := client_connect(f.path)
	c.keep = false
	client_spawn(c, 1, {"/usr/bin/yes", "a"})
	client_spawn(c, 2, {"/usr/bin/yes", "b"})
	deadline := time.tick_now()._nsec + 500 * 1_000_000
	for time.tick_now()._nsec < deadline && !c.closed do client_pump(c, 20)
	testing.expectf(t, c.by_ch[1] > 1 << 20 && c.by_ch[2] > 1 << 20, "both flow: %d / %d", c.by_ch[1], c.by_ch[2])
	client_signal(c, 1, .SIGKILL)
	client_signal(c, 2, .SIGKILL)
	client_close(c)
	testing.expect_value(t, fixture_stop(f), 0)
}

// Releases out of spawn order keep the live set exact: the next core's
// WELCOME lists precisely the survivors, and a reused slot still flows.
@(test)
test_live_set_after_releases :: proc(t: ^testing.T) {
	f := fixture_start()
	a := client_connect(f.path)
	for id in u32(1)..=6 do client_spawn(a, id, {"/bin/sh", "-c", "sleep 30"})
	for id in u32(1)..=6 do testing.expect(t, client_wait_kind(a, proto.MSG_SPAWNED, id, 3000) >= 0, "SPAWNED")
	for id in ([]u32{2, 6, 1}) do client_send(a, proto.MSG_RELEASE, id)
	client_spawn(a, 9, {"/bin/sh", "-c", "printf x9; sleep 30"})
	testing.expect(t, client_wait_output(a, 9, "x9", 3000), "reused slot flows")
	client_close(a)

	b := client_connect(f.path)
	wi := client_wait_kind(b, proto.MSG_WELCOME, 0, 3000)
	testing.expect(t, wi >= 0, "WELCOME")
	if wi >= 0 {
		r := ipc.wire_reader(b.log[wi].data)
		w := proto.dec_welcome(&r)
		testing.expect_value(t, w.count, u32(4))
		seen: bit_set[0..<16]
		for _ in 0..<w.count do seen += {int(proto.dec_held(&r).id)}
		testing.expect(t, ipc.wr_done(&r), "WELCOME decodes")
		testing.expect_value(t, seen, bit_set[0..<16]{3, 4, 5, 9})
	}
	ti := client_wait_kind(b, proto.MSG_TAIL, 9, 3000)
	testing.expect(t, ti >= 0 && string(b.log[ti].data) == "x9", "TAIL of the reused slot")
	client_close(b)
	testing.expect_value(t, fixture_stop(f), 0)
}
