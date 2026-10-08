package session_ipc_test

import "core:testing"
import "core:encoding/endian"
import ipc "../"

sample_frame :: proc() -> ipc.Frame {
	return {
		header = {major = ipc.PROTOCOL_MAJOR, minor = ipc.PROTOCOL_MINOR, kind = .Input,
			request_id = 0x0807060504030201, stream_id = 0x1817161514131211, sequence = 0x2827262524232221},
		payload = transmute([]u8)string("\x00\xFFB"),
	}
}

@(test)
test_header_golden_and_borrowed_roundtrip :: proc(t: ^testing.T) {
	frame := sample_frame()
	buf: [64]u8
	n, status := ipc.encode_frame(buf[:], frame)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	golden := []u8{'T', 'E', 'R', 'M', 1, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0,
		1, 2, 3, 4, 5, 6, 7, 8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
		0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0, 0xFF, 0x42}
	testing.expect_value(t, n, len(golden))
	for b, i in golden do testing.expect_value(t, buf[i], b)
	decoded, consumed, decoded_status := ipc.decode_frame(buf[:n])
	testing.expect_value(t, decoded_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, n)
	testing.expect_value(t, decoded.header, frame.header)
	testing.expect(t, raw_data(decoded.payload) == &buf[ipc.FRAME_HEADER_BYTES])
	buf[ipc.FRAME_HEADER_BYTES] = 0x77
	testing.expect_value(t, decoded.payload[0], u8(0x77))
}

@(test)
test_concatenated_frames_and_all_truncations :: proc(t: ^testing.T) {
	buf: [128]u8
	n, _ := ipc.encode_frame(buf[:], sample_frame())
	m, _ := ipc.encode_frame(buf[n:], {header = {major = ipc.PROTOCOL_MAJOR, kind = .Ack}})
	for cut in 0..<n {
		frame, consumed, status := ipc.decode_frame(buf[:cut])
		testing.expect_value(t, status, ipc.Codec_Status.Incomplete)
		testing.expect_value(t, consumed, 0)
		testing.expect_value(t, len(frame.payload), 0)
	}
	first, used, status := ipc.decode_frame(buf[:n+m])
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, used, n)
	testing.expect_value(t, first.header.kind, ipc.Message_Kind.Input)
	second, used_second, second_status := ipc.decode_frame(buf[used:n+m])
	testing.expect_value(t, second_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, used_second, m)
	testing.expect_value(t, second.header.kind, ipc.Message_Kind.Ack)
}

@(test)
test_invalid_headers_and_malicious_sizes :: proc(t: ^testing.T) {
	buf: [64]u8
	_, _ = ipc.encode_frame(buf[:], sample_frame())
	buf[0] = 0
	_, consumed, status := ipc.decode_frame(buf[:ipc.FRAME_HEADER_BYTES])
	testing.expect_value(t, status, ipc.Codec_Status.Malformed)
	testing.expect_value(t, consumed, 0)
	_, _ = ipc.encode_frame(buf[:], sample_frame())
	endian.unchecked_put_u16le(buf[4:6], ipc.PROTOCOL_MAJOR+1)
	_, _, status = ipc.decode_frame(buf[:ipc.FRAME_HEADER_BYTES])
	testing.expect_value(t, status, ipc.Codec_Status.Unsupported_Version)
	_, _ = ipc.encode_frame(buf[:], sample_frame())
	for invalid in ([]u16{0, u16(ipc.Message_Kind.Credit)+1, 0xFFFF}) {
		endian.unchecked_put_u16le(buf[8:10], invalid)
		_, consumed, status = ipc.decode_frame(buf[:ipc.FRAME_HEADER_BYTES])
		testing.expect_value(t, status, ipc.Codec_Status.Unsupported_Kind)
		testing.expect_value(t, consumed, 0)
	}
	_, _ = ipc.encode_frame(buf[:], sample_frame())
	for bit in 0..<16 {
		endian.unchecked_put_u16le(buf[10:12], u16(1)<<uint(bit))
		_, _, status = ipc.decode_frame(buf[:ipc.FRAME_HEADER_BYTES])
		testing.expect_value(t, status, ipc.Codec_Status.Unsupported_Flags)
	}
	_, _ = ipc.encode_frame(buf[:], sample_frame())
	for malicious in ([]u32{u32(ipc.MAX_PAYLOAD_BYTES)+1, 0x7FFFFFFF, 0xFFFFFFFF}) {
		endian.unchecked_put_u32le(buf[12:16], malicious)
		_, consumed, status = ipc.decode_frame(buf[:ipc.FRAME_HEADER_BYTES])
		testing.expect_value(t, status, ipc.Codec_Status.Limit_Exceeded)
		testing.expect_value(t, consumed, 0)
	}
}

@(test)
test_encoder_failure_does_not_mutate_destination :: proc(t: ^testing.T) {
	buf: [64]u8
	for &b in buf[:] do b = 0xA5
	frame := sample_frame()
	for cut in 0..<ipc.FRAME_HEADER_BYTES+len(frame.payload) {
		n, status := ipc.encode_frame(buf[:cut], frame)
		testing.expect_value(t, n, 0)
		testing.expect_value(t, status, ipc.Codec_Status.Destination_Too_Small)
	}
	invalid := frame
	invalid.header.major += 1
	_, status := ipc.encode_frame(buf[:], invalid)
	testing.expect_value(t, status, ipc.Codec_Status.Unsupported_Version)
	invalid = frame
	invalid.header.kind = ipc.Message_Kind(0)
	_, status = ipc.encode_frame(buf[:], invalid)
	testing.expect_value(t, status, ipc.Codec_Status.Unsupported_Kind)
	invalid = frame
	invalid.header.flags = 1
	_, status = ipc.encode_frame(buf[:], invalid)
	testing.expect_value(t, status, ipc.Codec_Status.Unsupported_Flags)
	oversized := make([]u8, ipc.MAX_PAYLOAD_BYTES+1)
	defer delete(oversized)
	invalid = frame
	invalid.payload = oversized
	_, status = ipc.encode_frame(buf[:], invalid)
	testing.expect_value(t, status, ipc.Codec_Status.Limit_Exceeded)
	for b in buf do testing.expect_value(t, b, u8(0xA5))
}

@(test)
test_exact_limit_and_same_major_minor_compatibility :: proc(t: ^testing.T) {
	buf := make([]u8, ipc.MAX_FRAME_BYTES)
	defer delete(buf)
	payload := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(payload)
	frame := sample_frame()
	frame.header.minor = ipc.PROTOCOL_MINOR+1
	frame.payload = payload
	n, status := ipc.encode_frame(buf, frame)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, n, ipc.MAX_FRAME_BYTES)
	decoded, consumed, decoded_status := ipc.decode_frame(buf)
	testing.expect_value(t, decoded_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, n)
	testing.expect_value(t, len(decoded.payload), ipc.MAX_PAYLOAD_BYTES)
	for kind := ipc.Message_Kind.Hello; kind <= .Credit; kind = ipc.Message_Kind(u16(kind)+1) {
		frame.header.kind = kind
		frame.payload = nil
		n, status = ipc.encode_frame(buf, frame)
		testing.expect_value(t, status, ipc.Codec_Status.Ok)
		decoded, consumed, decoded_status = ipc.decode_frame(buf[:n])
		testing.expect_value(t, decoded_status, ipc.Codec_Status.Ok)
		testing.expect_value(t, consumed, n)
		testing.expect_value(t, decoded.header.kind, kind)
	}
}
