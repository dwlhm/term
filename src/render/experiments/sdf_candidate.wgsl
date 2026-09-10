// sdf_candidate.wgsl — OFFLINE COMPARE ONLY. Never loaded by any backend.
//
// Bit-near candidate for the Phase 19 SDF/MSDF experiment: mirrors fs_main
// (src/render/shaders/glyph.wgsl:90) with the field-coverage mapping added.
// The CPU mirror is sdf_sample_cpu / msdf_sample_cpu
// (src/render/experiments/sdf_experiment.odin):
//   d_out   = (v - 0.5) * 2 * spread_hires * scale   (spread_hires = 8,
//             scale = out/base = 0.25 for the 16px leg)
//   a       = smoothstep(clamp(d_out + 0.5, 0, 1))
// SDF costs 1 fetch + smoothstep over fs_main; MSDF adds median3.

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) tex_coord: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@group(0) @binding(0) var atlas_texture: texture_2d<f32>;
@group(0) @binding(1) var atlas_sampler: sampler;

// smoothstep(0, 1, x) spelled out so the ALU delta vs fs_main is explicit.
fn sdf_smooth(a: f32) -> f32 {
    let c = clamp(a, 0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
}

// CPU mirror: _sdf_coverage in sdf_experiment.odin.
fn sdf_coverage(v: f32, spread_hires: f32, scale: f32) -> f32 {
    let d = (v - 0.5) * 2.0 * spread_hires * scale;
    return sdf_smooth(d + 0.5);
}

// 3-tap median without dynamic branching (+median3 over the SDF path).
fn msdf_median(r: f32, g: f32, b: f32) -> f32 {
    return max(min(r, g), min(max(r, g), b));
}

@fragment
fn fs_sdf_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let v = textureSample(atlas_texture, atlas_sampler, input.tex_coord).r;
    let alpha = sdf_coverage(v, 8.0, 0.25);

    if (alpha < 0.01) {
        discard;
    }

    return vec4<f32>(input.color.rgb, input.color.a * alpha);
}

@fragment
fn fs_msdf_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let rgb = textureSample(atlas_texture, atlas_sampler, input.tex_coord).rgb;
    let v = msdf_median(rgb.r, rgb.g, rgb.b);
    let alpha = sdf_coverage(v, 8.0, 0.25);

    if (alpha < 0.01) {
        discard;
    }

    return vec4<f32>(input.color.rgb, input.color.a * alpha);
}
