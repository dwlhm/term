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
	frame_active: bool,
}

// Upload_Ring_Frame is a tentative reservation. The ring index advances only
// after the command using the slot has been accepted by the queue.
Upload_Ring_Frame :: struct {
	slot:     int,
	data_size: u64,
	reserved: bool,
	committed: bool,
}

// upload_ring_init creates the upload ring with the specified capacity per slot.
upload_ring_init :: proc(r: ^Upload_Ring, backend: ^gpu.Gpu_Backend_VTable, device: gpu.Gpu_Device, queue: gpu.Gpu_Queue, capacity: u64, allocator: runtime.Allocator = context.allocator) {
	r.backend    = backend
	r.device   = device
	r.queue    = queue
	r.capacity = capacity
	r.write_slot = 0
	r.frame_active = false

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

// upload_ring_begin reserves the current slot without advancing ownership.
upload_ring_begin :: proc(r: ^Upload_Ring) -> Upload_Ring_Frame {
	if r == nil || r.frame_active {
		return Upload_Ring_Frame{}
	}
	r.frame_active = true
	return Upload_Ring_Frame{slot = r.write_slot, reserved = true}
}

// upload_ring_get_staging returns the staging buffer for a reservation.
upload_ring_get_staging :: proc(r: ^Upload_Ring, frame: Upload_Ring_Frame) -> []u8 {
	if r == nil || !frame.reserved || frame.slot < 0 || frame.slot >= UPLOAD_RING_SLOTS {
		return nil
	}
	return r.staging[frame.slot]
}

// upload_ring_write publishes tentative bytes to the reserved GPU buffer.
// The slot remains owned by the frame until upload_ring_commit.
upload_ring_write :: proc(r: ^Upload_Ring, frame: ^Upload_Ring_Frame, data_size: u64) -> bool {
	if r == nil || frame == nil || !frame.reserved || frame.committed || !r.frame_active {
		return false
	}
	if frame.slot < 0 || frame.slot >= UPLOAD_RING_SLOTS || data_size > r.capacity {
		return false
	}
	frame.data_size = data_size
	if r.backend != nil && rawptr(r.queue) != nil && rawptr(r.buffers[frame.slot]) != nil && data_size > 0 {
		r.backend.write_buffer(r.queue, r.buffers[frame.slot], 0, raw_data(r.staging[frame.slot]), data_size)
	}
	return true
}

// upload_ring_commit advances ownership after queue submission succeeds.
upload_ring_commit :: proc(r: ^Upload_Ring, frame: ^Upload_Ring_Frame) {
	if r == nil || frame == nil || !frame.reserved || frame.committed || !r.frame_active {
		return
	}
	frame.committed = true
	r.write_slot = (frame.slot + 1) % UPLOAD_RING_SLOTS
	r.frame_active = false
}

// upload_ring_abort releases a tentative reservation without advancing it.
upload_ring_abort :: proc(r: ^Upload_Ring, frame: ^Upload_Ring_Frame) {
	if r == nil || frame == nil || !frame.reserved || frame.committed {
		return
	}
	frame.reserved = false
	r.frame_active = false
}

// upload_ring_get_buffer returns the GPU buffer for a given slot index.
upload_ring_get_buffer :: proc(r: ^Upload_Ring, slot: int) -> gpu.Gpu_Buffer {
	return r.buffers[slot % UPLOAD_RING_SLOTS]
}

// upload_ring_current_slot returns the current write slot index.
upload_ring_current_slot :: proc(r: ^Upload_Ring) -> int {
	return r.write_slot
}
