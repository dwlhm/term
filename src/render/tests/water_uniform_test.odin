package render_tests

import "core:testing"
import instance "../instance"
import gpu "../gpu"

_water_uniform_capture: instance.Uniform_Data
_water_uniform_bytes: u64
_water_uniform_calls: int
_water_capture_write :: proc(queue: gpu.Gpu_Queue, buffer: gpu.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	_water_uniform_bytes = size
	_water_uniform_calls += 1
	_water_uniform_capture = (^instance.Uniform_Data)(data)^
}

@test
test_water_uniform_upload_and_resize_preserve_tail :: proc(t: ^testing.T) {
	backend := gpu.Gpu_Backend_VTable{write_buffer = _water_capture_write}
	r := instance.Instance_Renderer{
		backend = &backend,
		queue = gpu.Gpu_Queue(rawptr(uintptr(1))),
		uniform_buffer = gpu.Gpu_Buffer(rawptr(uintptr(2))),
	}
	r.uniform_data.water_meta = {1, 2, 0, 0}
	r.uniform_data.waves[0] = instance.Water_Wave{origin_age_strength = {100, 150, 0.3, 0.4}, lifetime_params = {2, 0, 0, 0}}
	_water_uniform_calls = 0
	instance.instance_renderer_upload_uniforms(&r)
	testing.expect_value(t, _water_uniform_bytes, u64(size_of(instance.Uniform_Data)))
	testing.expect_value(t, _water_uniform_capture.waves[0].origin_age_strength[0], f32(100))
	instance.instance_renderer_set_screen_size(&r, &backend, 1600, 900)
	testing.expect_value(t, _water_uniform_calls, 2)
	testing.expect_value(t, _water_uniform_capture.screen_w, f32(1600))
	testing.expect_value(t, _water_uniform_capture.water_meta[0], f32(1))
	testing.expect_value(t, _water_uniform_capture.waves[0].origin_age_strength[1], f32(150))
	r.uniform_buffer = gpu.Gpu_Buffer(nil)
	instance.instance_renderer_upload_uniforms(&r)
	testing.expect_value(t, _water_uniform_calls, 2)
}
