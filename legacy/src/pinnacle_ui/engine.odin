package pinnacle_ui

import "core:math"

// Create the Inbound Port implementation that users interact with.
create_ui_service :: proc(engine: ^Core_Engine) -> UI_Service {
	return UI_Service{
		world = &engine.world,
		config = &engine.config,
		
		spawn_panel = proc(svc: ^UI_Service, pos: [3]f32, size: [2]f32, material_id: u32) -> Entity_ID {
			id := ecs_create_entity(svc.world)
			if id == MISSING_ENTITY { return MISSING_ENTITY }

			// 1. Transform Setup
			ecs_set_transform(svc.world, id, pos, size)
			svc.world.transforms[id].scale = {1.0, 1.0}
			svc.world.dirty_transforms[id] = true

			// 2. Material Setup
			svc.world.materials[id].material_id = material_id
			svc.world.materials[id].opacity = 1.0
			svc.world.dirty_materials[id] = true

			// 3. Mark as Panel
			svc.world.glyphs[id].uv_size = {0.0, 0.0}
			svc.world.glyphs[id].color_packed = 0xFFFFFFFF
			svc.world.dirty_glyphs[id] = true

			return id
		},
		
		spawn_text = proc(svc: ^UI_Service, text: string, pos: [2]f32, size: f32, material_id: u32) -> Entity_ID {
			id := ecs_create_entity(svc.world)
			if id == MISSING_ENTITY { return MISSING_ENTITY }
			
			z_index: f32 = 0.5
			ecs_set_transform(svc.world, id, {pos.x, pos.y, z_index}, {size, size})
			svc.world.transforms[id].scale = {1.0, 1.0}
			
			svc.world.glyphs[id].uv_start = {0.0, 0.0}
			svc.world.glyphs[id].uv_size = {0.1, 0.1}
			svc.world.glyphs[id].font_weight = 0.0
			svc.world.glyphs[id].color_packed = 0x00FF00FF
			svc.world.dirty_glyphs[id] = true
			
			svc.world.materials[id].material_id = material_id
			svc.world.materials[id].opacity = 1.0
			svc.world.dirty_materials[id] = true

			return id
		},
		
		tick_frame = proc(svc: ^UI_Service) -> bool {
			return true
		},
	}
}
