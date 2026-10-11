package pinnacle_wgpu_adapter

import pure_ui "../"
import gpu "../../render/gpu"
import "core:fmt"

WGPU_Adapter :: struct {
	is_initialized: bool,
    config:         ^pure_ui.Renderer_Config,

    gpu_backend:    ^gpu.Gpu_Backend_VTable,
    device:         gpu.Gpu_Device,
    queue:          gpu.Gpu_Queue,
    surface:        gpu.Gpu_Surface,

	transform_buffer: gpu.Gpu_Buffer, 
	material_buffer:  gpu.Gpu_Buffer, 
	glyph_buffer:     gpu.Gpu_Buffer, 
	
	render_pipeline:  gpu.Gpu_RenderPipeline,
	bind_group_layout: gpu.Gpu_BindGroupLayout,
	bind_group:       gpu.Gpu_BindGroup,
	shader_module:    gpu.Gpu_ShaderModule,
	
	capacity:         u32,
	active_count:     u32,
}

WGSL_CODE :: `
struct Transform {
    position: vec3f,
    pad0: u32,
    size: vec2f,
    scale: vec2f,
    rotation: vec4f,
}

struct Material {
    material_id: u32,
    opacity: f32,
    pad0: u32,
    pad1: u32,
}

struct Glyph {
    uv_start: vec2f,
    uv_size: vec2f,
    font_weight: f32,
    color_packed: u32,
    pad0: u32,
    pad1: u32,
}

@group(0) @binding(0) var<storage, read> transforms: array<Transform>;
@group(0) @binding(1) var<storage, read> materials: array<Material>;
@group(0) @binding(2) var<storage, read> glyphs: array<Glyph>;

struct VertexOut {
    @builtin(position) position_cs: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
}

@vertex
fn vs_main(@builtin(vertex_index) v_idx: u32, @builtin(instance_index) i_idx: u32) -> VertexOut {
    var out: VertexOut;
    let t = transforms[i_idx];
    let g = glyphs[i_idx];
    let m = materials[i_idx];
    
    var p = vec2f(0.0, 0.0);
    var tex = vec2f(0.0, 0.0);
    
    switch (v_idx % 6u) {
        case 0u: { p = vec2f(0.0, 0.0); tex = vec2f(0.0, 0.0); }
        case 1u: { p = vec2f(1.0, 0.0); tex = vec2f(1.0, 0.0); }
        case 2u: { p = vec2f(0.0, 1.0); tex = vec2f(0.0, 1.0); }
        case 3u: { p = vec2f(1.0, 0.0); tex = vec2f(1.0, 0.0); }
        case 4u: { p = vec2f(1.0, 1.0); tex = vec2f(1.0, 1.0); }
        case 5u: { p = vec2f(0.0, 1.0); tex = vec2f(0.0, 1.0); }
        default: {}
    }
    
    var screen_w = t.rotation.x;
    var screen_h = t.rotation.y;
    if (screen_w < 10.0) { screen_w = 2000.0; screen_h = 1000.0; }
    
    let pos_x = t.position.x + p.x * t.size.x;
    let pos_y = t.position.y + p.y * t.size.y;
    
    let ndc_x = (pos_x / screen_w) * 2.0 - 1.0;
    let ndc_y = 1.0 - (pos_y / screen_h) * 2.0;

    out.position_cs = vec4f(ndc_x, ndc_y, 0.5, 1.0);
    out.uv = g.uv_start + tex * g.uv_size;
    
    // g.color_packed is ARGB (0xAARRGGBB)
    let a = f32((g.color_packed >> 24u) & 0xFFu) / 255.0;
    let r = f32((g.color_packed >> 16u) & 0xFFu) / 255.0;
    let b_green = f32((g.color_packed >> 8u) & 0xFFu) / 255.0;
    let b_blue = f32(g.color_packed & 0xFFu) / 255.0;

    out.color = vec4f(r, b_green, b_blue, select(1.0, a, a > 0.0));
    
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return in.color;
}
`

