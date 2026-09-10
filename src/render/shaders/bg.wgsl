// Background shader for terminal cell background rendering.
//
// Renders a full-screen quad per cell (instanced) with a solid background color.
// Uses the same instancing approach as the glyph shader but without texture sampling.
//
// Vertex input (per-instance):
//   - position: vec2<f32>  (cell x, y in pixel coordinates)
//   - cell_size: vec2<f32> (width, height of the cell)
//   - bg_color: vec4<f32>  (background color, RGBA)

struct Uniforms {
    screen_size: vec2<f32>,
    cell_size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// Vertex positions for a unit quad
var<private> quad_positions: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0),  // top-left
    vec2<f32>(1.0, 0.0),  // top-right
    vec2<f32>(0.0, 1.0),  // bottom-left
    vec2<f32>(0.0, 1.0),  // bottom-left
    vec2<f32>(1.0, 0.0),  // top-right
    vec2<f32>(1.0, 1.0),  // bottom-right
);

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    @location(0) position: vec2<f32>,
    @location(1) cell_size: vec2<f32>,
    @location(2) uv_rect: vec4<f32>,
    @location(3) bg_color: vec4<f32>,
) -> VertexOutput {
    var output: VertexOutput;

    // Expand quad corner
    let corner = quad_positions[vertex_index];

    // World position: cell origin + corner * cell_size
    let world_pos = position + corner * cell_size;

    // Convert to clip space: [0, screen_size] -> [-1, 1]
    let clip_x = (world_pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / uniforms.screen_size.y) * 2.0;
    output.clip_position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);

    output.color = bg_color;

    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    return input.color;
}
