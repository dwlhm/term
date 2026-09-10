package render

// Triple-buffered upload ring for zero-allocation-per-frame GPU data uploads.
//
// The ring has 3 slots. Each frame, the renderer writes data into the "write" slot,
// then submits it to the GPU. The GPU reads from a slot that is at least 1 frame
// behind the write slot, ensuring no data races.
//
// Slot lifecycle:
//   Frame N:   write to slot[N % 3], submit to GPU
//   Frame N+1: write to slot[(N+1) % 3], GPU reads slot[N % 3]
//   Frame N+2: write to slot[(N+2) % 3], GPU reads slot[(N+1) % 3]
//
// This ensures the GPU always reads data that is no longer being written.

import "base:runtime"
import gpu "gpu"

// UPLOAD_RING_SLOTS is the number of slots in the upload ring (triple-buffered).
UPLOAD_RING_SLOTS :: 3

// Upload_Ring manages triple-buffered GPU uploads.
Upload_Ring :: struct {
	buffers:    [UPLOAD_RING_SLOTS]gpu.Gpu_Buffer,
	staging:    [UPLOAD_RING_SLOTS][]u8,  // CPU-side staging memory
	capacity:   u64,                       // bytes per slot
	write_slot: int,                       // current write slot index
	device:     gpu.Gpu_Device,
	queue:      gpu.Gpu_Queue,
	backend:    ^gpu.Gpu_Backend_VTable,
}

// upload_ring_init creates the upload ring with the specified capacity per slot.
upload_ring_init :: proc(r: ^Upload_Ring, backend: ^gpu.Gpu_Backend_VTable, device: gpu.Gpu_Device, queue: gpu.Gpu_Queue, capacity: u64, allocator: runtime.Allocator = context.allocator) {
	r.backend    = backend
	r.device   = device
	r.queue    = queue
	r.capacity = capacity
	r.write_slot = 0

	for i in 0..<UPLOAD_RING_SLOTS {
		// Create GPU buffer (nil backend → CPU-only)
		if backend != nil && rawptr(device) != nil {
			r.buffers[i] = backend.create_buffer(
				device,
				capacity,
				gpu.Gpu_Buffer_Usage.Vertex | gpu.Gpu_Buffer_Usage.Copy_Dst,
				false,
			)
		} else {
			r.buffers[i] = gpu.Gpu_Buffer(nil)
		}

		// Allocate CPU staging memory
		r.staging[i] = make([]u8, capacity, allocator)
	}
}

// upload_ring_destroy frees all staging memory.
upload_ring_destroy :: proc(r: ^Upload_Ring, allocator: runtime.Allocator = context.allocator) {
	for i in 0..<UPLOAD_RING_SLOTS {
		if rawptr(r.buffers[i]) != nil && r.backend != nil {
			r.backend.destroy_buffer(r.buffers[i])
			r.buffers[i] = gpu.Gpu_Buffer(nil)
		}
		if r.staging[i] != nil {
			delete(r.staging[i])
			r.staging[i] = nil
		}
	}
}

// upload_ring_get_staging returns the CPU staging buffer for the current write slot.
// The caller writes data into this buffer, then calls upload_ring_submit.
upload_ring_get_staging :: proc(r: ^Upload_Ring) -> []u8 {
	return r.staging[r.write_slot]
}

// upload_ring_submit flushes the current write slot's data to the GPU buffer.
// Advances the write slot to the next ring position.
upload_ring_submit :: proc(r: ^Upload_Ring, data_size: u64) {
	slot := r.write_slot
	size := data_size
	if size > r.capacity {
		size = r.capacity
	}
	if r.backend != nil && rawptr(r.queue) != nil && rawptr(r.buffers[slot]) != nil && size > 0 {
		r.backend.write_buffer(r.queue, r.buffers[slot], 0, raw_data(r.staging[slot]), size)
	}
	// Advance to next slot
	r.write_slot = (r.write_slot + 1) % UPLOAD_RING_SLOTS
}

// upload_ring_get_buffer returns the GPU buffer for a given slot index.
upload_ring_get_buffer :: proc(r: ^Upload_Ring, slot: int) -> gpu.Gpu_Buffer {
	return r.buffers[slot % UPLOAD_RING_SLOTS]
}

// upload_ring_current_slot returns the current write slot index.
upload_ring_current_slot :: proc(r: ^Upload_Ring) -> int {
	return r.write_slot
}
