package pinnacle_ui

import "core:mem"

UI_Service :: struct {
	world:    ^ECS_World,
	config:   ^Renderer_Config,
	
	spawn_text:  proc(svc: ^UI_Service, text: string, pos: [2]f32, size: f32, material_id: u32) -> Entity_ID,
	spawn_panel: proc(svc: ^UI_Service, pos: [3]f32, size: [2]f32, material_id: u32) -> Entity_ID,
	tick_frame:  proc(svc: ^UI_Service) -> bool,
}

Renderer_Port :: struct {
	adapter_ctx: rawptr, 

	init_gpu:          proc(ctx: rawptr, config: ^Renderer_Config) -> bool,
	allocate_ssbo:     proc(ctx: rawptr, capacity: u32) -> bool,
	
	update_transforms: proc(ctx: rawptr, data: []Transform_Component, dirty_flags: []bool),
	update_materials:  proc(ctx: rawptr, data: []Material_Component, dirty_flags: []bool),
	update_glyphs:     proc(ctx: rawptr, data: []Glyph_Component, dirty_flags: []bool),

	dispatch_compute:  proc(ctx: rawptr, active_count: u32),
	draw_indirect:     proc(ctx: rawptr),
	destroy:           proc(ctx: rawptr),
}

Core_Engine :: struct {
	config:   Renderer_Config,
	world:    ECS_World,
	renderer: ^Renderer_Port,
}

init_engine :: proc(config: Renderer_Config, renderer: ^Renderer_Port) -> ^Core_Engine {
	engine := new(Core_Engine)
	engine.config = config
	engine.renderer = renderer
	engine.world = ecs_init_world(config.max_ui_elements)
	
	if !renderer.init_gpu(renderer.adapter_ctx, &engine.config) {
		return nil
	}
	renderer.allocate_ssbo(renderer.adapter_ctx, config.max_ui_elements)
	return engine
}

engine_tick :: proc(engine: ^Core_Engine) {
	engine.renderer.update_transforms(engine.renderer.adapter_ctx, engine.world.transforms, engine.world.dirty_transforms)
	engine.renderer.update_materials(engine.renderer.adapter_ctx, engine.world.materials, engine.world.dirty_materials)
	engine.renderer.update_glyphs(engine.renderer.adapter_ctx, engine.world.glyphs, engine.world.dirty_glyphs)

	engine.renderer.dispatch_compute(engine.renderer.adapter_ctx, engine.world.active_entities)
	engine.renderer.draw_indirect(engine.renderer.adapter_ctx)
	
	mem.zero_slice(engine.world.dirty_transforms)
	mem.zero_slice(engine.world.dirty_materials)
	mem.zero_slice(engine.world.dirty_glyphs)
}
