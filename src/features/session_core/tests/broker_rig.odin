package feature_session_core_tests

// Helpers for the broker state machine tests: a fake clock and effect lookups.

import core ".."

NOW :: i64(1_000_000_000)

fake_now := NOW

broker_new :: proc() -> ^core.Broker {
	fake_now = NOW
	b := new(core.Broker)
	core.broker_init(b, proc() -> i64 { return fake_now })
	return b
}

broker_free :: proc(b: ^core.Broker) {
	core.broker_destroy(b)
	free(b)
}

tell :: proc(b: ^core.Broker, from, to: u32, body := "do it", shell := core.Shell_Readiness.None, waiter := -1, timeout_ms := u32(0), parent := u64(0)) -> (u64, core.Broker_Reject) {
	return core.broker_tell(b, from, to, body, timeout_ms, fake_now, shell, waiter, parent)
}

listen :: proc(b: ^core.Broker, sid: u32, viewer: int, timeout_ms := u32(0)) {
	core.broker_next(b, sid, viewer, timeout_ms, fake_now)
}

// effect returns the request an effect of the last call carries (nil: none).
effect :: proc(b: ^core.Broker, kind: core.Broker_Effect_Kind, viewer := -1, sid := u32(0)) -> ^core.Broker_Request {
	for e in b.effects[:b.n_effects] {
		if e.kind != kind || (viewer >= 0 && e.viewer != viewer) || (sid != 0 && e.sid != sid) do continue
		return &b.reqs[max(e.req, 0)]
	}
	return nil
}

has :: proc(b: ^core.Broker, kind: core.Broker_Effect_Kind, viewer := -1, sid := u32(0)) -> bool {
	for e in b.effects[:b.n_effects] {
		if e.kind == kind && (viewer < 0 || e.viewer == viewer) && (sid == 0 || e.sid == sid) do return true
	}
	return false
}

