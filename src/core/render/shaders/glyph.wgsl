// Glyph vertex/fragment shader for instanced terminal rendering.
//
// Vertex input (per-instance):
//   - position: vec2<f32>  (cell x, y in grid coordinates)
//   - codepoint: u32       (glyph index in atlas)
//   - fg_color: u32        (R5G6B5 packed foreground color)
//
// The vertex shader expands each instance (cell) into a quad (4 vertices, 6 indices)
// using vertex_id to select the corner. Texture coordinates are derived from the
// atlas slot for the given codepoint.
//
// The fragment shader samples the atlas texture and applies the foreground color.

struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) cell_size: vec2<f32>,
    @location(2) uv_rect: vec4<f32>,  // u0, v0, u1, v1
    @location(3) fg_color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
    @location(1) color: vec4<f32>,
};

struct Uniforms {
    screen_size: vec2<f32>,
    cell_size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var atlas_texture: texture_2d<f32>;
@group(0) @binding(2) var atlas_sampler: sampler;

// Vertex positions for a unit quad (expanded by cell_size)
var<private> quad_positions: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0),  // top-left
    vec2<f32>(1.0, 0.0),  // top-right
    vec2<f32>(0.0, 1.0),  // bottom-left
    vec2<f32>(0.0, 1.0),  // bottom-left
    vec2<f32>(1.0, 0.0),  // top-right
    vec2<f32>(1.0, 1.0),  // bottom-right
);

// Texture coordinates for a unit quad
var<private> quad_uvs: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0),
    vec2<f32>(1.0, 0.0),
    vec2<f32>(0.0, 1.0),
    vec2<f32>(0.0, 1.0),
    vec2<f32>(1.0, 0.0),
    vec2<f32>(1.0, 1.0),
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

    // Expand quad corner
    let corner = quad_positions[vertex_index];
    let uv_corner = quad_uvs[vertex_index];

    // Negative uv_rect.z (u1) signals synthetic italic oblique shear on the
    // glyph quad while leaving the background pass (bg.wgsl) strictly rectangular.
    // Negative uv_rect.w (v1) signals synthetic bold weight (SGR 1).
    let is_italic = uv_rect.z < 0.0;
    let is_bold = uv_rect.w < 0.0;
    let u1 = abs(uv_rect.z);
    let v1 = abs(uv_rect.w);
    let shear_x = select(0.0, (0.5 - corner.y) * 0.22 * cell_size.x, is_italic);

    // World position: cell origin + corner * cell_size + italic shear
    let world_pos = vec2<f32>(
        position.x + corner.x * cell_size.x + shear_x,
        position.y + corner.y * cell_size.y,
    );

    // Convert to clip space: [0, screen_size] -> [-1, 1]
    let clip_x = (world_pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / uniforms.screen_size.y) * 2.0;
    output.clip_position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);

    // Texture coordinates: interpolate within the atlas UV rect.
    // Encode bold state via negative tex_coord.y (offset by -2.0 so v=0.0 is strictly < 0.0).
    let v_raw = mix(uv_rect.y, v1, uv_corner.y);
    output.tex_coord = vec2<f32>(
        mix(uv_rect.x, u1, uv_corner.x),
        select(v_raw, -(v_raw + 2.0), is_bold),
    );

    output.color = fg_color;

    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let is_bold = input.tex_coord.y < 0.0;
    let uv = vec2<f32>(
        input.tex_coord.x,
        select(input.tex_coord.y, -input.tex_coord.y - 2.0, is_bold),
    );

    // Sample the atlas (R8 format: alpha is the glyph mask)
    let a0 = textureSampleLevel(atlas_texture, atlas_sampler, uv, 0.0).r;
    let a1 = select(
        0.0,
        textureSampleLevel(atlas_texture, atlas_sampler, uv - vec2<f32>(0.65 / 1024.0, 0.0), 0.0).r * 0.82,
        is_bold,
    );
    let raw_alpha = max(a0, a1);

    // Discard fully transparent fragments
    if (raw_alpha < 0.01) {
        discard;
    }

    // Dark-mode luminance gamma contrast boost
    let alpha = pow(clamp(raw_alpha, 0.0, 1.0), 0.82);

    // Apply foreground color with glyph alpha
    return vec4<f32>(input.color.rgb, input.color.a * alpha);
}
