// Emoji glyph shader: samples RGBA8 color emoji texture directly.
struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
};

struct Uniforms {
    screen_size: vec2<f32>,
    cell_size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var emoji_texture: texture_2d<f32>;
@group(0) @binding(2) var emoji_sampler: sampler;

var<private> quad_positions: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
    vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
);
var<private> quad_uvs: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
    vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
);

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    @location(0) position: vec2<f32>,
    @location(1) cell_size: vec2<f32>,
    @location(2) uv_rect: vec4<f32>,
    @location(3) fg_color: vec4<f32>,
) -> VertexOutput {
    var output: VertexOutput;
    let corner = quad_positions[vertex_index];
    let uv_corner = quad_uvs[vertex_index];
    let world_pos = position + corner * cell_size;
    let clip_x = (world_pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / uniforms.screen_size.y) * 2.0;
    output.clip_position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);
    output.tex_coord = vec2<f32>(
        mix(uv_rect.x, uv_rect.z, uv_corner.x),
        mix(uv_rect.y, uv_rect.w, uv_corner.y),
    );
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(emoji_texture, emoji_sampler, input.tex_coord);
    if (color.a < 0.01) { discard; }
    return color;
}
