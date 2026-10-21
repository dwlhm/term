package core_cursor

// Platform-Neutral Mouse Cursor Contract
// Part of Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU, Windowing, or Platform/OS Dependencies.

Mouse_Cursor :: enum u8 {
	Default,      // Standard arrow pointer
	Text,         // I-beam
	Pointer,      // Hand / clickable pointer
	Col_Resize,   // Horizontal split / EW resize (↔)
	Row_Resize,   // Vertical split / NS resize (↕)
	Crosshair,
	Move,
	Not_Allowed,
	Wait,
}
