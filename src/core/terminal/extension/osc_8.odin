package terminal_extension

// OSC 8 hyperlinks: OSC 8 ; <params> ; <uri> ST sets the hyperlink for every
// subsequently written cell, and an empty URI clears it.

import "core:strings"

MAX_HYPERLINKS :: 64

Hyperlink_Entry :: struct {
	uri:  [512]u8,
	len:  int,
	used: bool,
}

// Hyperlink_Set_Proc hands the parser the numeric id of the active link (0 for
// none). Ids are stable for the lifetime of the URI in the table.
Hyperlink_Set_Proc :: #type proc(term: rawptr, link_id: u16)

Hyperlink_Table :: struct {
	entries:    [MAX_HYPERLINKS]Hyperlink_Entry,
	next_id:    u16,
	active:     u16,
	set_proc:   Hyperlink_Set_Proc,
}

hyperlinks_init :: proc(table: ^Hyperlink_Table, set_proc: Hyperlink_Set_Proc) {
	if table == nil do return
	table.entries = {}
	table.next_id = 1
	table.active = 0
	table.set_proc = set_proc
}

hyperlinks_uri :: proc(table: ^Hyperlink_Table, link_id: u16) -> string {
	if table == nil || link_id == 0 do return ""
	index := int(link_id - 1)
	if index < 0 || index >= MAX_HYPERLINKS do return ""
	entry := &table.entries[index]
	if !entry.used do return ""
	return string(entry.uri[:entry.len])
}

// hyperlinks_set makes `uri` the active hyperlink and returns its id. An empty
// URI clears the active link, matching the protocol's terminator sequence.
hyperlinks_set :: proc(table: ^Hyperlink_Table, uri: string) -> u16 {
	if table == nil do return 0
	if len(uri) == 0 {
		table.active = 0
		return 0
	}

	// Reuse an existing entry so repeated links do not exhaust the table.
	for i in 0..<MAX_HYPERLINKS {
		entry := &table.entries[i]
		if entry.used && entry.len == len(uri) && string(entry.uri[:entry.len]) == uri {
			table.active = u16(i + 1)
			return table.active
		}
	}

	index := int(table.next_id - 1)
	if index >= MAX_HYPERLINKS || table.entries[index].used {
		index = -1
		for i in 0..<MAX_HYPERLINKS {
			if !table.entries[i].used {
				index = i
				break
			}
		}
		if index < 0 {
			// Never recycle an id: cells already reference it, and a click must
			// never resolve to a different URL. New links are simply dropped.
			table.active = 0
			return 0
		}
	}

	entry := &table.entries[index]
	copy_len := min(len(uri), len(entry.uri))
	copy(entry.uri[:copy_len], uri[:copy_len])
	entry.len = copy_len
	entry.used = true
	table.next_id = u16(index + 2)
	table.active = u16(index + 1)
	return table.active
}

// osc_8_handler parses "<params>;<uri>" payloads and applies them.
osc_8_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term: rawptr) -> bool {
	table := (^Hyperlink_Table)(user_data)
	if table == nil do return false

	semicolon := strings.index_byte(payload, ';')
	uri := payload if semicolon < 0 else payload[semicolon + 1:]
	link_id := hyperlinks_set(table, strings.trim_space(uri))
	if table.set_proc != nil do table.set_proc(term, link_id)
	return true
}
