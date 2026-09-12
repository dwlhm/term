// Phase 15 fullscreen fragment renderer: draws the whole grid in one pass.
//
// One fullscreen triangle (vertex_index, no vertex buffer) shades every
// framebuffer pixel directly from the packed V2 grid: cell lookup from
// frag coords, LUT background fill, atlas glyph overlay (foreground).
//
// Cell unpack mirrors render_cell_unpack_v2 (cells are u64 pairs):
//   lo = bits 0..31, hi = bits 32..63
//   content = lo & 0x1FFFFF, style = (lo >> 21) & 0x3FF,
//   width = ((lo >> 31) & 1) | ((hi & 1) << 1),
//   slot = (hi >> 8) & 0x1FF (0x1FF = UNRESOLVED -> pinned lookup below).
//
// Slot resolution: explicit slots (< 512) map arithmetically to UVs (every
// slot is a 16px cell in a 16-column grid). UNRESOLVED slots resolve through
// the pinned ranges (ASCII / box / block / powerline, mirroring
// atlas_pinned_slot_index); anything else keeps the background
// (GlyphSlotInvalid parity). Wide-lead glyphs span two cells: continuation
// cells sample the left neighbor and draw the right half over black,
// matching the instance path (continuations emit nothing there).
//
// Shader bindings (must match fullscreen.odin):
//   0 params uniform, 1 cells ro storage, 2 lut ro storage,
//   3 atlas texture, 4 sampler. Direct-to-surface output (opaque).

struct Fullscreen_Params {
    screen_w: f32,
    screen_h: f32,
    cols: u32,
    rows: u32,
    cell_w: f32,
    cell_h: f32,
    pad_x: f32,
    pad_y: f32,
    atlas_w: u32,
    atlas_h: u32,
};

@group(0) @binding(0) var<uniform> params: Fullscreen_Params;
@group(0) @binding(1) var<storage, read> cells: array<u32>;
@group(0) @binding(2) var<storage, read> lut: array<u32, 1024>;
@group(0) @binding(3) var atlas_texture: texture_2d<f32>;
@group(0) @binding(4) var atlas_sampler: sampler;

struct Fullscreen_Output {
    @builtin(position) clip_position: vec4<f32>,
};

// r5g6b5_to_rgb mirrors instance.unpack_r5g6b5.
fn r5g6b5_to_rgb(packed: u32) -> vec3<f32> {
    let r = f32((packed >> 11u) & 0x1Fu) / 31.0;
    let g = f32((packed >> 5u) & 0x3Fu) / 63.0;
    let b = f32(packed & 0x1Fu) / 31.0;
    return vec3<f32>(r, g, b);
}

// lut_color decodes one R5G6B5 half for style s from the raw Style_LUT words
// (fg pairs in words 0..511, bg pairs in words 512..1023).
fn lut_fg(s: u32) -> u32 {
    let w = lut[s >> 1u];
    if ((s & 1u) == 0u) {
        return w & 0xFFFFu;
    }
    return (w >> 16u) & 0xFFFFu;
}

fn lut_bg(s: u32) -> u32 {
    let w = lut[512u + (s >> 1u)];
    if ((s & 1u) == 0u) {
        return w & 0xFFFFu;
    }
    return (w >> 16u) & 0xFFFFu;
}

// pinned_slot mirrors atlas_pinned_slot_index: ASCII 32..126 -> 0..94,
// box 2500..257F -> 95..222, block 2580..259F -> 223..254,
// powerline E0B0..E0BF -> 255..270. Returns -1 when not pinned.
fn pinned_slot(content: u32) -> i32 {
    if (content >= 32u && content <= 126u) {
        return i32(content - 32u);
    }
    if (content >= 0x2500u && content <= 0x257Fu) {
        return 95 + i32(content - 0x2500u);
    }
    if (content >= 0x2580u && content <= 0x259Fu) {
        return 223 + i32(content - 0x2580u);
    }
    if (content >= 0xE0B0u && content <= 0xE0BFu) {
        return 255 + i32(content - 0xE0B0u);
    }
    return -1;
}

// slot_uv maps any atlas slot to its UV rect (16px cell, 16-column grid).
fn slot_uv(slot: u32) -> vec4<f32> {
    let col = f32(slot % 16u);
    let row = f32(slot / 16u);
    let aw = f32(params.atlas_w);
    let ah = f32(params.atlas_h);
    return vec4<f32>(
        col * 16.0 / aw,
        row * 16.0 / ah,
        (col * 16.0 + 16.0) / aw,
        (row * 16.0 + 16.0) / ah,
    );
}

