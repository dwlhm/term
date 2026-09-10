// Phase 14 tiled compute shader: renders dirty tiles into the framebuffer.
//
// One workgroup (8x8) owns one tile: tile_id = tile_list[workgroup_id.x].
// Threads stride over the tile's cells; each cell fills its pixel rect with
// the LUT background and overlays the atlas glyph mask (foreground).
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

struct Tile_Params {
    screen_w: f32,
    screen_h: f32,
    cols: u32,
    rows: u32,
    cell_w: f32,
    cell_h: f32,
    tile_w: u32,
    tile_h: u32,
    tiles_x: u32,
    tiles_y: u32,
    atlas_w: u32,
    atlas_h: u32,
};

@group(0) @binding(0) var<uniform> params: Tile_Params;
@group(0) @binding(1) var<storage, read> tile_list: array<u32>;
@group(0) @binding(2) var<storage, read> cells: array<u32>;
@group(0) @binding(3) var<storage, read> lut: array<u32, 1024>;
@group(0) @binding(4) var atlas_texture: texture_2d<f32>;
@group(0) @binding(5) var atlas_sampler: sampler;
@group(0) @binding(6) var framebuffer: texture_storage_2d<rgba8unorm, write>;

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

@compute @workgroup_size(8, 8, 1)
fn cs_main(
    @builtin(workgroup_id) wg: vec3<u32>,
    @builtin(local_invocation_id) lid: vec3<u32>,
) {
    let tile_id = tile_list[wg.x];
    // OOB early-out: tile id beyond the tile grid.
    if (tile_id >= params.tiles_x * params.tiles_y) {
        return;
    }
    let tile_row = tile_id / params.tiles_x;
    let tile_col = tile_id % params.tiles_x;
    let orow = tile_row * params.tile_h;
    let ocol = tile_col * params.tile_w;
    let cw = min(params.tile_w, params.cols - ocol);
    let ch = min(params.tile_h, params.rows - orow);
    if (cw == 0u || ch == 0u) {
        return;
    }
    let fb_w = i32(f32(params.cols) * params.cell_w);
    let fb_h = i32(f32(params.rows) * params.cell_h);

    let lane = lid.y * 8u + lid.x;
    let n_cells = cw * ch;
    for (var i = lane; i < n_cells; i += 64u) {
        let lr = orow + i / cw;
        let lc = ocol + i % cw;
        let ci = lr * params.cols + lc;
        let lo = cells[ci * 2u];
        let hi = cells[ci * 2u + 1u];
        let content = lo & 0x1FFFFFu;
        let style = (lo >> 21u) & 0x3FFu;
        let width = ((lo >> 31u) & 1u) | ((hi & 1u) << 1u);
        let slot = (hi >> 8u) & 0x1FFu;

        let bg_rgb = r5g6b5_to_rgb(lut_bg(style));

        let x0 = i32(f32(lc) * params.cell_w);
        let y0 = i32(f32(lr) * params.cell_h);
        let x1 = min(x0 + i32(params.cell_w), fb_w);
        let y1 = min(y0 + i32(params.cell_h), fb_h);

        // Continuation cell: black fill, plus the left neighbor's wide-lead
        // right half when present (instance-path parity).
        if (width == 0u) {
            var fg_rgb = vec3<f32>(0.0);
            var uvs = vec4<f32>(0.0);
            var has_glyph = false;
            var gw = params.cell_w;
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
                            fg_rgb = r5g6b5_to_rgb(lut_fg(nstyle));
                            uvs = slot_uv(u32(su));
                            gw = params.cell_w * 2.0;
                            has_glyph = true;
                        }
                    }
                }
            }
            for (var py = y0; py < y1; py++) {
                for (var px = x0; px < x1; px++) {
                    var col = vec3<f32>(0.0);
                    if (has_glyph) {
                        let fx = (f32(px) - (f32(x0) - params.cell_w)) / gw;
                        let fy = (f32(py) - f32(y0)) / params.cell_h;
                        if (fx >= 0.0 && fx < 1.0 && fy >= 0.0 && fy < 1.0) {
                            let u = uvs.x + fx * (uvs.z - uvs.x);
                            let v = uvs.y + fy * (uvs.w - uvs.y);
                            let alpha = textureSampleLevel(
                                atlas_texture, atlas_sampler,
                                vec2<f32>(u, v), 0.0).r;
                            col = mix(col, fg_rgb, alpha);
                        }
                    }
                    textureStore(framebuffer, vec2<i32>(px, py), vec4<f32>(col, 1.0));
                }
            }
            continue;
        }

        // Regular cell: LUT background fill, glyph overlay when present.
        var su = -1;
        if (slot == 0x1FFu) {
            su = pinned_slot(content);
        } else if (slot < 512u) {
            su = i32(slot);
        }
        let fg_rgb = r5g6b5_to_rgb(lut_fg(style));
        var has_glyph = false;
        var uvs = vec4<f32>(0.0);
        var gw = params.cell_w;
        if (content != 0x20u && content != 0u && su >= 0) {
            uvs = slot_uv(u32(su));
            if (width == 2u) {
                gw = params.cell_w * 2.0;
            }
            has_glyph = true;
        }
        for (var py2 = y0; py2 < y1; py2++) {
            for (var px2 = x0; px2 < x1; px2++) {
                var col = bg_rgb;
                if (has_glyph) {
                    let fx = (f32(px2) - f32(x0)) / gw;
                    let fy = (f32(py2) - f32(y0)) / params.cell_h;
                    if (fx >= 0.0 && fx < 1.0 && fy >= 0.0 && fy < 1.0) {
                        let u = uvs.x + fx * (uvs.z - uvs.x);
                        let v = uvs.y + fy * (uvs.w - uvs.y);
                        let alpha = textureSampleLevel(
                            atlas_texture, atlas_sampler,
                            vec2<f32>(u, v), 0.0).r;
                        col = mix(col, fg_rgb, alpha);
                    }
                }
                textureStore(framebuffer, vec2<i32>(px2, py2), vec4<f32>(col, 1.0));
            }
        }
    }
}
