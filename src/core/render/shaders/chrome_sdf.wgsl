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

@group(0) @binding(0) var<storage, read> instances: array<Sdf_Params>;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) pixel_coord: vec2<f32>,
    @location(1) rect_center: vec2<f32>,
    @location(2) rect_half: vec2<f32>,
    @location(3) @interpolate(flat) radius: f32,
    @location(4) @interpolate(flat) border_width: f32,
    @location(5) color: vec4<f32>,
    @location(6) border_color: vec4<f32>,
    @location(7) @interpolate(flat) instance_idx: u32,
};

var<private> quad_corners: array<vec2<f32>, 6> = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
    vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
);

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VertexOutput {
    let params = instances[iid];
    var out: VertexOutput;
    out.instance_idx = iid;

    // Sentinel -997.0: pure wave data record, cull vertex completely
    if (params.border_width == -997.0) {
        out.position = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        return out;
    }

    let corner = quad_corners[vid % 6u];
    var pad = 2.0;
    if (params.border_width < 0.0 && params.border_width > -900.0) {
        pad = max(2.0, -params.border_width + 2.0);
    }
    let world_pos = params.rect_pos - vec2<f32>(pad, pad) + corner * (params.rect_size + vec2<f32>(pad * 2.0, pad * 2.0));

    let clip_x = (world_pos.x / params.screen_size.x) * 2.0 - 1.0;
    let clip_y = 1.0 - (world_pos.y / params.screen_size.y) * 2.0;

    let center = params.rect_pos + params.rect_size * 0.5;
    let half_size = params.rect_size * 0.5;

    out.position = vec4<f32>(clip_x, clip_y, 0.0, 1.0);
    out.pixel_coord = world_pos;
    out.rect_center = center;
    out.rect_half = half_size;
    out.radius = params.radius;
    out.border_width = params.border_width;
    out.color = params.color;
    out.border_color = params.border_color;
    return out;
}

// Dispersive Airy wave packet model with natural geometric attenuation.
fn water_height(pos: vec2<f32>, base_idx: u32, wave_count: u32) -> vec2<f32> {
    const TAU: f32 = 6.2831853;

    var height = 0.0;
    var coverage = 0.0;

    for (var i = 0u; i < wave_count; i += 1u) {
        let wave = instances[base_idx + 1u + i];
        let age = wave.radius;
        let lifetime = wave.border_color.x;
        let strength = wave.border_color.y;
        if (age < 0.0 || age >= lifetime || lifetime <= 0.0) {
            continue;
        }

        let is_impact = (strength > 0.80);
        let speed = select(320.0, 480.0, is_impact);
        let wavelength = select(48.0, 84.0, is_impact);
        let wave_front = age * speed;

        let delta = pos - wave.rect_pos;
        let dist = length(delta);

        let dr = dist - wave_front;
        // Compact Gaussian wave packet localized around the expanding wavefront
        let packet_width = select(44.0 + age * 16.0, 72.0 + age * 28.0, is_impact);
        if (abs(dr) > packet_width * 2.8) {
            continue;
        }
        let packet_envelope = exp(-0.5 * (dr * dr) / (packet_width * packet_width));

        // Fluid geometric attenuation (1/sqrt(r)) & time fade
        let geom_atten = 1.0 / sqrt(max(dist / 45.0, 1.0));
        let time_fade = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(lifetime * 0.40, lifetime, age)) * strength;
        let envelope = packet_envelope * geom_atten * time_fade;

        // Dispersive harmonic: primary wave followed by subtle capillary ripple
        let k = TAU / wavelength;
        let main_wave = sin(dr * k);
        let harmonic = sin(dr * (k * 1.85) + age * 2.0) * 0.32;

        // Central rebound droplet response for drop impact
        let rebound = select(0.0, exp(-dist / 30.0) * sin(age * 18.0) * exp(-age * 4.0) * 0.70, is_impact);

        let wave_val = (main_wave + harmonic + rebound) * envelope;
        height += wave_val;
        coverage += envelope;
    }
    return vec2<f32>(height, clamp(coverage, 0.0, 1.0));
}