create_wgpu_port :: proc(
    adapter: ^WGPU_Adapter, 
    backend: ^gpu.Gpu_Backend_VTable, 
    dev: gpu.Gpu_Device, 
    q: gpu.Gpu_Queue,
    surf: gpu.Gpu_Surface,
) -> pure_ui.Renderer_Port {
    adapter.gpu_backend = backend
    adapter.device = dev
    adapter.queue = q
    adapter.surface = surf

	return pure_ui.Renderer_Port{
		adapter_ctx = adapter,
		init_gpu = proc(ctx: rawptr, config: ^pure_ui.Renderer_Config) -> bool {
			a := cast(^WGPU_Adapter)ctx
			a.config = config
			a.is_initialized = true
			
			// Build Shaders and Pipeline

			a.shader_module = a.gpu_backend.create_shader_module(a.device, WGSL_CODE)
			
			format := a.gpu_backend.get_preferred_format(rawptr(a.surface), a.device)
			a.render_pipeline = a.gpu_backend.create_render_pipeline(
			    a.device, 
			    a.shader_module, "vs_main",
			    a.shader_module, "fs_main",
			    nil, 
			    format,
			    .Alpha_Blend,
			    .Triangle_List,
			)
			return true

		},
		allocate_ssbo = proc(ctx: rawptr, capacity: u32) -> bool {
		    a := cast(^WGPU_Adapter)ctx
		    if a.capacity >= capacity do return true
		    
		    a.capacity = capacity
		    
		    a.transform_buffer = a.gpu_backend.create_buffer(a.device, u64(capacity) * size_of(pure_ui.Transform_Component), .Storage | .Copy_Dst, false)
		    a.material_buffer = a.gpu_backend.create_buffer(a.device, u64(capacity) * size_of(pure_ui.Material_Component), .Storage | .Copy_Dst, false)
		    a.glyph_buffer = a.gpu_backend.create_buffer(a.device, u64(capacity) * size_of(pure_ui.Glyph_Component), .Storage | .Copy_Dst, false)
		    

		    bg_entries := [3]gpu.Gpu_Bind_Entry{
		        { binding = 0, buffer = a.transform_buffer, offset = 0, size = u64(capacity) * size_of(pure_ui.Transform_Component), entry_type = .Buffer },
		        { binding = 1, buffer = a.material_buffer, offset = 0, size = u64(capacity) * size_of(pure_ui.Material_Component), entry_type = .Buffer },
		        { binding = 2, buffer = a.glyph_buffer, offset = 0, size = u64(capacity) * size_of(pure_ui.Glyph_Component), entry_type = .Buffer },
		    }
		    
		    layout := a.gpu_backend.pipeline_get_bind_group_layout(a.render_pipeline, 0)
		    a.bind_group = a.gpu_backend.create_bind_group(a.device, layout, bg_entries[:])
		    a.gpu_backend.destroy_bind_group_layout(layout)

		    
            return true
		},
		
		update_transforms = proc(ctx: rawptr, data: []pure_ui.Transform_Component, dirty_flags: []bool) {
		    a := cast(^WGPU_Adapter)ctx
		    if len(data) > 0 {
		        a.gpu_backend.write_buffer(a.queue, a.transform_buffer, 0, raw_data(data), u64(len(data)) * size_of(pure_ui.Transform_Component))
		    }
		},
		update_materials = proc(ctx: rawptr, data: []pure_ui.Material_Component, dirty_flags: []bool) {
		    a := cast(^WGPU_Adapter)ctx
		    if len(data) > 0 {
		        a.gpu_backend.write_buffer(a.queue, a.material_buffer, 0, raw_data(data), u64(len(data)) * size_of(pure_ui.Material_Component))
		    }
		},
		update_glyphs = proc(ctx: rawptr, data: []pure_ui.Glyph_Component, dirty_flags: []bool) {
		    a := cast(^WGPU_Adapter)ctx
		    if len(data) > 0 {
		        a.gpu_backend.write_buffer(a.queue, a.glyph_buffer, 0, raw_data(data), u64(len(data)) * size_of(pure_ui.Glyph_Component))
		    }
		},
		
		dispatch_compute = proc(ctx: rawptr, active_count: u32) {
		    a := cast(^WGPU_Adapter)ctx
		    a.active_count = active_count
		}, // Not needed immediately since Draw overrides
		
		draw_indirect = proc(ctx: rawptr) {
		    a := cast(^WGPU_Adapter)ctx
		    
		    tex, view, _ := a.gpu_backend.get_surface_texture(rawptr(a.surface))
		    if tex == nil do return
		    
		    encoder := a.gpu_backend.create_command_encoder(a.device)
		    
		    
		    
		    pass := a.gpu_backend.begin_render_pass(encoder, view, [4]f64{0.118, 0.118, 0.180, 1.0}, .Clear)
		    a.gpu_backend.render_set_pipeline(pass, a.render_pipeline)
		    a.gpu_backend.render_set_bind_group(pass, 0, a.bind_group)
		    
		    // We use CPU-known total length currently for reliability proof (no active_count strict tracking).
		    a.gpu_backend.render_draw(pass, 6, a.active_count)
		    
		    a.gpu_backend.end_render_pass(pass)
		    
		    cmd_buf := a.gpu_backend.finish_command_buffer(encoder)
		    a.gpu_backend.submit(a.queue, cmd_buf)
		    a.gpu_backend.release_command_buffer(cmd_buf)
		    
		    ok := a.gpu_backend.present_surface(rawptr(a.surface))
		    a.gpu_backend.release_surface_texture(tex, view)
		    if !ok {
		        fmt.eprintf("present_surface failed!\n")
		    }
		    if a.gpu_backend.poll_device != nil {
		        _ = a.gpu_backend.poll_device(a.device, false)
		    }
		},
		destroy = proc(ctx: rawptr) {
		},
	}
}
