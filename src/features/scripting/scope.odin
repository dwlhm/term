package feature_scripting

// Resource Scope and AcquireRelease management.
// Finalizers are executed in strict LIFO order on fiber exit or interruption.

scope_init :: proc(s: ^Scope, allocator := context.allocator) {
	s.finalizers = make([dynamic]Finalizer, allocator)
	s.closed = false
}

scope_add_finalizer :: proc(s: ^Scope, fn: Finalizer_Proc, data: rawptr) {
	if s.closed {
		// If already closed, execute immediately to avoid leaking
		if fn != nil do fn(data)
		return
	}
	append(&s.finalizers, Finalizer{fn = fn, data = data})
}

// scope_close executes all registered finalizers in reverse order (LIFO).
scope_close :: proc(s: ^Scope) {
	if s.closed do return
	s.closed = true

	// Execute backwards (LIFO)
	for i := len(s.finalizers) - 1; i >= 0; i -= 1 {
		f := s.finalizers[i]
		if f.fn != nil {
			f.fn(f.data)
		}
	}
	clear(&s.finalizers)
}

scope_destroy :: proc(s: ^Scope) {
	scope_close(s)
	delete(s.finalizers)
}
