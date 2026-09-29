// Background shader for terminal cell background rendering.
//
// Renders a full-screen quad per cell (instanced) with a solid background color.
// Uses the same instancing approach as the glyph shader but without texture sampling.
//
// Vertex input (per-instance):
//   - position: vec2<f32>  (cell x, y in pixel coordinates)
//   - cell_size: vec2<f32> (width, height of the cell)
//   - bg_color: vec4<f32>  (background color, RGBA)

struct WaterWave {
    origin_age_strength: vec4<f32>,
    lifetime_params: vec4<f32>,
};

struct Uniforms {
    screen_size: vec2<f32>,
    cell_size: vec2<f32>,
    water_meta: vec4<f32>,
    waves: array<WaterWave, 16>,
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
    @location(1) uv: vec2<f32>,
    @location(2) world_pos: vec2<f32>,
    @location(3) params: vec4<f32>,
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

    let corner = quad_positions[vertex_index];
    let world_pos = position + corner * cell_size;

    let clip_x = (world_pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / uniforms.screen_size.y) * 2.0;
    output.clip_position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);

    output.color = bg_color;
    output.uv = corner;
    output.world_pos = world_pos;
    output.params = uv_rect;

    return output;
}

// Immutable disturbances interfere as one height field in logical pixels.
fn water_height(pos: vec2<f32>, surface: Uniforms) -> vec2<f32> {
    const WAVE_SPEED: f32 = 100.0;
    const PACKET_WIDTH: f32 = 85.0;
    const WAVELENGTH: f32 = 50.0;
    const DETAIL_WAVELENGTH: f32 = 22.0;
    const DETAIL_GAIN: f32 = 0.28;
    const BIRTH_TIME: f32 = 0.12;
    const TAU: f32 = 6.2831853;
    var height = 0.0;
    var coverage = 0.0;
    for (var i = 0u; i < 16u; i += 1u) {
        if (f32(i) >= surface.water_meta.x) { break; }
        let wave = surface.waves[i];
        let age = wave.origin_age_strength.z;
        let lifetime = wave.lifetime_params.x;
        if (age < 0.0 || age >= lifetime || lifetime <= 0.0) { continue; }
        let radial = pos - wave.origin_age_strength.xy;
        let distance = length(radial);
        let delta = distance - age * WAVE_SPEED;
        let q = delta / PACKET_WIDTH;
        if (abs(q) >= 1.0) { continue; }
        let support = 1.0 - q * q;
        let fade = 1.0 - smoothstep(0.15, 1.0, age / lifetime);
        let envelope = support * support * smoothstep(0.0, BIRTH_TIME, age)
            * fade * wave.origin_age_strength.w;
        // World-anchored variation bends crests without jittering with the pointer.
        let phase_warp = sin(dot(pos, vec2<f32>(0.021, 0.013))) * 0.85
            + sin(dot(pos, vec2<f32>(-0.011, 0.027))) * 0.45;
        let phase = delta * TAU / WAVELENGTH + phase_warp;
        let detail = sin(delta * TAU / DETAIL_WAVELENGTH - phase_warp * 1.4)
            * DETAIL_GAIN * exp(-age * 1.6);
        height += (sin(phase) + detail) * envelope;
        coverage += envelope * 0.85;
    }
    return vec2<f32>(height, clamp(coverage, 0.0, 1.0));
}

