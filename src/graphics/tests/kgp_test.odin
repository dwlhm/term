package graphics_tests

import "core:testing"
import "core:c"
import "core:fmt"
import "core:strings"
import posix "core:sys/posix"
import graphics ".."

GRAPHICS_TEST_RESPONSE_CAP :: 256

Response_Capture :: struct {
	data:  [GRAPHICS_TEST_RESPONSE_CAP]u8,
	len:   int,
	calls: int,
}

GRAPHICS_TEST_PNG :: [?]u8{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
	0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
	0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54,
	0x78, 0x9c, 0x63, 0xe0, 0x12, 0x91, 0xd3, 0x00,
	0x00, 0x00, 0xcd, 0x00, 0x65, 0x6a, 0x99, 0x84, 0x42,
	0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
	0xae, 0x42, 0x60, 0x82,
}

GRAPHICS_TEST_PNG_BASE64 :: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPgEpHTAAAAzQBlapmEQgAAAABJRU5ErkJggg=="

_graphics_capture_write :: proc(user_data: rawptr, data: []u8) {
	capture := cast(^Response_Capture)user_data
	if capture == nil do return
	n := min(len(data), len(capture.data))
	copy(capture.data[:n], data[:n])
	capture.len = n
	capture.calls += 1
}

_graphics_capture_reset :: proc(capture: ^Response_Capture) {
	if capture == nil do return
	capture.len = 0
	capture.calls = 0
}

_graphics_sink :: proc(capture: ^Response_Capture) -> graphics.Response_Sink {
	return graphics.Response_Sink{
		user_data = rawptr(capture),
		write = _graphics_capture_write,
	}
}

_graphics_bytes :: proc(text: string) -> []u8 {
	return transmute([]u8)text
}

_graphics_context :: proc() -> graphics.Feed_Context {
	return graphics.Feed_Context{
		cursor_row = 7,
		cursor_col = 11,
		grid_rows = 24,
		grid_cols = 80,
		allocator = context.allocator,
	}
}

_graphics_expect_bytes :: proc(t: ^testing.T, got, want: []u8, message: string) {
	if !testing.expect(t, len(got) == len(want), message) do return
	for i in 0..<len(want) {
		if !testing.expect(t, got[i] == want[i], message) do return
	}
}

_graphics_feed :: proc(
	store: ^graphics.Store,
	ctx: graphics.Feed_Context,
	capture: ^Response_Capture,
	control, payload: string,
) -> graphics.Feed_Result {
	return graphics.store_feed(
		store,
		ctx,
		transmute([]u8)control,
		transmute([]u8)payload,
		_graphics_sink(capture),
	)
}

_graphics_create_shm :: proc(name: string, data: []u8) -> bool {
	c_name, name_err := strings.clone_to_cstring(name)
	if name_err != nil do return false
	defer delete(c_name)
	when ODIN_OS == .Darwin {
		fd := posix.shm_open(c_name, {.CREAT, .EXCL, .RDWR}, posix.mode_t{ .IRUSR, .IWUSR })
		if fd < 0 do return false
		ok := posix.ftruncate(fd, posix.off_t(len(data))) == .OK
		if ok && len(data) > 0 {
			mapping := posix.mmap(nil, c.size_t(len(data)), {.READ, .WRITE}, {.SHARED}, fd, 0)
			if mapping == nil || mapping == posix.MAP_FAILED {
				ok = false
			} else {
				copy(([^]u8)(mapping)[:len(data)], data)
				ok = posix.munmap(mapping, c.size_t(len(data))) == .OK
			}
		}
		ok = posix.close(fd) == .OK && ok
		if !ok { _ = posix.shm_unlink(c_name) }
		return ok
	} else {
		fd := posix.shm_open(c_name, {.CREAT, .EXCL, .RDWR}, posix.mode_t{ .IRUSR, .IWUSR })
		if fd < 0 do return false
		ok := posix.ftruncate(fd, posix.off_t(len(data))) == .OK
		if ok && len(data) > 0 {
			mapping := posix.mmap(nil, c.size_t(len(data)), {.READ, .WRITE}, {.SHARED}, fd, 0)
			if mapping == nil || mapping == posix.MAP_FAILED {
				ok = false
			} else {
				copy(([^]u8)(mapping)[:len(data)], data)
				ok = posix.munmap(mapping, c.size_t(len(data))) == .OK
			}
		}
		ok = posix.close(fd) == .OK && ok
		if !ok { _ = posix.shm_unlink(c_name) }
		return ok
	}
}

