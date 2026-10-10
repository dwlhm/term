package three_d

import "core:math"
import "core:math/linalg"

Three_D_Interactor :: struct {
	yaw:            f32,
	pitch:          f32,
	distance:       f32,
	target:         [3]f32,
	is_dragging:    bool,
	last_mouse:     [2]f32,
	auto_rotate:    bool,
	wireframe_mode: bool,
}

interactor_init :: proc(it: ^Three_D_Interactor) {
	if it == nil do return
	it.yaw = 0.75
	it.pitch = 0.45
	it.distance = 4.2
	it.target = [3]f32{0.0, 0.0, 0.0}
	it.is_dragging = false
	it.last_mouse = [2]f32{0.0, 0.0}
	it.auto_rotate = true
	it.wireframe_mode = false
}

interactor_on_mouse_down :: proc(it: ^Three_D_Interactor, x, y: f32, button: int) {
	if it == nil do return
	if button == 1 {
		it.is_dragging = true
		it.last_mouse = [2]f32{x, y}
	}
}

interactor_on_mouse_up :: proc(it: ^Three_D_Interactor, button: int) {
	if it == nil do return
	if button == 1 {
		it.is_dragging = false
	}
}

interactor_on_mouse_move :: proc(it: ^Three_D_Interactor, x, y: f32, shift: bool) {
	if it == nil || !it.is_dragging do return

	dx := x - it.last_mouse[0]
	dy := y - it.last_mouse[1]
	it.last_mouse = [2]f32{x, y}

	if shift {
		pan_speed: f32 = 0.004 * it.distance
		it.target[0] -= dx * pan_speed
		it.target[1] += dy * pan_speed
	} else {
		rot_speed: f32 = 0.007
		it.yaw += dx * rot_speed
		it.pitch += dy * rot_speed

		max_pitch: f32 = 1.48 // ~85 deg
		if it.pitch > max_pitch do it.pitch = max_pitch
		if it.pitch < -max_pitch do it.pitch = -max_pitch
	}
}

interactor_on_mouse_wheel :: proc(it: ^Three_D_Interactor, dy: f32) {
	if it == nil do return
	zoom_speed: f32 = 0.4
	it.distance -= dy * zoom_speed
	if it.distance < 1.5 do it.distance = 1.5
	if it.distance > 25.0 do it.distance = 25.0
}

interactor_update :: proc(it: ^Three_D_Interactor, dt: f32) {
	if it == nil do return
	if it.auto_rotate && !it.is_dragging {
		it.yaw += 0.6 * dt
	}
}

matrix4_perspective_webgpu :: proc(fovy, aspect, near, far: f32) -> matrix[4, 4]f32 {
	tan_half := math.tan(0.5 * fovy)
	m: matrix[4, 4]f32
	m[0, 0] = 1.0 / (aspect * tan_half)
	m[1, 1] = 1.0 / tan_half
	m[2, 2] = far / (near - far)
	m[2, 3] = (near * far) / (near - far)
	m[3, 2] = -1.0
	return m
}

interactor_compute_uniforms :: proc(it: ^Three_D_Interactor, viewport_w, viewport_h: f32, time: f32) -> Component3D_Uniforms {
	u: Component3D_Uniforms

	w := max(f32(1.0), viewport_w)
	h := max(f32(1.0), viewport_h)
	aspect := w / h

	eye_x := it.target[0] + it.distance * math.cos(it.pitch) * math.sin(it.yaw)
	eye_y := it.target[1] + it.distance * math.sin(it.pitch)
	eye_z := it.target[2] + it.distance * math.cos(it.pitch) * math.cos(it.yaw)
	eye := [3]f32{eye_x, eye_y, eye_z}
	center := it.target
	up := [3]f32{0.0, 1.0, 0.0}

	view := linalg.matrix4_look_at(eye, center, up)
	base_fov := f32(math.to_radians(f32(45.0)))
	fovy := base_fov
	if aspect < 1.0 {
		fovy = 2.0 * math.atan(math.tan(base_fov * 0.5) / aspect)
	}
	proj := matrix4_perspective_webgpu(fovy, aspect, 0.1, 100.0)

	model: matrix[4, 4]f32 = 1.0

	pv := proj * view
	mvp := pv * model
	normal_mat := linalg.matrix4_inverse_transpose(model)

	u.mvp = mvp
	u.model = model
	u.normal_mat = normal_mat

	u.light_pos = [4]f32{eye_x + 3.0, eye_y + 5.0, eye_z + 4.0, 1.0}
	u.view_pos = [4]f32{eye_x, eye_y, eye_z, 1.0}
	u.ambient_color = [4]f32{0.18, 0.22, 0.32, 1.0}
	u.light_color = [4]f32{1.0, 0.98, 0.92, 1.0}

	u.time = time
	u.metallic = 0.6
	u.roughness = 0.3
	u.wireframe = 1.0 if it.wireframe_mode else 0.0

	return u
}