fn water_surface(pos: vec2<f32>, color: vec4<f32>, surface: Uniforms) -> vec4<f32> {
    const GRADIENT_STEP: f32 = 1.0;
    const HEIGHT_SCALE: f32 = 15.0;
    const REFLECTION_POWER: f32 = 18.0;
    const REFLECTION_GAIN: f32 = 0.46;
    let field = water_height(pos, surface);
    if (field.y <= 0.0) { return vec4<f32>(0.0); }
    let dx = (water_height(pos + vec2<f32>(GRADIENT_STEP, 0.0), surface).x - field.x) / GRADIENT_STEP;
    let dy = (water_height(pos + vec2<f32>(0.0, GRADIENT_STEP), surface).x - field.x) / GRADIENT_STEP;
    let normal = normalize(vec3<f32>(-dx * HEIGHT_SCALE, -dy * HEIGHT_SCALE, 1.0));
    let light = normalize(vec3<f32>(-0.4, -0.6, 0.7));
    let half_vector = normalize(light + vec3<f32>(0.0, 0.0, 1.0));
    let diffuse = max(dot(normal, light), 0.0);
    let reflection = pow(max(dot(normal, half_vector), 0.0), REFLECTION_POWER) * REFLECTION_GAIN;
    let shade = 0.07 + diffuse * 0.23;
    let tint = mix(vec3<f32>(0.48), color.rgb, 0.3);
    let rgb = clamp(tint * shade + vec3<f32>(reflection), vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(rgb, clamp(field.y * color.a, 0.0, 1.0));
}

// Compact cubic height and its analytic radial derivative.
fn ripple_profile(offset: f32, width: f32) -> vec2<f32> {
    let q = offset / width;
    if (abs(q) >= 1.0) { return vec2<f32>(0.0); }
    let support = 1.0 - q * q;
    return vec2<f32>(support * support * support, -6.0 * q * support * support / width);
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    // Fast path: ordinary background cell or standard UI quad
    if (input.params.w == 0.0) {
        return input.color;
    }

    if (input.params.w == -3.0) {
        return water_surface(input.world_pos / max(uniforms.water_meta.y, 0.001), input.color, uniforms);
    }

    // Compact wave packets leave the terminal untouched between rings.
    const HOVER_SPEED: f32 = 145.0;
    const HOVER_PERIOD: f32 = 0.85;
    const HOVER_RING_COUNT: u32 = 4u;
    const HOVER_FADE_IN: f32 = 0.28;
    const HOVER_GAIN: f32 = 0.62;
    const SPLASH_TRAVEL: f32 = 1520.0;
    const SPLASH_SPACING: f32 = 46.0;
    const SPLASH_RING_COUNT: u32 = 4u;
    const SPLASH_GAIN: f32 = 0.92;
    const CREST_WIDTH: f32 = 20.0;
    const TROUGH_WIDTH: f32 = 24.0;
    const TROUGH_OFFSET: f32 = 20.0;
    const SPLASH_BIRTH_RADIUS: f32 = 10.0;
    const TROUGH_GAIN: f32 = 0.42;
    const HEIGHT_SCALE: f32 = 24.0;
    const LIGHT_DIRECTION = vec3<f32>(-0.4, -0.6, 0.7);
    const SPECULAR_SHARPNESS: f32 = 72.0;
    const SPECULAR_GAIN: f32 = 1.35;
    const BROAD_SHARPNESS: f32 = 12.0;
    const BROAD_GAIN: f32 = 0.38;
    const TROUGH_SHADOW: f32 = 0.78;

    let center = input.params.xy;
    let time = input.params.z;
    let fx_type = input.params.w;
    let radial = input.world_pos - center;
    let dist = length(radial);
    let dir = radial / max(dist, 0.001);
    var height = 0.0;
    var radial_slope = 0.0;
    var crest = 0.0;
    var trough = 0.0;

    if (fx_type == -1.0) {
        let fade_in = smoothstep(0.0, HOVER_FADE_IN, time);
        let lifetime = HOVER_PERIOD * f32(HOVER_RING_COUNT);
        for (var i = 0u; i < HOVER_RING_COUNT; i += 1u) {
            let elapsed = time - f32(i) * HOVER_PERIOD;
            if (elapsed >= 0.0) {
                let age = elapsed - floor(elapsed / lifetime) * lifetime;
                let radius = age * HOVER_SPEED;
                let envelope = smoothstep(0.0, HOVER_FADE_IN, age)
                    * (1.0 - smoothstep(lifetime * 0.45, lifetime, age))
                    * fade_in * HOVER_GAIN;
                let delta = dist - radius;
                let ridge_profile = ripple_profile(delta, CREST_WIDTH);
                let trough_profile = ripple_profile(delta + TROUGH_OFFSET, TROUGH_WIDTH);
                crest += ridge_profile.x * envelope;
                trough += trough_profile.x * envelope;
                height += (ridge_profile.x - TROUGH_GAIN * trough_profile.x) * envelope;
                radial_slope += (ridge_profile.y - TROUGH_GAIN * trough_profile.y) * envelope;
            }
        }
    } else if (fx_type == -2.0) {
        // Staging supplies normalized progress, independent of splash duration.
        if (time < 0.0 || time >= 1.0) {
            return vec4<f32>(0.0);
        }
        let fade = (1.0 - time) * (1.0 - time);
        for (var i = 0u; i < SPLASH_RING_COUNT; i += 1u) {
            let radius = time * SPLASH_TRAVEL - f32(i) * SPLASH_SPACING;
            if (radius >= 0.0) {
                let envelope = smoothstep(0.0, SPLASH_BIRTH_RADIUS, radius)
                    * fade * SPLASH_GAIN / (1.0 + f32(i) * 0.3);
                let delta = dist - radius;
                let ridge_profile = ripple_profile(delta, CREST_WIDTH);
                let trough_profile = ripple_profile(delta + TROUGH_OFFSET, TROUGH_WIDTH);
                crest += ridge_profile.x * envelope;
                trough += trough_profile.x * envelope;
                height += (ridge_profile.x - TROUGH_GAIN * trough_profile.x) * envelope;
                radial_slope += (ridge_profile.y - TROUGH_GAIN * trough_profile.y) * envelope;
            }
        }
    } else {
        return input.color;
    }

    let coverage = clamp(crest + trough * TROUGH_GAIN, 0.0, 1.0);
    let normal = normalize(vec3<f32>(-dir * radial_slope * HEIGHT_SCALE, 1.0));
    let light = normalize(LIGHT_DIRECTION);
    let half_vector = normalize(light + vec3<f32>(0.0, 0.0, 1.0));
    let diffuse = max(dot(normal, light), 0.0);
    let reflection = max(dot(normal, half_vector), 0.0);
    let specular = pow(reflection, SPECULAR_SHARPNESS) * SPECULAR_GAIN
        + pow(reflection, BROAD_SHARPNESS) * BROAD_GAIN;
    let shadow = clamp(-height / max(coverage, 0.001), 0.0, 1.0) * TROUGH_SHADOW;
    let body = input.color.rgb * (0.12 + 0.55 * diffuse) * (1.0 - shadow);
    let rgb = clamp(body + vec3<f32>(specular) * (1.0 - shadow), vec3<f32>(0.0), vec3<f32>(1.0));
    // All reflection and shadow coverage vanish exactly outside the height packet.
    return vec4<f32>(rgb, clamp(coverage * input.color.a, 0.0, 1.0));
}
