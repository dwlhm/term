package bench_probe

import "base:runtime"
import "core:sync"

Alloc_Probe :: struct {
	base_allocator:        runtime.Allocator,
	init_done:             bool,
	post_init_allocs:      u64,
	post_init_frees:       u64,
	total_allocated_bytes: u64,
	mutex:                 sync.Mutex,
}

alloc_probe_init :: proc(p: ^Alloc_Probe, base: runtime.Allocator) {
	if p == nil do return
	p^ = {}
	p.base_allocator = base
}

alloc_probe_allocator :: proc(p: ^Alloc_Probe) -> runtime.Allocator {
	return runtime.Allocator{
		procedure = alloc_probe_proc,
		data      = rawptr(p),
	}
}

alloc_probe_mark_init_done :: proc(p: ^Alloc_Probe) {
	if p == nil do return
	p.init_done = true
}

alloc_probe_post_init_allocs :: proc(p: ^Alloc_Probe) -> u64 {
	if p == nil do return 0
	return sync.atomic_load(&p.post_init_allocs)
}

alloc_probe_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location = #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	p := (^Alloc_Probe)(allocator_data)
	if p == nil || p.base_allocator.procedure == nil {
		return nil, .Invalid_Argument
	}

	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if p.init_done {
			sync.atomic_add(&p.post_init_allocs, 1)
			sync.atomic_add(&p.total_allocated_bytes, u64(size))
		}
	case .Free:
		if p.init_done {
			sync.atomic_add(&p.post_init_frees, 1)
		}
	case .Resize, .Resize_Non_Zeroed:
		if p.init_done {
			if size > old_size {
				sync.atomic_add(&p.post_init_allocs, 1)
				sync.atomic_add(&p.total_allocated_bytes, u64(size - old_size))
			}
		}
	}

	return p.base_allocator.procedure(
		p.base_allocator.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		location,
	)
}