@(test)
test_graphics_control_parse :: proc(t: ^testing.T) {
	control: graphics.Control
	input := "a=T,f=100,s=10,v=20,i=5"
	ok := graphics.kgp_parse_control(transmute([]u8)input, &control)

	testing.expect(t, ok, "valid control must parse")
	testing.expect_value(t, control.action, graphics.Action.Transmit_Put)
	testing.expect_value(t, control.format, graphics.Format.PNG)
	testing.expect_value(t, control.src_w, u32(10))
	testing.expect_value(t, control.src_h, u32(20))
	testing.expect_value(t, control.id, u32(5))

	malformed := "a=T,broken"
	testing.expect(t, !graphics.kgp_parse_control(transmute([]u8)malformed, &control), "malformed control must be rejected")
}

@(test)
test_graphics_base64_decode :: proc(t: ^testing.T) {
	decoded: [16]u8
	known_input := "SGVsbG8="
	n, ok := graphics.base64_decode(decoded[:], transmute([]u8)known_input)

	testing.expect(t, ok, "known base64 input must decode")
	testing.expect_value(t, n, 5)
	_graphics_expect_bytes(t, decoded[:n], _graphics_bytes("Hello"), "known base64 output must match")

	invalid := "SGVsbG8!"
	_, invalid_ok := graphics.base64_decode(decoded[:], transmute([]u8)invalid)
	testing.expect(t, !invalid_ok, "invalid base64 must be rejected")
}

@(test)
test_graphics_assembly_chunks :: proc(t: ^testing.T) {
	assembly: graphics.Assembly
	first_control := "a=t,f=24,s=3,v=1,m=1"
	complete, result := graphics.assembly_feed(
		&assembly,
		transmute([]u8)first_control,
		_graphics_bytes("AQID"),
	)
	testing.expect(t, !complete && result == .Ok, "first chunk must leave an active assembly")

	complete, result = graphics.assembly_feed(&assembly, _graphics_bytes("m=1"), _graphics_bytes("BAUG"))
	testing.expect(t, !complete && result == .Ok, "middle chunk must leave an active assembly")

	complete, result = graphics.assembly_feed(&assembly, _graphics_bytes("m=0"), _graphics_bytes("BwgJ"))
	testing.expect(t, complete && result == .Ok, "final chunk must complete the assembly")
	_graphics_expect_bytes(t, assembly.buf[:], []u8{1, 2, 3, 4, 5, 6, 7, 8, 9}, "chunks must assemble in order")
	graphics.assembly_reset(&assembly)

	complete, result = graphics.assembly_feed(&assembly, _graphics_bytes("m=1"), _graphics_bytes("AQ=="))
	testing.expect(t, complete && result == .Invalid, "continuation without an active assembly must be rejected")
	graphics.assembly_reset(&assembly)
}

@(test)
test_graphics_decode_raw_rgb :: proc(t: ^testing.T) {
	payload := []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	image, result := graphics.decode_raw(payload, 2, 2, graphics.DECODE_RGB_CHANNELS, context.allocator)

	testing.expect(t, result == .Ok, "valid raw RGB must decode")
	testing.expect_value(t, image.width, 2)
	testing.expect_value(t, image.height, 2)
	_graphics_expect_bytes(
		t,
		image.data,
		[]u8{1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255},
		"raw RGB must expand to RGBA",
	)
	delete(image.data, context.allocator)

	invalid, invalid_result := graphics.decode_raw(payload[:len(payload)-1], 2, 2, graphics.DECODE_RGB_CHANNELS, context.allocator)
	testing.expect(t, invalid_result == .Invalid && invalid.data == nil, "invalid raw length must be rejected")
}

