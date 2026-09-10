package render

// Arabic presentation-form joining: codepoint substitution preserving the
// 1-cell-1-glyph grid invariant. No HarfBuzz, no ligatures, no bidi: each
// cell independently maps its logical codepoint to at most one presentation
// form codepoint selected from its immediate neighbors. Slow path only.

// Join_Form selects which presentation form a joining letter takes.
Join_Form :: enum u8 {
	Isolated = 0,
	Initial  = 1,
	Medial   = 2,
	Final    = 3,
}

// Join_Type classifies a codepoint's cursive-joining behavior.
Join_Type :: enum u8 {
	Non_Joining      = 0,
	Right_Joining    = 1, // joins the previous cell only (e.g. ALEF)
	Dual_Joining     = 2, // joins both neighbors (e.g. BEH)
	Transparent      = 3, // combining mark: never breaks a join
	Join_Causing_ZWJ = 4, // ZWJ: treated as a boundary (no ligatures)
}

// ARABIC_ZWNJ is a hard join boundary on both sides.
ARABIC_ZWNJ :: rune(0x200C)

// _ARABIC_ZWJ never merges cells (Phase-10 policy: no ligatures).
_ARABIC_ZWJ :: rune(0x200D)

// arabic_join_type classifies a codepoint from the static 0600-08FF tables
// (plus ZWJ/ZWNJ). Anything unlisted is Non_Joining. Slow-path only.
arabic_join_type :: proc(cp: rune) -> Join_Type {
	if cp == _ARABIC_ZWJ {
		return .Join_Causing_ZWJ
	}
	// Transparent combining marks (0600-08FF block + wider extends).
	if (cp >= 0x0610 && cp <= 0x061A) ||
	   (cp >= 0x064B && cp <= 0x065F) ||
	   cp == 0x0670 ||
	   (cp >= 0x06D6 && cp <= 0x06DC) ||
	   (cp >= 0x06DF && cp <= 0x06E4) ||
	   (cp >= 0x06E7 && cp <= 0x06E8) ||
	   (cp >= 0x06EA && cp <= 0x06ED) {
		return .Transparent
	}
	switch cp {
	case 0x0627, 0x0629, 0x062F, 0x0630, 0x0631, 0x0632, 0x0648:
		return .Right_Joining
	case 0x0628, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E,
	     0x0633, 0x0634, 0x0635, 0x0636, 0x0637, 0x0638,
	     0x0639, 0x063A, 0x0641, 0x0642, 0x0643, 0x0644,
	     0x0645, 0x0646, 0x0647:
		return .Dual_Joining
	}
	return .Non_Joining
}

// arabic_join_form is the pure truth table from neighbor links to form.
// Right-joining letters never take Initial/Medial; anything non-joining
// stays Isolated.
arabic_join_form :: proc(left_joins: bool, right_joins: bool, self: Join_Type) -> Join_Form {
	switch self {
	case .Dual_Joining:
		switch {
		case left_joins && right_joins:
			return .Medial
		case left_joins:
			return .Final
		case right_joins:
			return .Initial
		}
		return .Isolated
	case .Right_Joining:
		if left_joins {
			return .Final
		}
		return .Isolated
	case .Non_Joining, .Transparent, .Join_Causing_ZWJ:
		return .Isolated
	}
	return .Isolated
}

// _Arabic_Presentation maps one logical letter to its presentation forms.
// initial/medial are 0 for right-joining letters (inapplicable).
_Arabic_Presentation :: struct {
	base:              rune,
	isolated:          u32,
	initial:           u32,
	medial:            u32,
	final:             u32,
}

