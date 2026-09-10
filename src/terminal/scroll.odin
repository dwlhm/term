package termgrid

// scroll_up scrolls the grid up by n rows within the specified region.
// Returns the number of rows actually scrolled.
scroll_up :: proc(g: ^Grid, d: ^Damage, top, bottom, n: int) -> int {
	actual := _scroll_region(g, top, bottom, n)
	if actual > 0 {
		// Clamp region to valid bounds for damage recording.
		t := top
		b := bottom
		if t < 0 {
			t = 0
		}
		if b >= g.row_count {
			b = g.row_count - 1
		}
		damage_record_scroll(d, t, b, actual)

		// Mark the newly exposed rows at the bottom of the region as dirty.
		for i in 0..<actual {
			logical := b - actual + 1 + i
			phys := _grid_physical_row(g, logical)
			damage_mark_row(d, logical, g.rows[phys].generation)
		}
	}
	return actual
}

// scroll_down scrolls the grid down by n rows within the specified region.
// Returns the number of rows actually scrolled.
scroll_down :: proc(g: ^Grid, d: ^Damage, top, bottom, n: int) -> int {
	actual := _scroll_region(g, top, bottom, -n)
	if actual > 0 {
		// Clamp region to valid bounds for damage recording.
		t := top
		b := bottom
		if t < 0 {
			t = 0
		}
		if b >= g.row_count {
			b = g.row_count - 1
		}
		damage_record_scroll(d, t, b, -actual)

		// Mark the newly exposed rows at the top of the region as dirty.
		for i in 0..<actual {
			logical := t + i
			phys := _grid_physical_row(g, logical)
			damage_mark_row(d, logical, g.rows[phys].generation)
		}
	}
	return actual
}

// _scroll_region scrolls a specific region of the grid.
// Positive n = scroll up, negative n = scroll down.
// Returns the number of rows actually scrolled (absolute value).
_scroll_region :: proc(g: ^Grid, top, bottom, n: int) -> int {
	if g.row_count == 0 {
		return 0
	}

	// Clamp region to valid bounds
	t := top
	b := bottom
	if t < 0 {
		t = 0
	}
	if b >= g.row_count {
		b = g.row_count - 1
	}
	if t > b {
		return 0
	}

	region_size := b - t + 1
	abs_n := n
	if abs_n < 0 {
		abs_n = -abs_n
	}
	if abs_n > region_size {
		abs_n = region_size
	}
	if abs_n == 0 {
		return 0
	}

	// Full-grid scroll: use ring buffer rotation (O(1))
	if t == 0 && b == g.row_count - 1 {
		if n > 0 {
			grid_scroll_up(g, abs_n)
		} else {
			grid_scroll_down(g, abs_n)
		}
		return abs_n
	}

	// Partial region scroll: rotate rows in-place
	if n > 0 {
		// Scroll up: rotate rows [top, bottom] left by n
		_scroll_region_up(g, t, b, abs_n)
	} else {
		// Scroll down: rotate rows [top, bottom] right by n
		_scroll_region_down(g, t, b, abs_n)
	}

	return abs_n
}

// _scroll_region_up rotates rows in [top, bottom] up by n positions.
// Uses swap-based rotation to avoid allocations.
_scroll_region_up :: proc(g: ^Grid, top, bottom, n: int) {
	region_size := bottom - top + 1
	steps := region_size - n

	// Move rows [top+n, bottom] to [top, bottom-n] via swaps
	for i in 0..<steps {
		src_logical := top + n + i
		dst_logical := top + i
		src_phys := _grid_physical_row(g, src_logical)
		dst_phys := _grid_physical_row(g, dst_logical)

		// Swap Row structs (cells slice + generation)
		g.rows[src_phys], g.rows[dst_phys] = g.rows[dst_phys], g.rows[src_phys]
	}

	// Clear the bottom n rows (they now contain stale data from the rotation)
	for i in 0..<n {
		logical := bottom - n + 1 + i
		phys := _grid_physical_row(g, logical)
		row_clear(&g.rows[phys])
	}
}

// _scroll_region_down rotates rows in [top, bottom] down by n positions.
// Uses swap-based rotation to avoid allocations.
_scroll_region_down :: proc(g: ^Grid, top, bottom, n: int) {
	region_size := bottom - top + 1
	steps := region_size - n

	// Move rows [top, bottom-n] to [top+n, bottom] via swaps
	// Iterate in reverse to avoid overwriting data we still need
	for i in 0..<steps {
		src_logical := bottom - n - i
		dst_logical := bottom - i
		src_phys := _grid_physical_row(g, src_logical)
		dst_phys := _grid_physical_row(g, dst_logical)

		// Swap Row structs (cells slice + generation)
		g.rows[src_phys], g.rows[dst_phys] = g.rows[dst_phys], g.rows[src_phys]
	}

	// Clear the top n rows (they now contain stale data from the rotation)
	for i in 0..<n {
		logical := top + i
		phys := _grid_physical_row(g, logical)
		row_clear(&g.rows[phys])
	}
}