@(test)
test_graphics_decode_png_rgba :: proc(t: ^testing.T) {
	png := GRAPHICS_TEST_PNG
	image, result := graphics.decode_png(png[:], context.allocator)
	testing.expect(t, result == .Ok, "minimal PNG must decode")
	testing.expect_value(t, image.width, 1)
	testing.expect_value(t, image.height, 1)
	_graphics_expect_bytes(t, image.data, []u8{10, 20, 30, 40}, "PNG must decode to expected RGBA bytes")
	delete(image.data, context.allocator)
}

@(test)
test_graphics_response_ok_bytes :: proc(t: ^testing.T) {
	buffer: [GRAPHICS_TEST_RESPONSE_CAP]u8
	response := graphics.kgp_format_response(buffer[:], u32(5), .Ok)
	want := "\x1b_Gi=5;OK\x1b\\"
	_graphics_expect_bytes(t, response, transmute([]u8)want, "OK response bytes must be exact")
}

@(test)
test_graphics_store_lifecycle_and_placement :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	result := _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,i=7", "AQID")
	testing.expect(t, result == .Ok, "transmit must succeed")
	image := graphics.store_find_image(&store, u32(7), 0)
	testing.expect(t, image != nil, "transmitted image must be findable")
	if image != nil {
		testing.expect_value(t, image.id, u32(7))
		testing.expect_value(t, image.frames[0].width, 1)
		testing.expect_value(t, image.frames[0].height, 1)
		_graphics_expect_bytes(t, image.frames[0].data, []u8{1, 2, 3, 255}, "stored raw pixels must be owned by the image")
	}

	_graphics_capture_reset(&capture)
	result = _graphics_feed(&store, ctx, &capture, "a=p,i=7,p=9,c=2,r=3", "")
	testing.expect(t, result == .Ok, "put must place an existing image")
	placement := graphics.store_find_placement(&store, 7, 0, 9)
	testing.expect(t, placement != nil, "placement must be findable")
	if placement != nil {
		testing.expect_value(t, placement.image_id, u32(7))
		testing.expect_value(t, placement.placement_id, u32(9))
		testing.expect_value(t, placement.row, 7)
		testing.expect_value(t, placement.col, 11)
	}

	_graphics_capture_reset(&capture)
	result = _graphics_feed(&store, ctx, &capture, "a=d,d=f,p=9", "")
	testing.expect(t, result == .Ok, "placement deletion must succeed")
	testing.expect(t, graphics.store_find_placement(&store, 7, 0, 9) == nil, "deleted placement must not be findable")
	testing.expect(t, graphics.store_find_image(&store, 7, 0) != nil, "placement deletion must retain the image")

	_graphics_capture_reset(&capture)
	result = _graphics_feed(&store, ctx, &capture, "a=d,d=I,i=7", "")
	testing.expect(t, result == .Ok, "image deletion must succeed")
	testing.expect(t, graphics.store_find_image(&store, 7, 0) == nil, "deleted image must not be findable")
	graphics.store_destroy(&store, context.allocator)
}

