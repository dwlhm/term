package feature_automation

// Elements: what a screen shows, found from marked sources (OSC 133 regions,
// OSC 8 links: never overridden) and generic inference. Refs (@e1, @e2…) are
// valid for the screen they were found on only.

import "core:fmt"
import "core:strings"

Role :: enum u8 {
	Panel, Dialog, Button, Checkbox, Radio, Input, Listitem, Tab, Scrollbar, Statusbar,
	Link, Prompt, Output,
}

Source :: enum u8 {
	Inferred,
	Osc133, // shell integration
	Osc8,   // hyperlinks
}

Box :: struct {
	row, col, width, height: int,
}

Element :: struct {
	role:     Role,
	name:     string, // the label: a panel's title, a button's text, a list item's text
	text:     string, // what it shows (an input's value, a link's URI, a panel's footer)
	box:      Box,
	parent:   int,  // index of the enclosing panel or dialog, -1 = the screen
	selected: bool,
	focused:  bool,
	checked:  bool,
	source:   Source,
}

box_contains :: proc(outer, inner: Box) -> bool {
	return inner.row >= outer.row && inner.col >= outer.col &&
	       inner.row + inner.height <= outer.row + outer.height && inner.col + inner.width <= outer.col + outer.width
}

box_has :: proc(b: Box, row, col: int) -> bool {
	return row >= b.row && row < b.row + b.height && col >= b.col && col < b.col + b.width
}

// element_ref is an element's ref on its screen: @e1 for elements[0].
element_ref :: proc(i: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("@e%d", i + 1, allocator = allocator)
}

// screen_elements finds every element: marked first, then inferred ones that
// do not repeat a marked element's box. Parents point into the same slice.
screen_elements :: proc(s: ^Screen, allocator := context.allocator) -> []Element {
	context.allocator = allocator
	out: [dynamic]Element
	marked(s, &out)
	n_marked := len(out)
	inferred: [dynamic]Element
	infer(s, &inferred)
	base := len(out)
	for e in inferred {
		dup := false
		for m in out[:n_marked] do dup ||= m.box == e.box
		if dup do continue
		f := e
		if f.parent >= 0 do f.parent += base
		append(&out, f)
	}
	delete(inferred)
	return out[:]
}

// element_describe: one line per element, for snapshots and golden files.
// Rows and columns are 1-based, as in Lua and in mouse input.
element_describe :: proc(es: []Element, i: int, allocator := context.temp_allocator) -> string {
	e := es[i]
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s %v %q [%d,%d %dx%d]", element_ref(i, allocator), e.role, e.name, e.box.row + 1, e.box.col + 1, e.box.width, e.box.height)
	if len(e.text) > 0 do fmt.sbprintf(&b, " text=%q", e.text)
	if e.parent >= 0 do fmt.sbprintf(&b, " in %s", element_ref(e.parent, allocator))
	if e.selected do strings.write_string(&b, " selected")
	if e.focused do strings.write_string(&b, " focused")
	if e.checked do strings.write_string(&b, " checked")
	if e.source != .Inferred do fmt.sbprintf(&b, " %v", e.source)
	return strings.to_string(b)
}