fn render_water_surface(in: VertexOutput) -> vec4<f32> {
    let wave_count = min(u32(in.radius), 32u);
    if (wave_count == 0u) {
        discard;
    }

    let field = water_height(in.pixel_coord, in.instance_idx, wave_count);
    if (field.y <= 0.0005) {
        discard;
    }

    const GRADIENT_STEP: f32 = 1.2;
    const HEIGHT_SCALE: f32 = 28.0;

    let h_right = water_height(in.pixel_coord + vec2<f32>(GRADIENT_STEP, 0.0), in.instance_idx, wave_count).x;
    let h_down  = water_height(in.pixel_coord + vec2<f32>(0.0, GRADIENT_STEP), in.instance_idx, wave_count).x;
    let dx = (h_right - field.x) / GRADIENT_STEP;
    let dy = (h_down - field.x) / GRADIENT_STEP;

    let normal = normalize(vec3<f32>(-dx * HEIGHT_SCALE, -dy * HEIGHT_SCALE, 1.0));
    let light = normalize(vec3<f32>(-0.45, -0.60, 0.65));
    let fill_light = normalize(vec3<f32>(0.45, 0.60, 0.65));
    let view_dir = vec3<f32>(0.0, 0.0, 1.0);

    let half_key = normalize(light + view_dir);
    let half_fill = normalize(fill_light + view_dir);

    // Razor-sharp specular glints matching high surface tension of calm water
    let n_dot_h = max(dot(normal, half_key), 0.0);
    let spec_key = pow(n_dot_h, 72.0) * 1.45;
    let spec_fill = pow(max(dot(normal, half_fill), 0.0), 28.0) * 0.35;
    let specular = spec_key + spec_fill;

    // Fresnel rim luminescence on steep wave slopes
    let n_dot_v = clamp(dot(normal, view_dir), 0.0, 1.0);
    let fresnel = pow(1.0 - n_dot_v, 3.0);

    let slope = length(vec2<f32>(dx, dy)) * HEIGHT_SCALE;
    let crest = max(field.x * 2.0, 0.0);

    // Crystal clear optics: flat water has zero opacity, ripples glint with diamond-like highlights
    let optical_activity = specular + fresnel * 0.55 + slope * 0.35;
    let edge_fade = smoothstep(0.002, 0.04, optical_activity);
    if (edge_fade <= 0.001) {
        discard;
    }

    // Pure crystalline water palette (ice-crystal sheen & specular highlights, zero muddy diffuse)
    let water_tint = vec3<f32>(0.65, 0.82, 0.96);
    let specular_color = vec3<f32>(0.98, 0.99, 1.0);
    let surface_color = mix(water_tint, specular_color, clamp(specular * 0.85 + crest * 0.8, 0.0, 1.0));

    let rgb = surface_color;
    let alpha = clamp((specular * 0.92 + fresnel * 0.50 + slope * 0.22) * edge_fade * in.color.a, 0.0, 0.88);
    return vec4<f32>(rgb, alpha);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    if (in.border_width == -997.0) {
        discard;
    }
    if (in.border_width <= -998.0) {
        return render_water_surface(in);
    }
    let b = in.rect_half;
    let p = in.pixel_coord - in.rect_center;
    var d: f32;

    if (in.radius < -0.5) {
        // 3D Perspective Ellipse mode (radius < -0.5)
        let k0 = length(p / vec2<f32>(b.x, b.y));
        let k1 = length(p / vec2<f32>(b.x * b.x, b.y * b.y));
        d = (k0 - 1.0) * (k0 / max(k1, 0.0001));
    } else {
        let r = clamp(in.radius, 0.0, min(b.x, b.y));
        let q = abs(p) - b + vec2<f32>(r, r);
        d = length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;
    }

    // Soft ambient drop shadow mode (border_width < 0.0 indicates negative blur radius)
    if (in.border_width < 0.0) {
        let blur = -in.border_width;
        if (d < 0.0) {
            discard; // Keep the pane content and background untouched
        }
        let shadow_alpha = 1.0 - smoothstep(0.0, blur, d);
        if (shadow_alpha <= 0.001) {
            discard;
        }
        var out_col = in.color;
        out_col.a = out_col.a * shadow_alpha;
        return out_col;
    }

    let fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);
    if (fill_alpha <= 0.001) {
        discard;
    }

    var out_col = in.color;
    if (in.border_width > 0.0) {
        let bw = in.border_width;
        let border_factor = smoothstep(-bw - 0.5, -bw + 0.5, d);
        out_col = mix(in.color, in.border_color, border_factor);
    }

    out_col.a = out_col.a * fill_alpha;
    return out_col;
}