@(test)
test_graphics_store_dynamic_kgp_placements_and_sync :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	defer graphics.store_destroy(&store, context.allocator)
	ctx := _graphics_context()
	capture: Response_Capture
	store.images[0] = graphics.Image_Slot{used = true, id = 7, number = 1, generation = 1, frame_count = 1, current_frame = 0}
	store.images[0].frames[0] = graphics.Frame{width = 512, height = 1}
	store.image_count = 1

	KGp_TEST_PLACEMENT_COUNT :: 200
	for index in 0..<KGp_TEST_PLACEMENT_COUNT {
		placement_id := u32(index + 1)
		control := fmt.tprintf("a=p,i=7,p=%d,c=1,r=1,x=%d,y=0,w=1,h=1", placement_id, index)
		defer delete(control, context.temp_allocator)
		ctx.cursor_col = index
		result := _graphics_feed(&store, ctx, &capture, control, "")
		if !testing.expect(t, result == .Ok, "each one-cell KGP placement must be accepted") do return
	}
	testing.expect_value(t, store.placement_count, KGp_TEST_PLACEMENT_COUNT)
	last := graphics.store_find_placement(&store, 7, 0, u32(KGp_TEST_PLACEMENT_COUNT))
	testing.expect(t, last != nil, "placement beyond the former inline capacity must remain stored")
	if last != nil {
		testing.expect_value(t, last.src_x, u32(KGp_TEST_PLACEMENT_COUNT-1))
		testing.expect_value(t, last.src_w, u32(1))
	}

	snapshot: graphics.Store
	graphics.store_init(&snapshot)
	defer graphics.store_destroy(&snapshot, context.allocator)
	graphics.store_sync(&snapshot, &store, context.allocator)
	copied := graphics.store_find_placement(&snapshot, 7, 0, u32(KGp_TEST_PLACEMENT_COUNT))
	testing.expect(t, copied != nil, "snapshot must include placements after dynamic growth")
	if copied != nil && last != nil {
		testing.expect(t, rawptr(copied) != rawptr(last), "snapshot placements must not alias source backing")
		testing.expect_value(t, copied.src_x, last.src_x)
	}
	previous_snapshot_backing := rawptr(&snapshot.placements[0])
	graphics.store_sync(&snapshot, &store, context.allocator)
	testing.expect(t, rawptr(&snapshot.placements[0]) != previous_snapshot_backing, "snapshot replacement must allocate independent backing before releasing the old copy")
	graphics.store_clear_placements(&snapshot)
	testing.expect_value(t, len(snapshot.placements), 0)
	graphics.store_sync(&snapshot, &store, context.allocator)
	copied = graphics.store_find_placement(&snapshot, 7, 0, u32(KGp_TEST_PLACEMENT_COUNT))
	testing.expect(t, copied != nil, "snapshot replacement must restore independent placement backing")
}

@(test)
test_graphics_transmit_put_grows_full_placement_storage :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	defer graphics.store_destroy(&store, context.allocator)
	ctx := _graphics_context()
	capture: Response_Capture
	store.images[0] = graphics.Image_Slot{used = true, id = 7, number = 1, generation = 1, frame_count = 1, current_frame = 0}
	store.images[0].frames[0] = graphics.Frame{width = 512, height = 1}
	store.image_count = 1

	for index in 0..<200 {
		placement_id := u32(index + 1)
		control := fmt.tprintf("a=p,i=7,p=%d,c=1,r=1,x=%d,y=0,w=1,h=1", placement_id, index)
		defer delete(control, context.temp_allocator)
		ctx.cursor_col = index
		if !testing.expect(t, _graphics_feed(&store, ctx, &capture, control, "") == .Ok, "placement setup must succeed") do return
	}
	previous_capacity := len(store.placements)
	for index := store.placement_count; index < previous_capacity; index += 1 {
		placement_id := u32(index + 1)
		control := fmt.tprintf("a=p,i=7,p=%d,c=1,r=1,x=%d,y=0,w=1,h=1", placement_id, index)
		defer delete(control, context.temp_allocator)
		ctx.cursor_col = index
		if !testing.expect(t, _graphics_feed(&store, ctx, &capture, control, "") == .Ok, "placement capacity must be fillable") do return
	}
	if !testing.expect(t, store.placement_count == previous_capacity, "placement backing must be full before transmitted placement") do return

	png_payload := _graphics_bytes(GRAPHICS_TEST_PNG_BASE64)
	transmit_control := _graphics_bytes("a=T,f=100,s=1,v=1,i=9,p=999,c=1,r=1,w=1,h=1")
	result := graphics.store_feed(
		&store,
		ctx,
		transmit_control,
		png_payload,
		_graphics_sink(&capture),
	)
	if !testing.expect(t, result == .Ok, "transmit-put must grow full placement storage and succeed") do return
	if !testing.expect(t, len(store.placements) > previous_capacity, "transmit-put must grow beyond prior placement capacity") do return
	image := graphics.store_find_image(&store, 9, 0)
	placement := graphics.store_find_placement(&store, 9, 0, 999)
	testing.expect(t, image != nil, "transmitted image must be installed")
	testing.expect(t, placement != nil, "transmitted image placement must be installed")

	grown_capacity := len(store.placements)
	result = graphics.store_feed(
		&store,
		ctx,
		transmit_control,
		png_payload,
		_graphics_sink(&capture),
	)
	testing.expect(t, result == .Ok, "repeated placement ID must remain accepted")
	testing.expect_value(t, len(store.placements), grown_capacity)

	graphics.store_destroy(&store, context.allocator)
	testing.expect(t, store.placements == nil, "store destruction must release placement backing")
}