var<private> fullscreen_positions: array<vec2<f32>, 3> = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, 1.0),   // top-left
    vec2<f32>(3.0, 1.0),    // top-right (oversized)
    vec2<f32>(-1.0, -3.0),  // bottom-left (oversized)
);

@vertex
fn fullscreen_vs_main(@builtin(vertex_index) vertex_index: u32) -> Fullscreen_Output {
    var output: Fullscreen_Output;
    output.clip_position = vec4<f32>(fullscreen_positions[vertex_index], 0.0, 1.0);
    return output;
}

@fragment
fn fullscreen_fs_main(input: Fullscreen_Output) -> @location(0) vec4<f32> {
    let px = i32(input.clip_position.x);
    let py = i32(input.clip_position.y);
    if (f32(px) < params.pad_x || f32(py) < params.pad_y ||
        f32(px) >= params.pad_x + f32(params.cols) * params.cell_w ||
        f32(py) >= params.pad_y + f32(params.rows) * params.cell_h) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let content_px = f32(px) - params.pad_x;
    let content_py = f32(py) - params.pad_y;
    let lc = u32(content_px / params.cell_w);
    let lr = u32(content_py / params.cell_h);
    if (lc >= params.cols || lr >= params.rows) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let ci = lr * params.cols + lc;
    let lo = cells[ci * 2u];
    let hi = cells[ci * 2u + 1u];
    let content = lo & 0x1FFFFFu;
    let style = (lo >> 21u) & 0x3FFu;
    let width = ((lo >> 31u) & 1u) | ((hi & 1u) << 1u);
    let slot = (hi >> 8u) & 0x1FFu;

    let bg_rgb = r5g6b5_to_rgb(lut_bg(style));

    let x0 = params.pad_x + f32(lc) * params.cell_w;
    let y0 = params.pad_y + f32(lr) * params.cell_h;

    // Continuation cell: black fill, plus the left neighbor's wide-lead
    // right half when present (instance-path parity).
    if (width == 0u) {
        var col = vec3<f32>(0.0);
        if (lc > 0u) {
            let ni = lr * params.cols + (lc - 1u);
            let nlo = cells[ni * 2u];
            let nhi = cells[ni * 2u + 1u];
            let nwidth = ((nlo >> 31u) & 1u) | ((nhi & 1u) << 1u);
            if (nwidth == 2u) {
                let ncontent = nlo & 0x1FFFFFu;
                let nstyle = (nlo >> 21u) & 0x3FFu;
                let nslot = (nhi >> 8u) & 0x1FFu;
                if (ncontent != 0x20u && ncontent != 0u) {
                    var su = -1;
                    if (nslot == 0x1FFu) {
                        su = pinned_slot(ncontent);
                    } else if (nslot < 512u) {
                        su = i32(nslot);
                    }
                    if (su >= 0) {
                        let fg_rgb = r5g6b5_to_rgb(lut_fg(nstyle));
                        let uvs = slot_uv(u32(su));
                        let gw = params.cell_w * 2.0;
                        let fx = (f32(px) - (x0 - params.cell_w)) / gw;
                        let fy = (f32(py) - y0) / params.cell_h;
                        if (fx >= 0.0 && fx < 1.0 && fy >= 0.0 && fy < 1.0) {
                            let u = uvs.x + fx * (uvs.z - uvs.x);
                            let v = uvs.y + fy * (uvs.w - uvs.y);
                            let alpha = textureSampleLevel(
                                atlas_texture, atlas_sampler,
                                vec2<f32>(u, v), 0.0).r;
                            col = mix(col, fg_rgb, alpha);
                        }
                    }
                }
            }
        }
        return vec4<f32>(col, 1.0);
    }

    // Regular cell: LUT background fill, glyph overlay when present.
    var su = -1;
    if (slot == 0x1FFu) {
        su = pinned_slot(content);
    } else if (slot < 512u) {
        su = i32(slot);
    }
    let fg_rgb = r5g6b5_to_rgb(lut_fg(style));
    var col = bg_rgb;
    if (content != 0x20u && content != 0u && su >= 0) {
        let uvs = slot_uv(u32(su));
        var gw = params.cell_w;
        if (width == 2u) {
            gw = params.cell_w * 2.0;
        }
        let fx = (f32(px) - x0) / gw;
        let fy = (f32(py) - y0) / params.cell_h;
        if (fx >= 0.0 && fx < 1.0 && fy >= 0.0 && fy < 1.0) {
            let u = uvs.x + fx * (uvs.z - uvs.x);
            let v = uvs.y + fy * (uvs.w - uvs.y);
            let alpha = textureSampleLevel(
                atlas_texture, atlas_sampler,
                vec2<f32>(u, v), 0.0).r;
            col = mix(col, fg_rgb, alpha);
        }
    }
    return vec4<f32>(col, 1.0);
}
