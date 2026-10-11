package frame

// Production frame tick for the OS-Style Layer Compositor Architecture.
// The single frame loop reused by the app and harnesses: transition update ->
// scheduler gate -> raster dirty layers -> acquire target -> composite -> submit -> present.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Invariants:
// 1. ZERO Horizontal Dependencies: Imports ONLY base:runtime, contract "../../render/contract",
//    and composer sibling packages. No imports of terminal, chrome, ui, platform, or app.
// 2. Zero dynamic heap allocation during steady-state.
// 3. Injectable clock: Uses explicit now_ns directly (ZERO wall-clock platform_now).
// 4. Strict adherence to Odin -strict-style.

import "base:runtime"
import contract "../../render/contract"
import composer "../"
import pipeline "../pipeline"
import scheduler "../scheduler"
import transition "../transition"

// Frame_Acquire_Proc acquires the frame target (e.g. surface texture) to composite into.
Frame_Acquire_Proc :: proc(user: rawptr) -> (tex: contract.Gpu_Texture, view: contract.Gpu_TextureView, ok: bool)

// Frame_Raster_Proc encodes raster work for one dirty layer into its backing view.
Frame_Raster_Proc :: proc(user: rawptr, enc: contract.Gpu_CommandEncoder, l: ^composer.Composer_Layer) -> bool

// Frame_Present_Proc presents (and releases) the acquired frame target.
Frame_Present_Proc :: proc(user: rawptr, tex: contract.Gpu_Texture, view: contract.Gpu_TextureView) -> bool

Frame_Driver :: struct {
	user:    rawptr,
	acquire: Frame_Acquire_Proc,
	raster:  Frame_Raster_Proc,
	present: Frame_Present_Proc,
}

Frame_Fail :: enum {
	None,
	Acquire_Failed,
	Encoder_Failed,
	Composite_Failed,
	Submit_Failed,
	Present_Failed,
}

Frame_Outcome :: struct {
	ticked:          bool,
	raster_calls:    int,
	composite_calls: int,
	submits:         int,
	presented:       bool,
	wake_at:         u64,
	fail:            Frame_Fail,
}

// frame_tick runs one iteration of the frame loop against an injected clock (now_ns).
// tm may be nil. Returns wake_at when no frame is needed.
frame_tick :: proc(
	s: ^scheduler.Frame_Scheduler,
	cp: ^pipeline.Composer_Pipeline,
	tm: ^transition.Transition_Manager,
	d: ^Frame_Driver,
	now_ns: u64,
) -> Frame_Outcome {
	out: Frame_Outcome
	if s == nil || cp == nil || d == nil do return out

	// 1. Advance transitions (moves dest_rect/opacity, marks damage; never marks layers dirty).
	if tm != nil {
		_ = transition.transition_update(tm, s, cp.layer_pool.layers[:], now_ns)
	}

	// 2. Scheduler gate.
	needs, wake := scheduler.scheduler_needs_frame(s, now_ns)
	if !needs {
		scheduler.scheduler_record_skip(s)
		out.wake_at = wake
		return out
	}

	// 3. Begin frame & encoder.
	pipeline.composer_pipeline_begin_frame(cp)
	enc := contract.create_command_encoder(cp.device)
	if rawptr(enc) == nil {
		out.fail = .Encoder_Failed
		return out
	}

	// 4. Raster ONLY dirty layers, back-to-front.
	for i in 0..<cp.layer_count {
		id := cp.layer_order[i]
		l := pipeline.composer_pipeline_get_layer(cp, id)
		if l != nil && l.in_use && l.is_dirty {
			_ = d.raster(d.user, enc, l)
			out.raster_calls += 1
			pipeline.composer_pipeline_mark_clean(cp, id)
		}
	}

	// 5. Acquire frame target. On failure, raster work is still submitted (layers are
	//    already clean); damage stays pending so the next tick retries composite.
	tex, view, acquired := d.acquire(d.user)
	if !acquired {
		_submit_and_release(cp, enc)
		out.submits = 1
		out.fail = .Acquire_Failed
		return out
	}

	// 6. Composite all in-use layers into the frame target.
	if pipeline.composer_pipeline_composite(cp, enc, view) {
		out.composite_calls = 1
	} else {
		out.fail = .Composite_Failed
	}

	// 7. Submit.
	if !_submit_and_release(cp, enc) && out.fail == .None {
		out.fail = .Submit_Failed
	}
	out.submits = 1

	// 8. Present; on success clear damage and consume an expired one-shot deadline.
	out.presented = d.present(d.user, tex, view)
	if out.presented {
		scheduler.scheduler_frame_done(s)
		if s.next_deadline != 0 && now_ns >= s.next_deadline {
			scheduler.scheduler_set_deadline(s, 0)
		}
	} else if out.fail == .None {
		out.fail = .Present_Failed
	}

	// 9. Finalize.
	pipeline.composer_pipeline_end_frame(cp)
	out.ticked = true
	return out
}

// _submit_and_release finishes, submits, and releases the command buffer and encoder.
@(private = "file")
_submit_and_release :: proc(cp: ^pipeline.Composer_Pipeline, enc: contract.Gpu_CommandEncoder) -> bool {
	cmd := contract.finish_command_buffer(enc)
	ok := contract.submit(cp.queue, cmd)
	contract.release_command_buffer(cmd)
	contract.release_command_encoder(enc)
	return ok
}
