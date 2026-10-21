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
// cells sample the left neighbor and draw the right half over their authored
// background, matching the instance path (continuations emit no own glyph).

struct Tile_Params {
    screen_w: f32,
    screen_h: f32,
    cols: u32,
    rows: u32,
    cell_w: f32,
    cell_h: f32,
    pad_x: f32,
    pad_y: f32,
    tile_w: u32,
    tile_h: u32,
    tiles_x: u32,
    tiles_y: u32,
    atlas_w: u32,
    atlas_h: u32,
    bg_opacity: f32,
    cell_opacity: f32,
};

@group(0) @binding(0) var<uniform> params: Tile_Params;
@group(0) @binding(1) var<storage, read> tile_list: array<u32>;
@group(0) @binding(2) var<storage, read> cells: array<u32>;
@group(0) @binding(3) var<storage, read> lut: array<u32, 1025>;
@group(0) @binding(4) var atlas_texture: texture_2d<f32>;
@group(0) @binding(5) var atlas_sampler: sampler;
@group(0) @binding(6) var framebuffer: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(7) var<storage, read> colors: array<u32>;

// r5g6b5_to_rgb mirrors instance.unpack_r5g6b5 and fullscreen.wgsl.
fn r5g6b5_to_rgb(packed: u32) -> vec3<f32> {
    let r = floor(f32((packed >> 11u) & 0x1Fu) / 31.0 * 255.0 + 0.5) / 255.0;
    let g = floor(f32((packed >> 5u) & 0x3Fu) / 63.0 * 255.0 + 0.5) / 255.0;
    let b = floor(f32(packed & 0x1Fu) / 31.0 * 255.0 + 0.5) / 255.0;
    return vec3<f32>(r, g, b);
}

