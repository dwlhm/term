// 3D Component Engine WGSL Shader
// Part of core_render: Tier 1 Autonomous Core Primitives.
//
// Supports full depth testing, Blinn-Phong lighting, metallic specular,
// Fresnel rim glow, and holographic wireframe overlay.

struct Component3D_Uniforms {
    mvp: mat4x4<f32>,
    model: mat4x4<f32>,
    normal_mat: mat4x4<f32>,
    light_pos: vec4<f32>,
    view_pos: vec4<f32>,
    ambient_color: vec4<f32>,
    light_color: vec4<f32>,
    time: f32,
    metallic: f32,
    roughness: f32,
    wireframe: f32,
};

@group(0) @binding(0)
var<uniform> uniforms: Component3D_Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) world_normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    let world_pos4 = uniforms.model * vec4<f32>(in.position, 1.0);
    out.world_pos = world_pos4.xyz;
    let norm4 = uniforms.normal_mat * vec4<f32>(in.normal, 0.0);
    out.world_normal = normalize(norm4.xyz);
    out.clip_position = uniforms.mvp * vec4<f32>(in.position, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let N = normalize(in.world_normal);
    let L = normalize(uniforms.light_pos.xyz - in.world_pos);
    let V = normalize(uniforms.view_pos.xyz - in.world_pos);
    let H = normalize(L + V);

    // Blinn-Phong Diffuse
    let diff = max(dot(N, L), 0.0);
    let diffuse = uniforms.light_color.rgb * diff;

    // Specular
    let shininess = mix(16.0, 128.0, 1.0 - uniforms.roughness);
    let spec = pow(max(dot(N, H), 0.0), shininess);
    let specular = uniforms.light_color.rgb * spec * mix(0.2, 1.0, uniforms.metallic);

    // Ambient
    let ambient = uniforms.ambient_color.rgb;

    // Fresnel Rim Glow
    let n_dot_v = max(dot(N, V), 0.0);
    let fresnel = pow(1.0 - n_dot_v, 3.0);
    let rim = vec3<f32>(0.2, 0.7, 1.0) * fresnel * 0.85;

    // Base color from vertex color
    let base = in.color.rgb;
    var lit = (ambient + diffuse) * base + specular + rim;

    // Optional holographic wireframe / pulse grid overlay
    if (uniforms.wireframe > 0.5) {
        let uv_grid = fract(in.uv * 6.0);
        let line_w = 0.07;
        let edge = step(uv_grid.x, line_w) + step(1.0 - line_w, uv_grid.x) +
                   step(uv_grid.y, line_w) + step(1.0 - line_w, uv_grid.y);
        let is_edge = clamp(edge, 0.0, 1.0);
        let wire_color = vec3<f32>(0.0, 1.0, 0.85) * (0.8 + 0.2 * sin(uniforms.time * 4.0));
        lit = mix(lit * 0.35, wire_color, is_edge);
    }

    return vec4<f32>(lit, in.color.a);
}
