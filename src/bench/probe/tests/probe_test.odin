package probe_test

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import probe "../"

@(test)
test_alloc_probe_tracking :: proc(t: ^testing.T) {
	p: probe.Alloc_Probe
	probe.alloc_probe_init(&p, context.allocator)
	probe_allocator := probe.alloc_probe_allocator(&p)

	buf1, err1 := runtime.mem_alloc(64, runtime.DEFAULT_ALIGNMENT, probe_allocator)
	testing.expect(t, err1 == nil, "allocation should succeed")
	testing.expect_value(t, probe.alloc_probe_post_init_allocs(&p), 0)
	runtime.mem_free(raw_data(buf1), probe_allocator)

	probe.alloc_probe_mark_init_done(&p)

	buf2, err2 := runtime.mem_alloc(128, runtime.DEFAULT_ALIGNMENT, probe_allocator)
	testing.expect(t, err2 == nil, "post-init allocation should succeed")
	testing.expect_value(t, probe.alloc_probe_post_init_allocs(&p), 1)
	runtime.mem_free(raw_data(buf2), probe_allocator)
}

@(test)
test_frame_probe_metrics :: proc(t: ^testing.T) {
	fp: probe.Frame_Probe
	probe.frame_probe_init(&fp)

	probe.frame_probe_record(&fp, true, "Instance", 2048)
	probe.frame_probe_record(&fp, false, "ComputeTile", 0)
	probe.frame_probe_record(&fp, true, "Fullscreen", 1024)

	testing.expect_value(t, fp.frames_rendered, 2)
	testing.expect_value(t, fp.frames_skipped, 1)
	testing.expect_value(t, fp.strategy_instance, 1)
	testing.expect_value(t, fp.strategy_compute, 1)
	testing.expect_value(t, fp.strategy_fullscreen, 1)
	testing.expect_value(t, fp.pty_bytes_total, 3072)

	report := probe.frame_probe_report(&fp, context.temp_allocator)
	testing.expect(t, strings.contains(report, "rendered=2"), "report contains rendered count")
	testing.expect(t, strings.contains(report, "skipped=1"), "report contains skipped count")
	testing.expect(t, strings.contains(report, "instance=1"), "report contains instance count")
	testing.expect(t, strings.contains(report, "compute=1"), "report contains compute count")
	testing.expect(t, strings.contains(report, "fullscreen=1"), "report contains fullscreen count")
	testing.expect(t, strings.contains(report, "pty_bytes=3072"), "report contains pty_bytes")
}

@(test)
test_profile_ring_drops :: proc(t: ^testing.T) {
	r := new(probe.Profile_Ring)
	defer free(r)

	for i in 0..<(probe.PROFILE_RECORD_CAP + 1) {
		ok := probe.profile_try_record(r, probe.Profile_Record{})
		if i < probe.PROFILE_RECORD_CAP {
			testing.expect(t, ok, "records fit while ring has capacity")
		} else {
			testing.expect(t, !ok, "full ring drops record")
		}
	}
	dropped := sync.atomic_load(&r.dropped)
	testing.expect_value(t, dropped, 1)
}
