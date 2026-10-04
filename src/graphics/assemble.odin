package graphics

import "base:runtime"

// Assembly accumulates the decoded payload of a KGP transmission.
Assembly :: struct {
	active:    bool,
	control:   Control,
	buf:       [dynamic]u8,
	allocator: runtime.Allocator,
}

// assembly_reset releases the accumulated payload and returns the assembly to
// its initial reusable state.
assembly_reset :: proc(a: ^Assembly) {
	if a == nil do return
	if a.buf != nil {
		previous_allocator := context.allocator
		context.allocator = a.allocator
		delete(a.buf)
		context.allocator = previous_allocator
	}
	a.buf = nil
	a.active = false
	a.control = Control{}
	a.allocator = {}
}

// assembly_feed parses and accumulates one KGP control/payload pair.
assembly_feed :: proc(a: ^Assembly, control: []u8, payload: []u8) -> (complete: bool, res: Feed_Result) {
	if a == nil do return true, .Invalid

	is_continuation := kgp_is_continuation(control)
	parsed: Control
	if !kgp_parse_control(control, &parsed) {
		assembly_reset(a)
		return true, .Invalid
	}
	if is_continuation && !a.active {
		return true, .Invalid
	}

	previous_allocator := context.allocator
	defer context.allocator = previous_allocator
	if is_continuation {
		context.allocator = a.allocator
	} else {
		if a.buf != nil {
			assembly_reset(a)
		}
		a.allocator = context.allocator
		a.control = parsed
		a.active = true
	}

	// Base64 decoding never produces more bytes than its input, so reserving
	// the input length is sufficient for the decoded chunk. The destination
	// must be part of the dynamic array's current length, not just its capacity.
	old_len := len(a.buf)
	reserve(&a.buf, old_len + len(payload))
	resize(&a.buf, old_len + len(payload))
	n, ok := base64_decode(a.buf[old_len:], payload)
	if !ok {
		assembly_reset(a)
		return true, .Invalid
	}
	resize(&a.buf, old_len + n)

	if parsed.more {
		return false, .Ok
	}
	a.active = false
	return true, .Ok
}
