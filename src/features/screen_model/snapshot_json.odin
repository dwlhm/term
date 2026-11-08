package feature_screen_model

// Snapshots saved by `term auto snapshot --save` (JSON, enum names), for
// adapter tests (term.screen.load) and golden files.

import "core:encoding/json"
import "core:os"
import proto "../session_proto"

snapshot_load :: proc(path: string, allocator := context.allocator) -> (snap: proto.Snapshot, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil do return
	return snapshot_parse(data, allocator)
}

snapshot_parse :: proc(data: []u8, allocator := context.allocator) -> (snap: proto.Snapshot, ok: bool) {
	if json.unmarshal(data, &snap, allocator = allocator) != nil do return {}, false
	return snap, int(snap.cols) > 0 && int(snap.rows) > 0 && len(snap.screen) <= int(snap.rows)
}
