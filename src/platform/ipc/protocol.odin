package platform_ipc

// Protocol validation, once per *_open (spec 7.3): kinds 0..2 and the
// HELLO/FAIL kinds belong to the package; a request kind appears once; every
// request has a non-zero answer. Answer and progress kinds may be shared by
// several rows (term answers many requests with OK).

@(private)
_HELLO_DEFAULT :: u8(3)
@(private)
_FAIL_DEFAULT :: u8(4)

// _protocol_resolve fills the default kinds and checks the catalog; link =
// a Link (no catalog), otherwise a Server or Client (catalog required).
@(private)
_protocol_resolve :: proc(proto: Protocol, link: bool) -> (p: Protocol, err: Error) {
	p = proto
	if p.hello_kind == 0 do p.hello_kind = _HELLO_DEFAULT
	if p.fail_kind == 0 do p.fail_kind = _FAIL_DEFAULT
	switch {
	case p.hello_kind <= 2 || p.fail_kind <= 2 || p.hello_kind == p.fail_kind:
		return p, {kind = .Bad_Protocol, reason = "hello_kind and fail_kind must be two kinds above 2"}
	case link && len(p.catalog) > 0:
		return p, {kind = .Bad_Protocol, reason = "a Link has no catalog"}
	case !link && len(p.catalog) == 0:
		return p, {kind = .Bad_Protocol, reason = "a Server or Client needs a catalog"}
	}
	for row, i in p.catalog {
		if reason := _row_problem(p, row, p.catalog[:i]); reason != "" do return p, {kind = .Bad_Protocol, reason = reason}
	}
	return p, {}
}

@(private = "file")
_row_problem :: proc(p: Protocol, row: Msg_Spec, before: []Msg_Spec) -> string {
	reserved :: proc(p: Protocol, k: u8) -> bool { return k <= 2 || k == p.hello_kind || k == p.fail_kind }
	if reserved(p, row.request) do return "a catalog kind is reserved by the package"
	for b in before do if b.request == row.request do return "a request kind appears twice"
	if row.notice do return ""
	if row.answer == 0 do return "a request has no answer kind"
	if reserved(p, row.answer) || (row.progress != 0 && reserved(p, row.progress)) do return "a catalog kind is reserved by the package"
	return ""
}