@(test)
test_graphics_store_delete_all_and_by_id :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,i=1", "AQID") == .Ok, "first image setup must succeed")
	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,i=2", "AQID") == .Ok, "second image setup must succeed")
	testing.expect_value(t, store.image_count, 2)

	_graphics_capture_reset(&capture)
	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=d,d=A", "") == .Ok, "delete all must succeed")
	testing.expect_value(t, store.image_count, 0)
	testing.expect(t, graphics.store_find_image(&store, 1, 0) == nil, "delete all must remove first image")
	testing.expect(t, graphics.store_find_image(&store, 2, 0) == nil, "delete all must remove second image")

	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,i=3", "AQID") == .Ok, "replacement image setup must succeed")
	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=d,d=I,i=3", "") == .Ok, "delete by id must succeed")
	testing.expect(t, graphics.store_find_image(&store, 3, 0) == nil, "delete by id must remove the selected image")
	graphics.store_destroy(&store, context.allocator)
}

@(test)
test_graphics_store_query_does_not_count :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	result := _graphics_feed(&store, ctx, &capture, "a=q,f=24,s=1,v=1", "AQID")
	testing.expect(t, result == .Ok, "valid query payload must decode")
	testing.expect_value(t, store.image_count, 0)

	result = _graphics_feed(&store, ctx, &capture, "a=q,f=24,s=1,v=1", "AQI")
	testing.expect(t, result == .Invalid, "invalid query payload must be rejected")
	testing.expect_value(t, store.image_count, 0)
	graphics.store_destroy(&store, context.allocator)
}

@(test)
test_graphics_store_assigns_id_for_number :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	result := _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,I=13", "AQID")
	testing.expect(t, result == .Ok, "numbered transmit must succeed")
	image := graphics.store_find_image(&store, 0, 13)
	testing.expect(t, image != nil, "numbered image must be findable")
	if image != nil {
		testing.expect(t, image.id != 0, "numbered transmit must allocate an id")
		testing.expect_value(t, image.number, u32(13))
		expected_buffer: [GRAPHICS_TEST_RESPONSE_CAP]u8
		expected := graphics.kgp_format_response(expected_buffer[:], image.id, .Ok)
		_graphics_expect_bytes(t, capture.data[:capture.len], expected, "response must include the assigned id")
	}
	graphics.store_destroy(&store, context.allocator)
}

@(test)
test_graphics_store_quiet_success_has_no_response :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	result := _graphics_feed(&store, ctx, &capture, "a=q,f=24,s=1,v=1,q=2", "AQID")
	testing.expect(t, result == .Ok, "quiet valid query must succeed")
	testing.expect_value(t, capture.calls, 0)
	testing.expect_value(t, capture.len, 0)
	graphics.store_destroy(&store, context.allocator)
}

@(test)
test_graphics_store_clear_and_destroy_lifecycle :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	result := _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,i=4,m=1", "AQID")
	testing.expect(t, result == .Ok, "partial transmission must be accepted")
	testing.expect(t, store.assembly.active, "partial transmission must retain assembly state")

	graphics.store_clear(&store, context.allocator)
	testing.expect_value(t, store.image_count, 0)
	testing.expect(t, !store.assembly.active, "clear must release active assembly")
	graphics.store_destroy(&store, context.allocator)
	graphics.store_destroy(&store, context.allocator)
}

