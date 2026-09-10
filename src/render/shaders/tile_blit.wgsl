// Phase 14 framebuffer blit shader: samples the compute framebuffer onto the
// surface with a fullscreen triangle generated from vertex_index (no vertex
// buffers). UV (0, 0) is the top-left texel; the oversized triangle corners
// are absorbed by ClampToEdge sampling. Opaque output.

@group(0) @binding(0) var fb_texture: texture_2d<f32>;
@group(0) @binding(1) var fb_sampler: sampler;

struct Blit_Output {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
};

var<private> blit_positions: array<vec2<f32>, 3> = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, 1.0),   // top-left
    vec2<f32>(3.0, 1.0),    // top-right (oversized)
    vec2<f32>(-1.0, -3.0),  // bottom-left (oversized)
);

var<private> blit_uvs: array<vec2<f32>, 3> = array<vec2<f32>, 3>(
    vec2<f32>(0.0, 0.0),
    vec2<f32>(2.0, 0.0),
    vec2<f32>(0.0, 2.0),
);

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> Blit_Output {
    var output: Blit_Output;
    output.clip_position = vec4<f32>(blit_positions[vertex_index], 0.0, 1.0);
    output.tex_coord = blit_uvs[vertex_index];
    return output;
}

@fragment
fn fs_main(input: Blit_Output) -> @location(0) vec4<f32> {
    let sampled = textureSample(fb_texture, fb_sampler, input.tex_coord);
    return vec4<f32>(sampled.rgb, 1.0);
}
