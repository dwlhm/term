// WGSL Shader for Strategy 3: SDF Vector Shader.
// Signed Distance Field evaluation for anti-aliased rounded rectangles and borders.
//
// Box SDF math:
//   d = length(max(abs(p) - b + r, 0.0)) - r with anti-aliasing via smoothstep.

struct Sdf_Params {
    screen_size:  vec2<f32>,
    rect_pos:     vec2<f32>,
    rect_size:    vec2<f32>,
    radius:       f32,
    border_width: f32,
    color:        vec4<f32>,
    border_color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> params: Sdf_Params;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) pixel_coord: vec2<f32>,
};

var<private> quad_corners: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
    vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
);

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOutput {
    let corner = quad_corners[vid % 6u];
    let world_pos = params.rect_pos - vec2<f32>(2.0, 2.0) + corner * (params.rect_size + vec2<f32>(4.0, 4.0));

    let clip_x = (world_pos.x / params.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / params.screen_size.y) * 2.0;

    var out: VertexOutput;
    out.position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);
    out.pixel_coord = world_pos;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let center = params.rect_pos + params.rect_size * 0.5;
    let b = params.rect_size * 0.5;
    let p = in.pixel_coord - center;
    let r = clamp(params.radius, 0.0, min(b.x, b.y));

    let q = abs(p) - b + vec2<f32>(r, r);
    let d = length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;

    let fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);
    if (fill_alpha <= 0.001) {
        discard;
    }

    var out_col = params.color;
    if (params.border_width > 0.0) {
        let bw = params.border_width;
        let border_factor = smoothstep(-bw - 0.5, -bw + 0.5, d);
        out_col = mix(params.color, params.border_color, border_factor);
    }

    out_col.a = out_col.a * fill_alpha;
    return out_col;
}