// _ARABIC_PRESENTATIONS is sorted ascending by base for early exit.
_ARABIC_PRESENTATIONS := [?]_Arabic_Presentation{
	{0x0627, 0xFE8D, 0, 0, 0xFE8E},
	{0x0628, 0xFE8F, 0xFE91, 0xFE92, 0xFE90},
	{0x0629, 0xFE93, 0, 0, 0xFE94},
	{0x062A, 0xFE95, 0xFE97, 0xFE98, 0xFE96},
	{0x062B, 0xFE99, 0xFE9B, 0xFE9C, 0xFE9A},
	{0x062C, 0xFE9D, 0xFE9F, 0xFEA0, 0xFE9E},
	{0x062D, 0xFEA1, 0xFEA3, 0xFEA4, 0xFEA2},
	{0x062E, 0xFEA5, 0xFEA7, 0xFEA8, 0xFEA6},
	{0x062F, 0xFEA9, 0, 0, 0xFEAB},
	{0x0630, 0xFEAD, 0, 0, 0xFEAF},
	{0x0631, 0xFEB1, 0, 0, 0xFEB3},
	{0x0632, 0xFEB5, 0, 0, 0xFEB7},
	{0x0633, 0xFEB9, 0xFEBB, 0xFEBC, 0xFEBA},
	{0x0634, 0xFEBD, 0xFEBF, 0xFEC0, 0xFEBE},
	{0x0635, 0xFEC1, 0xFEC3, 0xFEC4, 0xFEC2},
	{0x0636, 0xFEC5, 0xFEC7, 0xFEC8, 0xFEC6},
	{0x0637, 0xFEC9, 0xFECB, 0xFECC, 0xFECA},
	{0x0638, 0xFECD, 0xFECF, 0xFED0, 0xFECE},
	{0x0639, 0xFED1, 0xFED3, 0xFED4, 0xFED2},
	{0x063A, 0xFED5, 0xFED7, 0xFED8, 0xFED6},
	{0x0641, 0xFED9, 0xFEDB, 0xFEDC, 0xFEDA},
	{0x0642, 0xFEDD, 0xFEDF, 0xFEE0, 0xFEDE},
	{0x0643, 0xFEE1, 0xFEE3, 0xFEE4, 0xFEE2},
	{0x0644, 0xFEE5, 0xFEE7, 0xFEE8, 0xFEE6},
	{0x0645, 0xFEE9, 0xFEEB, 0xFEEC, 0xFEEA},
	{0x0646, 0xFEED, 0xFEEF, 0xFEF0, 0xFEEE},
	{0x0647, 0xFEF1, 0xFEF3, 0xFEF4, 0xFEF2},
}

// arabic_presentation_form maps (base, form) to the presentation codepoint.
// !ok means retry the logical codepoint: unlisted base or an inapplicable
// form (e.g. Initial on ALEF) never yields tofu when the logical is covered.
arabic_presentation_form :: proc(base: rune, form: Join_Form) -> (shaped: u32, ok: bool) {
	for e in _ARABIC_PRESENTATIONS {
		if e.base > base {
			break
		}
		if e.base != base {
			continue
		}
		switch form {
		case .Isolated:
			return e.isolated, true
		case .Initial:
			if e.initial != 0 {
				return e.initial, true
			}
			return 0, false
		case .Medial:
			if e.medial != 0 {
				return e.medial, true
			}
			return 0, false
		case .Final:
			if e.final != 0 {
				return e.final, true
			}
			return 0, false
		}
	}
	return 0, false
}

// arabic_left_joins reports whether the left neighbor joins forward into the
// current cell. Only dual-joining letters link forward; right-joining
// letters link backward only, ZWJ never links (no ligatures).
arabic_left_joins :: proc(left_cp: rune, left_type: Join_Type) -> bool {
	return left_type == .Dual_Joining
}

// _arabic_is_boundary reports whether cp breaks cursive joining on its side:
// empty/EOL, space, ASCII/Latin, ZWNJ (hard boundary), ZWJ (never merges),
// and anything non-joining (digits, punctuation, CJK, emoji...).
// Transparent marks are NOT boundaries: the caller looks through them.
_arabic_is_boundary :: proc(cp: rune) -> bool {
	if cp < 0x80 {
		return true
	}
	if cp == ARABIC_ZWNJ || cp == _ARABIC_ZWJ {
		return true
	}
	jt := arabic_join_type(cp)
	return jt == .Non_Joining || jt == .Join_Causing_ZWJ
}
