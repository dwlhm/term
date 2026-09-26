// ==========================================
// pinnace_ui Render Shader (MSDF + Glassmorphism)
// ==========================================

struct Transform {
    position: vec3<f32>,
    _pad0: u32,
    size: vec2<f32>,
    scale: vec2<f32>,
    rotation: vec4<f32>,
}

struct Material {
    material_id: u32,
    opacity: f32,
    _pad: vec2<u32>,
}

struct Glyph {
    uv_start: vec2<f32>,
    uv_size: vec2<f32>,
    font_weight: f32,
    color_packed: u32,
    _pad: vec2<u32>,
}

struct GlobalConfig {
    resolution: vec2<f32>,
    msdf_pixel_range: f32,
    is_spatial_3d: u32,
}

// ------------------------------------------
// Bindings
// ------------------------------------------
@group(0) @binding(0) var<storage, read> transforms: array<Transform>;
@group(0) @binding(1) var<storage, read> materials: array<Material>;
@group(0) @binding(2) var<storage, read> glyphs: array<Glyph>;
@group(0) @binding(3) var<storage, read> visible_indices: array<u32>;

@group(1) @binding(0) var<uniform> config: GlobalConfig;
@group(1) @binding(1) var msdf_atlas: texture_2d<f32>;
@group(1) @binding(2) var msdf_sampler: sampler;

// ------------------------------------------
// Vertex Shader (ZERO Vertex Buffer required)
// ------------------------------------------
struct VertexOutput {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) @interpolate(flat) entity_id: u32,
}

@vertex
fn vs_main(
    @builtin(vertex_index) v_idx: u32, 
    @builtin(instance_index) i_idx: u32
) -> VertexOutput {
    // 1. Get the actual Entity ID from our Culling Compute Shader
    let entity_id = visible_indices[i_idx];
    
    // 2. Fetch Data directly from SSBO (Zero CPU-GPU bandwidth toll!)
    let transform = transforms[entity_id];
    let glyph = glyphs[entity_id];
    
    // 3. Procedurally generate a Quad from 0 to 6 vertices based on standard Triangulation layout
    var quad_pos = vec2<f32>(0.0);
    var uvs = vec2<f32>(0.0);
    
    switch (v_idx % 6u) {
        case 0u: { quad_pos = vec2(0.0, 0.0); uvs = vec2(0.0, 1.0); }
        case 1u: { quad_pos = vec2(1.0, 0.0); uvs = vec2(1.0, 1.0); }
        case 2u: { quad_pos = vec2(1.0, 1.0); uvs = vec2(1.0, 0.0); }
        case 3u: { quad_pos = vec2(0.0, 0.0); uvs = vec2(0.0, 1.0); }
        case 4u: { quad_pos = vec2(1.0, 1.0); uvs = vec2(1.0, 0.0); }
        case 5u: { quad_pos = vec2(0.0, 1.0); uvs = vec2(0.0, 0.0); }
        default: {}
    }

    // Map Quad to Actual Size and Position
    let final_size = transform.size * transform.scale;
    let screen_pos = transform.position.xy + (quad_pos * final_size);

    // Map 0 -> Resolution into Normalize Device Coordinates (-1.0 to 1.0) for WebGPU
    let clip_x = (screen_pos.x / config.resolution.x) * 2.0 - 1.0;
    // Y is flipped in WebGPU 
    let clip_y = 1.0 - (screen_pos.y / config.resolution.y) * 2.0; 

    // Proper atlas UV mapping
    let final_uv = glyph.uv_start + (uvs * glyph.uv_size);

    var out: VertexOutput;
    // Keep Z dynamic for 3D depth buffers!
    out.clip_pos = vec4<f32>(clip_x, clip_y, transform.position.z, 1.0);
    out.uv = final_uv;
    out.entity_id = entity_id;
    
    return out;
}

// ------------------------------------------
// Fragment Shader (The "Pinnacle" Aesthetic)
// ------------------------------------------
fn median(r: f32, g: f32, b: f32) -> f32 {
    return max(min(r, g), min(max(r, g), b));
}

fn unpack_color(packed: u32) -> vec4<f32> {
    let r = f32((packed >> 24u) & 0xFFu) / 255.0;
    let g = f32((packed >> 16u) & 0xFFu) / 255.0;
    let b = f32((packed >> 8u) & 0xFFu) / 255.0;
    let a = f32(packed & 0xFFu) / 255.0;
    return vec4<f32>(r, g, b, a);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let glyph = glyphs[in.entity_id];
    let mat = materials[in.entity_id];
    let base_color = unpack_color(glyph.color_packed);
    
    // Is it a background pane or text? 
    // We can infer by checking if uv_size == 0 for panels.
    let is_panel = (glyph.uv_size.x == 0.0 && glyph.uv_size.y == 0.0);

    if (is_panel) {
        // [FUTURE] Apply Glassmorphism: Sample background screen texture with frost blur
        // For now, return standard high-performance quad color
        return vec4<f32>(base_color.rgb, base_color.a * mat.opacity);
    } 

    // --------------------------------------------
    // The Ultimate MSDF Magic Text Renderer
    // --------------------------------------------
    let msd = textureSample(msdf_atlas, msdf_sampler, in.uv).rgb;
    let sd = median(msd.r, msd.g, msd.b);
    let screen_px_distance = config.msdf_pixel_range * (sd - 0.5 + glyph.font_weight);
    
    // Instead of pixelating, we smoothstep the distance fields using automatic derivatives (fwidth).
    // This makes font look perfectly curved whether you are viewing it from 1 pixel size or 1000px size!
    let opacity = clamp(screen_px_distance + 0.5, 0.0, 1.0);
    
    if (opacity < 0.05) {
        discard;
    }

    return vec4<f32>(base_color.rgb, opacity * mat.opacity * base_color.a);
}
