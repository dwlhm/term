package main

// Term Headless E2E Test Driver: CLI Dispatcher & JSON-RPC Protocol (<250 lines)
// Part of Tier 4 Harnesses & Automation (src/cmd/term_driver/*).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import core_term "../../core/terminal"
import tabs_feat "../../features/tabs"

Cmd_Request :: struct {
	action:     string  `json:"action"`,
	cols:       int     `json:"cols"`,
	rows:       int     `json:"rows"`,
	shell:      string  `json:"shell"`,
	text:       string  `json:"text"`,
	key:        string  `json:"key"`,
	timeout_ms: int     `json:"timeout_ms"`,
	wait_text:  string  `json:"wait_text"`,
	direction:  string  `json:"direction"`,
	ratio:      f32     `json:"ratio"`,
	tab_index:  int     `json:"tab_index"`,
}

write_state_json :: proc(d: ^Driver) {
	t := driver_get_active_term(d)
	if t == nil {
		fmt.println(`{"status": "error", "message": "no active terminal"}`)
		return
	}
	cur_r, cur_c := core_term.terminal_cursor_pos(t)
	alt := core_term.terminal_in_alt_screen(t)
	hist := core_term.terminal_history_count(t)
	tab_count := tabs_feat.tabs_manager_tab_count(&d.tm)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{{"status": "ok", "pane_id": %d, "tab_count": %d, "active_tab": %d, ` +
		`"cols": %d, "rows": %d, "cursor": [%d, %d], "alt_screen": %s, "history": %d, "grid": [`,
		d.active_pane_id,
		tab_count,
		d.tm.model.active_idx,
		t.cols,
		t.rows,
		cur_r,
		cur_c,
		"true" if alt else "false",
		hist,
	)

	for r in 0 ..< t.rows {
		if r > 0 do strings.write_string(&b, ", ")
		strings.write_byte(&b, '"')
		for c in 0 ..< t.cols {
			cell := core_term.terminal_get_cell(t, r, c)
			if .Wide_Continuation in cell.flags do continue
			if cell.char == '\\' || cell.char == '"' {
				strings.write_byte(&b, '\\')
				strings.write_rune(&b, cell.char)
			} else if cell.char >= 32 {
				strings.write_rune(&b, cell.char)
			} else {
				strings.write_byte(&b, ' ')
			}
		}
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]}")
	fmt.println(strings.to_string(b))
}

handle_key :: proc(d: ^Driver, key: string) -> bool {
	switch key {
	case "Enter":     return driver_send(d, "\r")
	case "Tab":       return driver_send(d, "\t")
	case "Backspace": return driver_send(d, "\x7f")
	case "Escape":    return driver_send(d, "\x1b")
	case "Up":        return driver_send(d, "\033[A")
	case "Down":      return driver_send(d, "\033[B")
	case "Right":     return driver_send(d, "\033[C")
	case "Left":      return driver_send(d, "\033[D")
	case "Home":      return driver_send(d, "\033[H")
	case "End":       return driver_send(d, "\033[F")
	case "PageUp":    return driver_send(d, "\033[5~")
	case "PageDown":  return driver_send(d, "\033[6~")
	case "Cmd+T":
		_, ok := driver_tab_new(d)
		return ok
	case "Cmd+W":
		return driver_tab_close(d, -1)
	case:
		return driver_send(d, key)
	}
}

dispatch_command :: proc(d: ^Driver, cmd: Cmd_Request) -> bool {
	switch cmd.action {
	case "init":
		if d.initialized do driver_destroy(d)
		if !driver_init(d, cmd.cols, cmd.rows, cmd.shell) {
			fmt.println(`{"status": "error", "message": "init failed"}`)
			return true
		}
		fmt.printfln(`{{"status": "ok", "pane_id": %d}}`, d.active_pane_id)
	case "send":
		driver_send(d, cmd.text)
		fmt.println(`{"status": "ok"}`)
	case "feed":
		t := driver_get_active_term(d)
		if t != nil {
			core_term.terminal_feed_string(t, cmd.text)
			write_state_json(d)
		} else {
			fmt.println(`{"status": "error", "message": "no active terminal"}`)
		}
	case "key":
		handle_key(d, cmd.key)
		fmt.println(`{"status": "ok"}`)
	case "drain":
		found := driver_drain(d, cmd.timeout_ms, cmd.wait_text)
		if !found {
			fmt.println(`{"status": "timeout"}`)
		} else {
			write_state_json(d)
		}
	case "resize":
		driver_resize(d, cmd.cols, cmd.rows)
		fmt.println(`{"status": "ok"}`)
	case "split":
		nid, ok := driver_split(d, cmd.direction, cmd.ratio)
		if ok {
			fmt.printfln(`{{"status": "ok", "pane_id": %d}}`, nid)
		} else {
			fmt.println(`{"status": "error", "message": "split failed"}`)
		}
	case "tab_new":
		tid, ok := driver_tab_new(d)
		if ok {
			fmt.printfln(`{{"status": "ok", "tab_id": %d}}`, tid)
		} else {
			fmt.println(`{"status": "error", "message": "tab_new failed"}`)
		}
	case "tab_close":
		driver_tab_close(d, cmd.tab_index)
		fmt.println(`{"status": "ok"}`)
	case "get_state":
		write_state_json(d)
	case "quit":
		fmt.println(`{"status": "ok"}`)
		return false
	case:
		fmt.printfln(`{{"status": "error", "message": "unknown action %s"}}`, cmd.action)
	}
	return true
}

read_line_from_stdin :: proc(buf: ^[dynamic]u8) -> bool {
	clear(buf)
	byte_buf: [1]u8
	for {
		n, err := os.read(os.stdin, byte_buf[:])
		if err != nil || n == 0 {
			return len(buf) > 0
		}
		if byte_buf[0] == '\n' {
			return true
		}
		append(buf, byte_buf[0])
	}
}

main :: proc() {
	d: Driver
	defer driver_destroy(&d)

	line_buf: [dynamic]u8
	defer delete(line_buf)

	for {
		free_all(context.temp_allocator)
		if !read_line_from_stdin(&line_buf) do break

		trimmed := strings.trim_space(string(line_buf[:]))
		if len(trimmed) == 0 do continue

		cmd: Cmd_Request
		unmarshal_err := json.unmarshal(transmute([]u8)trimmed, &cmd, allocator = context.temp_allocator)
		if unmarshal_err != nil {
			fmt.printfln(`{{"status": "error", "message": "invalid json: %v"}}`, unmarshal_err)
			continue
		}

		if !dispatch_command(&d, cmd) do break
	}
}
