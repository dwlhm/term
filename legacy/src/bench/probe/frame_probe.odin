package bench_probe

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"

Frame_Probe :: struct {
	frames_rendered:     u64,
	frames_skipped:      u64,
	strategy_instance:   u64,
	strategy_compute:    u64,
	strategy_fullscreen: u64,
	pty_bytes_total:     u64,
	mutex:               sync.Mutex,
}

frame_probe_init :: proc(p: ^Frame_Probe) {
	if p == nil do return
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	p.frames_rendered = 0
	p.frames_skipped = 0
	p.strategy_instance = 0
	p.strategy_compute = 0
	p.strategy_fullscreen = 0
	p.pty_bytes_total = 0
}

frame_probe_record :: proc(p: ^Frame_Probe, rendered: bool, strategy_name: string, pty_bytes: u64) {
	if p == nil do return
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)

	if rendered {
		p.frames_rendered += 1
	} else {
		p.frames_skipped += 1
	}

	if strings.contains(strategy_name, "Instance") {
		p.strategy_instance += 1
	} else if strings.contains(strategy_name, "ComputeTile") || strings.contains(strategy_name, "Compute") {
		p.strategy_compute += 1
	} else if strings.contains(strategy_name, "Fullscreen") {
		p.strategy_fullscreen += 1
	}

	p.pty_bytes_total += pty_bytes
}

frame_probe_report :: proc(p: ^Frame_Probe, allocator: runtime.Allocator = context.allocator) -> string {
	if p == nil do return ""
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)

	return fmt.aprintf(
		"frames: rendered=%d skipped=%d | strategies: instance=%d compute=%d fullscreen=%d | pty_bytes=%d",
		p.frames_rendered,
		p.frames_skipped,
		p.strategy_instance,
		p.strategy_compute,
		p.strategy_fullscreen,
		p.pty_bytes_total,
		allocator = allocator,
	)
}