@(test)
test_graphics_shared_memory_medium_and_bounds :: proc(t: ^testing.T) {
	shared_name := "/term-kgp-shm-test"
	shared_data := []u8{1, 2, 3}
	testing.expect(t, _graphics_create_shm(shared_name, shared_data), "shared-memory fixture must be created")

	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture
	result := _graphics_feed(&store, ctx, &capture, "a=t,f=24,s=1,v=1,t=s,S=3,i=31", "L3Rlcm0ta2dwLXNobS10ZXN0")
	testing.expect(t, result == .Ok, "shared-memory image must decode and install")
	image := graphics.store_find_image(&store, 31, 0)
	if image != nil {
		_graphics_expect_bytes(t, image.frames[0].data, []u8{1, 2, 3, 255}, "shared-memory pixels must be copied into owned storage")
	}
	graphics.store_destroy(&store, context.allocator)

	bad_name := "/term-kgp-shm-bounds"
	testing.expect(t, _graphics_create_shm(bad_name, []u8{4, 5, 6}), "bounds fixture must be created")
	bounds_offset := u32(posix.sysconf(._PAGESIZE)) - 1
	bounds_size := u32(len(shared_data)) - 1
	_, bad_result := graphics.read_shared_memory(transmute([]u8)bad_name, bounds_offset, bounds_size, context.allocator)
	testing.expect(t, bad_result == .Invalid, "shared-memory bounds must be rejected")
}

@(test)
test_graphics_animation_frames_and_composition :: proc(t: ^testing.T) {
	store: graphics.Store
	graphics.store_init(&store)
	ctx := _graphics_context()
	capture: Response_Capture

	root_control := "a=t,f=32,s=2,v=1,i=21"
	root_payload := "ChQe/2RueP8="
	testing.expect(t, _graphics_feed(&store, ctx, &capture, root_control, root_payload) == .Ok, "animation root must install")
	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=f,i=21,f=32,s=2,v=1", "yAAAgAAAAAA=") == .Ok, "animation frame must append")
	image := graphics.store_find_image(&store, 21, 0)
	if image != nil {
		testing.expect_value(t, image.frame_count, 2)
		testing.expect_value(t, image.frames[1].gap_ms, i32(graphics.KGP_DEFAULT_FRAME_GAP_MS))
	}

	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=a,i=21,c=2,s=3,v=1", "") == .Ok, "animation control must update current frame and play state")
	if image != nil {
		testing.expect_value(t, image.current_frame, 1)
		testing.expect_value(t, image.animation_state, graphics.Animation_State.Running)
		testing.expect_value(t, image.animation_loops, u32(1))
	}
	testing.expect(t, _graphics_feed(&store, ctx, &capture, "a=a,i=21,r=2,z=-1", "") == .Ok, "animation gap control must update a frame")
	if image != nil {
		testing.expect_value(t, image.frames[1].gap_ms, i32(-1))
	}

	result := _graphics_feed(&store, ctx, &capture, "a=c,i=21,r=2,c=1,X=0,Y=0,x=0,y=0,w=1,h=1", "")
	testing.expect(t, result == .Ok, "alpha composition must succeed")
	if image != nil {
		_graphics_expect_bytes(t, image.frames[0].data[:4], []u8{105, 10, 15, 255}, "alpha composition must preserve source-over semantics")
	}
	result = _graphics_feed(&store, ctx, &capture, "a=c,i=21,r=2,c=1,X=0,Y=0,x=1,y=0,w=1,h=1,C=1", "")
	testing.expect(t, result == .Ok, "replacement composition must succeed")
	if image != nil {
		_graphics_expect_bytes(t, image.frames[0].data[4:8], []u8{200, 0, 0, 128}, "replacement composition must copy source pixels")
	}
	result = _graphics_feed(&store, ctx, &capture, "a=c,i=21,r=99,c=1,w=1,h=1", "")
	testing.expect(t, result == .NotFound, "missing compose frame must be rejected")
	result = _graphics_feed(&store, ctx, &capture, "a=c,i=21,r=1,c=1,x=0,y=0,X=0,Y=0,w=2,h=1", "")
	testing.expect(t, result == .Invalid, "overlapping same-frame composition must be rejected")
	graphics.store_destroy(&store, context.allocator)
}
