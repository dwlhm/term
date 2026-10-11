// Hardware quad blit shader for OS-Style Layer Compositor Architecture.
// Composites offscreen layer backing textures onto the target render pass.
//
// Features:
// 1. Procedural quad generated from 6 vertex IDs (zero vertex buffer overhead).
// 2. Per-layer scissor clip boundary check (discard fragments outside clip_rect).
// 3. Corner rounding via Box SDF smoothstep (for floating/rounded panes).
// 4. Opacity alpha blending (opacity * sampled.a).

struct Blit_Uniforms {
    screen_size:   vec2<f32>,
    dest_rect_xy:  vec2<f32>,
    dest_rect_wh:  vec2<f32>,
    clip_rect_xy:  vec2<f32>,
    clip_rect_wh:  vec2<f32>,
    opacity:       f32,
    corner_radius: f32,
};

@group(0) @binding(0) var<uniform> uniforms: Blit_Uniforms;
@group(0) @binding(1) var layer_texture: texture_2d<f32>;
@group(0) @binding(2) var layer_sampler: sampler;

struct VertexOutput {
    @builtin(position) position:    vec4<f32>,
    @location(0)       uv:          vec2<f32>,
    @location(1)       pixel_coord: vec2<f32>,
};

var<private> quad_corners: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
    vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
);

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOutput {
    let corner = quad_corners[vid % 6u];
    let dest_rect = vec4<f32>(uniforms.dest_rect_xy, uniforms.dest_rect_wh);
    let world_pos = dest_rect.xy + corner * dest_rect.zw;

    let clip_x = (world_pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / uniforms.screen_size.y) * 2.0;

    var out: VertexOutput;
    out.position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);
    out.uv = corner;
    out.pixel_coord = world_pos;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let clip_rect = vec4<f32>(uniforms.clip_rect_xy, uniforms.clip_rect_wh);

    // Scissor clipping discard: clip_rect is [x, y, w, h]
    if (in.pixel_coord.x < clip_rect.x || in.pixel_coord.x > (clip_rect.x + clip_rect.z) ||
        in.pixel_coord.y < clip_rect.y || in.pixel_coord.y > (clip_rect.y + clip_rect.w)) {
        discard;
    }

    // Corner rounding via Box SDF smoothstep
    var fill_alpha: f32 = 1.0;
    if (uniforms.corner_radius > 0.0) {
        let dest_rect = vec4<f32>(uniforms.dest_rect_xy, uniforms.dest_rect_wh);
        let center = dest_rect.xy + dest_rect.zw * 0.5;
        let b = dest_rect.zw * 0.5;
        let p = in.pixel_coord - center;
        let r = clamp(uniforms.corner_radius, 0.0, min(b.x, b.y));

        let q = abs(p) - b + vec2<f32>(r, r);
        let d = length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;

        fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);
        if (fill_alpha <= 0.001) {
            discard;
        }
    }

    // Sample layer texture and scale opacity
    var color = textureSampleLevel(layer_texture, layer_sampler, in.uv, 0.0);
    color.a = color.a * (fill_alpha * uniforms.opacity);
    return color;
}
