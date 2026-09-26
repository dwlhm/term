package pinnacle_ui

import "core:mem"

Entity_ID :: distinct u32

MISSING_ENTITY :: Entity_ID(0xFFFFFFFF)

Transform_Component :: struct #align(16) {
	position:    [3]f32,
	_pad0:       u32,
	size:        [2]f32,
	scale:       [2]f32,
	rotation:    [4]f32,
}

Material_Component :: struct #align(16) {
	material_id: u32,
	opacity:     f32,
	_pad:        [2]u32,
}

Glyph_Component :: struct #align(16) {
	uv_start:    [2]f32,
	uv_size:     [2]f32,
	font_weight: f32,
	color_packed: u32,
	_pad:        [2]u32,
}

ECS_World :: struct {
	next_entity:       Entity_ID,
	active_entities:   u32,
	
	transforms:        []Transform_Component,
	materials:         []Material_Component,
	glyphs:            []Glyph_Component,

	dirty_transforms:  []bool,
	dirty_materials:   []bool,
	dirty_glyphs:      []bool,
}

ecs_init_world :: proc(max_elements: u32) -> ECS_World {
	w := ECS_World{}
	w.next_entity = 0
	w.transforms  = make([]Transform_Component, max_elements)
	w.materials   = make([]Material_Component, max_elements)
	w.glyphs      = make([]Glyph_Component, max_elements)
	
	w.dirty_transforms = make([]bool, max_elements)
	w.dirty_materials  = make([]bool, max_elements)
	w.dirty_glyphs     = make([]bool, max_elements)
	return w
}

ecs_destroy_world :: proc(w: ^ECS_World) {
	delete(w.transforms)
	delete(w.materials)
	delete(w.glyphs)
	delete(w.dirty_transforms)
	delete(w.dirty_materials)
	delete(w.dirty_glyphs)
}

ecs_create_entity :: proc(w: ^ECS_World) -> Entity_ID {
	if w.active_entities >= u32(len(w.transforms)) {
		return MISSING_ENTITY 
	}
	id := w.next_entity
	w.next_entity += 1
	w.active_entities += 1
	return id
}

ecs_set_transform :: proc(w: ^ECS_World, id: Entity_ID, pos: [3]f32, size: [2]f32) {
	w.transforms[id].position = pos
	w.transforms[id].size = size
	w.dirty_transforms[id] = true
}
