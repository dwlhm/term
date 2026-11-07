package term

// The banner on a pane an automation holds (term auto): who drives it and how
// to take it back. It turns into a warning for a few seconds after a person
// types there (the input is held, not delivered), and into an invitation when
// the automation hands the session over (it waits for the person to type).

import "core:fmt"
import "core:time"
import chrome_dl "../../core/chrome/draw_list"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

AUTOMATION_HELD_NOTICE :: 3 * time.Second

// Automation_Notice: a moment's message on one pane (the session is only
// compared, never read through): its input is held, or a takeover found no
// automation to take the session back from.
Automation_Notice_Kind :: enum u8 { Held, None }

Automation_Notice :: struct {
	session: ^sess_feat.Terminal_Session,
	until:   time.Tick,
	kind:    Automation_Notice_Kind,
}

// app_automation_note_input: a person typed or clicked into sess; when an
// automation holds it, the banner says that the input is held.
app_automation_note_input :: proc(app: ^Term_App, sess: ^sess_feat.Terminal_Session) {
	owner, pass := sess_feat.session_controller(sess)
	if len(owner) == 0 || pass do return
	app.automation_notice = {sess, time.tick_add(time.tick_now(), AUTOMATION_HELD_NOTICE), .Held}
}

// automation_notice_active: the notice shows for sess now.
automation_notice_active :: proc(n: Automation_Notice, sess: ^sess_feat.Terminal_Session) -> bool {
	return sess != nil && n.session == sess && time.tick_diff(time.tick_now(), n.until) > 0
}

// automation_banner_emit draws a pane's banner; notice is the pane's active
// notice, if any.
automation_banner_emit :: proc(dl: ^chrome_dl.Ui_Draw_List, layout: ^Layout_State, pane: ^mux_feat.Pane_Entry, notice: Maybe(Automation_Notice_Kind)) {
	if layout == nil || pane.session == nil do return
	owner, pass := sess_feat.session_controller(pane.session)
	kind, noticed := notice.?
	if len(owner) == 0 && !(noticed && kind == .None) do return
	held := noticed && kind == .Held
	text: string
	dot := COLOR_CHROME_ACCENT
	switch {
	case len(owner) == 0:
		text, dot = "No automation drives a pane here", COLOR_CHROME_TEXT_FAINT
	case pass:
		text, dot = fmt.tprintf("%s waits for you: type here", owner), COLOR_CHROME_SUCCESS
	case held:
		text, dot = fmt.tprintf("%s holds this session: your input is held · ⇧⌘. take over", owner), COLOR_CHROME_WARNING
	case:
		text = fmt.tprintf("%s drives this session · ⇧⌘. take over", owner)
	}
	s := layout.metrics.scale
	th := FONT_CHROME_META * s
	w := min(chrome_text_width(layout.metrics, text, th) + 34.0 * s, pane.rect[2] - 16.0 * s)
	if w <= 40.0 * s do return
	r := [4]f32{pane.rect[0] + pane.rect[2] - w - 8.0 * s, pane.rect[1] + 8.0 * s, w, 24.0 * s}
	bg := COLOR_CHROME_ACCENT_SOFT if pass || held else COLOR_CHROME_RAISED
	chrome_dl.ui_draw_rounded_rect(dl, r, bg, 12.0 * s)
	chrome_dl.ui_draw_border(dl, r, COLOR_CHROME_BORDER, 12.0 * s, {}, 1.0 * s)
	chrome_dl.ui_draw_rounded_rect(dl, {r[0] + 10.0 * s, r[1] + 9.0 * s, 6.0 * s, 6.0 * s}, dot, 3.0 * s)
	chrome_dl.ui_draw_text(dl, {r[0] + 22.0 * s, r[1] + (r[3] - th) * 0.5, w - 30.0 * s, th}, text, COLOR_CHROME_TEXT)
}
