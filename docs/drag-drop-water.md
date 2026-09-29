# Drag/drop water surface

Production (verified source graph):

```ts
app_dispatch_input_events (src/app/main.odin:1228)
  → drop_fx_handle (src/app/drop_fx.odin:54)
    → [valid movement, distance-resampled] _drop_fx_spawn (src/app/drop_fx.odin:33)
      → {Drop_Fx_State.splashes: 16 immutable logical-space origins}
    → [File/Text] one impact per transaction; payload routing remains in dispatch
    → [Complete] stop emitter, retain live waves
  → drop_fx_tick (src/app/drop_fx.odin:119)
    → [live] age waves and request redraw
    → [last expiry] one cleanup redraw; then idle
  → _app_stage_ui (src/app/main.odin:2198)
    → ui_stage_water_surface (src/ui/ui_render.odin:39)
      → [finite valid waves] one full-window quad, marker -3
      → {cached Uniform_Data: 544 bytes, logical origins + content scale}
      → [empty/invalid/full staging] no effect quad; clear cached water tail
  → instance_renderer_upload_uniforms (src/render/instance/instance.odin:81)
    → render transaction (src/render/renderer.odin:1044)
      → _metal_render_set_bind_group (src/render/gpu/metal/metal.odin:832)
        → [uniform-only, valid range, ≤4096 bytes] encoder-owned vertex/fragment byte snapshot
        → [other buffers] existing buffer binding
      → fs_main (src/render/shaders/msl_spike/bg.msl:121)
        → water_height (src/render/shaders/msl_spike/bg.msl:56)
          → sum compact multiscale height packets at fixed origins
        → water_surface (src/render/shaders/msl_spike/bg.msl:93)
          → finite-difference gradient of summed height → one normal → muted directional reflection
          → alpha-blended surface; zero coverage outside disturbances
```

Each 22 logical pixels of motion emits a modest wake. Residual path distance survives successive events, so sampling does not depend on event density. Stationary input emits nothing. Long segments retain at most the latest 16 samples without unbounded iteration; saturated pools replace the oldest normalized age, with a rotating scan to resolve equal-age ties. Invalid coordinates invalidate the path anchor; the next valid point starts locally instead of bridging across bad input. File/Text payloads retain their original ownership and delivery; only visual impacts are deduplicated.

The shared uniform prefix remains compatible with glyph shaders. Resize changes the cached screen dimensions without losing wave data. The surface converts physical fragment positions to logical coordinates once using the content scale; origins remain logical. Per-encoder uniform snapshots prevent later CPU uploads from changing an already encoded draw. Storage buffers keep their existing binding behavior.

The surface uses broad compact wave packets with a dominant component and smaller, faster-decaying detail. Spatial phase variation is anchored to the window rather than the current pointer. Heights interfere before lighting, so overlapping wakes form one surface rather than independent alpha-added ring outlines. Legacy -1/-2 effects remain exported for compatibility; production uses -3 only. Nonnegative atlas UV values retain solid background rendering.

## Research context and limits

The analytical height-field/normal approach follows the general technique described in [GPU Gems, Chapter 1: Effective Water Simulation from Physical Models](https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models). This implementation is a bounded visual approximation, not a fluid solver. It samples no scene texture and does not implement physical refraction. The link is background research, not evidence of runtime correctness.

## Verification

`make build`, `make check`, `make test-app`, `make test-ui`, and `make test-render` completed successfully (exit 0). Added tests cover fixed origins, density-independent sampling/residuals, stationary input, saturation with equal-age retention, invalid-input recovery, payload impact deduplication, expiry/idle, modal parity, actual production UI staging with Retina scale, bounded one-quad staging, full uniform upload, and resize-tail preservation. Layout assertions pin the 16-byte prefix and 32-byte wave records.

Runtime Metal compilation/readback, encoder snapshot readback, and visual contact-sheet/animation inspection remain unverified for this revision: the requested GPU command was cancelled before execution while awaiting escalation. Odin build embeds MSL source and does not validate its runtime compilation. Earlier ring-shader previews do not validate this new surface.