// unpack_argb decodes a 0xFFRRGGBB word into (r, g, b, a) floats.
fn unpack_argb(c: u32) -> vec4<f32> {
    let a = f32((c >> ARGB_A_SHIFT) & ARGB_COMPONENT_MASK) / 255.0;
    let r = f32((c >> ARGB_R_SHIFT) & ARGB_COMPONENT_MASK) / 255.0;
    let g = f32((c >> ARGB_G_SHIFT) & ARGB_COMPONENT_MASK) / 255.0;
    let b = f32(c & ARGB_COMPONENT_MASK) / 255.0;
    return vec4<f32>(r, g, b, a);
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

const CELL_FLAG_SELECTED: u32 = 2u;
const CELL_FLAG_DIRECT_COLOR: u32 = 8u;
const LUT_SELECTION_WORD: u32 = 1024u;
const OPAQUE_ALPHA: f32 = 1.0;
const COLOR_WORDS_PER_CELL: u32 = 2u;
const ARGB_A_SHIFT: u32 = 24u;
const ARGB_R_SHIFT: u32 = 16u;
const ARGB_G_SHIFT: u32 = 8u;
const ARGB_COMPONENT_MASK: u32 = 0xFFu;

fn lut_selection_fg() -> u32 {
    return lut[LUT_SELECTION_WORD] & 0xFFFFu;
}

fn lut_selection_bg() -> u32 {
    return (lut[LUT_SELECTION_WORD] >> 16u) & 0xFFFFu;
}

fn cell_is_selected(cflags: u32) -> bool {
    return (cflags & CELL_FLAG_SELECTED) != 0u;
}

fn cell_background(style: u32, cflags: u32, bg_rgb: vec3<f32>, has_direct_bg: bool) -> vec4<f32> {
    let has_authored_background = cell_is_selected(cflags) ||
        has_direct_bg ||
        lut_bg(style) != lut_bg(0u);
    let base_rgb = r5g6b5_to_rgb(lut_bg(0u)) * params.bg_opacity;
    if (has_authored_background) {
        let alpha = params.cell_opacity;
        return vec4<f32>(bg_rgb * alpha + base_rgb * (1.0 - alpha),
            alpha + params.bg_opacity * (1.0 - alpha));
    }
    return vec4<f32>(base_rgb, params.bg_opacity);
}

fn composited_alpha(background_alpha: f32, glyph_coverage: f32) -> f32 {
    return background_alpha + glyph_coverage * (OPAQUE_ALPHA - background_alpha);
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

// slot_uv maps any atlas slot to its UV rect.
// Each slot is 64x64 in the 1024x2048 atlas. The glyph ink spans
// gw (cell_w or cell_w * 2 for wide) by cell_h within the slot origin.
fn slot_uv(slot: u32, gw: f32) -> vec4<f32> {
    let col = f32(slot & 15u);
    let row = f32(slot >> 4u);
    let inv_aw = 1.0 / f32(params.atlas_w);
    let inv_ah = 1.0 / f32(params.atlas_h);
    let u0 = col * (64.0 * inv_aw);
    let v0 = row * (64.0 * inv_ah);
    return vec4<f32>(
        u0,
        v0,
        u0 + gw * inv_aw,
        v0 + params.cell_h * inv_ah,
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
    let fb_w = i32(params.screen_w);
    let fb_h = i32(params.screen_h);

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
        let cflags = (hi >> 1u) & 0x7Fu;
        let slot = (hi >> 8u) & 0x1FFu;

        var has_direct_bg = false;
        var fg_rgb: vec3<f32>;
        var bg_rgb: vec3<f32>;
        if ((cflags & CELL_FLAG_DIRECT_COLOR) != 0u) {
            let fg_argb = colors[ci * COLOR_WORDS_PER_CELL];
            let bg_argb = colors[ci * COLOR_WORDS_PER_CELL + 1u];
            has_direct_bg = bg_argb != 0u;
            if (fg_argb != 0u && !cell_is_selected(cflags)) {
                fg_rgb = unpack_argb(fg_argb).rgb;
            } else {
                let fg_packed = select(lut_fg(style), lut_selection_fg(), cell_is_selected(cflags));
                fg_rgb = r5g6b5_to_rgb(fg_packed);
            }
            if (bg_argb != 0u && !cell_is_selected(cflags)) {
                bg_rgb = unpack_argb(bg_argb).rgb;
            } else {
                let bg_packed = select(lut_bg(style), lut_selection_bg(), cell_is_selected(cflags));
                bg_rgb = r5g6b5_to_rgb(bg_packed);
            }
        } else {
            let fg_packed = select(lut_fg(style), lut_selection_fg(), cell_is_selected(cflags));
            fg_rgb = r5g6b5_to_rgb(fg_packed);
            let bg_packed = select(lut_bg(style), lut_selection_bg(), cell_is_selected(cflags));
            bg_rgb = r5g6b5_to_rgb(bg_packed);
        }
        let background = cell_background(style, cflags, bg_rgb, has_direct_bg);
        let background_alpha = background.a;

        let cell_x0 = params.pad_x + f32(lc) * params.cell_w;
        let cell_y0 = params.pad_y + f32(lr) * params.cell_h;
        let x0 = max(i32(cell_x0), 0);
        let y0 = max(i32(cell_y0), 0);
        let x1 = min(i32(cell_x0 + params.cell_w), fb_w);
        let y1 = min(i32(cell_y0 + params.cell_h), fb_h);

        // Continuation cell: authored background plus the left neighbor's
        // wide-lead right half when present (instance-path parity).
        if (width == 0u) {
            var n_fg_rgb = vec3<f32>(0.0);
            var uvs = vec4<f32>(0.0);
            var has_glyph = false;
            var gw = params.cell_w;
            var n_is_selected = false;
            if (lc > 0u) {
                let ni = lr * params.cols + (lc - 1u);
                let nlo = cells[ni * 2u];
                let nhi = cells[ni * 2u + 1u];
                let nwidth = ((nlo >> 31u) & 1u) | ((nhi & 1u) << 1u);
                if (nwidth == 2u) {
                    let ncontent = nlo & 0x1FFFFFu;
                    let nstyle = (nlo >> 21u) & 0x3FFu;
                    let ncflags = (nhi >> 1u) & 0x7Fu;
                    let nslot = (nhi >> 8u) & 0x1FFu;
                    if (ncontent != 0x20u && ncontent != 0u) {
                        var su = -1;
                        if (nslot == 0x1FFu) {
                            su = pinned_slot(ncontent);
                        } else if (nslot < 512u) {
                            su = i32(nslot);
                        }
                        if (su >= 0) {
                            n_is_selected = cell_is_selected(ncflags);
                            if ((ncflags & CELL_FLAG_DIRECT_COLOR) != 0u && !cell_is_selected(ncflags)) {
                                let nfg_argb = colors[ni * COLOR_WORDS_PER_CELL];
                                if (nfg_argb != 0u) {
                                    n_fg_rgb = unpack_argb(nfg_argb).rgb;
                                } else {
                                    n_fg_rgb = r5g6b5_to_rgb(lut_fg(nstyle));
                                }
                            } else {
                                let nfg_packed = select(lut_fg(nstyle), lut_selection_fg(), cell_is_selected(ncflags));
                                n_fg_rgb = r5g6b5_to_rgb(nfg_packed);
                            }
                            gw = params.cell_w * 2.0;
                            uvs = slot_uv(u32(su), gw);
                            has_glyph = true;
                        }
                    }
                }
            }
            for (var py = y0; py < y1; py++) {
                for (var px = x0; px < x1; px++) {
                    var col = background.rgb;
                    var glyph_coverage = 0.0;
                    if (has_glyph) {
                        let fx = ((f32(px) + 0.5) - (cell_x0 - params.cell_w)) / gw;
                        let fy = ((f32(py) + 0.5) - cell_y0) / params.cell_h;
                        if (fx >= 0.0 && fx < 1.0 && fy >= 0.0 && fy < 1.0) {
                            let u = uvs.x + fx * (uvs.z - uvs.x);
                            let v = uvs.y + fy * (uvs.w - uvs.y);
                            let alpha = textureSampleLevel(
                                atlas_texture, atlas_sampler,
                                vec2<f32>(u, v), 0.0).r;
                            if (alpha >= 0.01) {
                                let n_fg_eff = select(n_fg_rgb * params.cell_opacity, n_fg_rgb, n_is_selected);
                                col = mix(col, n_fg_eff, alpha);
                                glyph_coverage = alpha;
                            }
                        }
                    }
                    textureStore(framebuffer, vec2<i32>(px, py), vec4<f32>(col, composited_alpha(background_alpha, glyph_coverage)));
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
        var has_glyph = false;
        var uvs = vec4<f32>(0.0);
        var gw = params.cell_w;
        if (width == 2u) {
            gw = params.cell_w * 2.0;
        }
        if (content != 0x20u && content != 0u && su >= 0) {
            uvs = slot_uv(u32(su), gw);
            has_glyph = true;
        }
        for (var py2 = y0; py2 < y1; py2++) {
            for (var px2 = x0; px2 < x1; px2++) {
                var col = background.rgb;
                var glyph_coverage = 0.0;
                if (has_glyph) {
                    let fx = ((f32(px2) + 0.5) - cell_x0) / gw;
                    let fy = ((f32(py2) + 0.5) - cell_y0) / params.cell_h;
                    if (fx >= 0.0 && fx < 1.0 && fy >= 0.0 && fy < 1.0) {
                        let u = uvs.x + fx * (uvs.z - uvs.x);
                        let v = uvs.y + fy * (uvs.w - uvs.y);
                        let alpha = textureSampleLevel(
                            atlas_texture, atlas_sampler,
                            vec2<f32>(u, v), 0.0).r;
                        if (alpha >= 0.01) {
                            let fg_eff = select(fg_rgb * params.cell_opacity, fg_rgb, cell_is_selected(cflags));
                            col = mix(col, fg_eff, alpha);
                            glyph_coverage = alpha;
                        }
                    }
                }
                textureStore(framebuffer, vec2<i32>(px2, py2), vec4<f32>(col, composited_alpha(background_alpha, glyph_coverage)));
            }
        }
    }
}
