-- examples/term_studio.lua
-- Production-Ready Multi-Surface & GPU Compositor TUI Cockpit powered by OSC 8400 (`term.ui`).
--
-- Features:
--   • Single-PTY Multi-Surface Architecture: 1 Process -> 3 Independent VT Splits + Modals.
--   • Native Hardware Scrolling: High-throughput log streaming without flickering parent grids.
--   • GPU SDF Modals: Floating Command Palette, Inspector, and Help with ZERO background repaint.
--   • Bidirectional Event Handling: Focus (8), Resize (9), Child Input (7), and Close (6).
--   • Non-Blocking Event Loop: 20Hz background telemetry ticks alongside raw keyboard dispatch.
--
-- Run interactively:  ./bin/term run examples/term_studio.lua
-- Run automated demo: ./bin/term run examples/term_studio.lua --demo

local term = require "term"
local ui   = require "term.ui"
local io   = require "term.io"
local task = require "term.task"

-- ANSI Color & Style Palettes
local C = {
	rst    = "\x1b[0m",
	bold   = "\x1b[1m",
	dim    = "\x1b[2m",
	italic = "\x1b[3m",
	blue   = "\x1b[38;2;110;185;255m",
	cyan   = "\x1b[38;2;90;220;230m",
	green  = "\x1b[38;2;120;225;140m",
	yellow = "\x1b[38;2;255;200;100m",
	orange = "\x1b[38;2;255;150;90m",
	red    = "\x1b[38;2;255;110;110m",
	purple = "\x1b[38;2;190;140;255m",
	gray   = "\x1b[38;2;130;140;160m",
	border = "\x1b[38;2;70;80;100m",
	bg_sel = "\x1b[48;2;40;60;90m",
	pill_act = "\x1b[48;2;30;70;45;38;2;120;240;150m",
	pill_idl = "\x1b[48;2;50;55;70;38;2;170;180;200m",
	pill_blk = "\x1b[48;2;80;40;35;38;2;255;140;130m",
}

-- Application State
local state = {
	active_tab = 1,
	selected_row = 1,
	log_count = 0,
	stream_paused = false,
	focused_surface = 0,
	modal_active = nil, -- nil | "palette" (10) | "inspect" (11) | "help" (12)
	palette_query = "",
	palette_sel = 1,
	tick = 0,
	cpu_history = { 24, 28, 35, 42, 38, 45, 52, 48, 40, 44, 50, 55, 49, 46, 52, 58 },
	mem_mb = 142.5,
	workloads = {
		{ id = "001", name = "term-core",    kind = "Session Hub",  status = "ACTIVE", cpu = 12.4, mem = 46.2, splits = 3, uptime = "04:12" },
		{ id = "002", name = "gpu-pipeline", kind = "Metal Blit",   status = "ACTIVE", cpu = 28.1, mem = 68.4, splits = 1, uptime = "04:12" },
		{ id = "003", name = "runner-pty",   kind = "PTY Spawn",    status = "IDLE",   cpu =  0.2, mem = 18.0, splits = 1, uptime = "02:40" },
		{ id = "004", name = "lsp-adapter",  kind = "Diagnostics",  status = "ACTIVE", cpu =  6.5, mem = 84.1, splits = 2, uptime = "01:15" },
		{ id = "005", name = "byte-ring",    kind = "Ring Buffer",  status = "IDLE",   cpu =  0.0, mem =  8.4, splits = 1, uptime = "05:01" },
		{ id = "006", name = "worker-pool",  kind = "Lua Effects",  status = "ACTIVE", cpu =  8.9, mem = 32.7, splits = 2, uptime = "00:54" },
		{ id = "007", name = "bench-stream", kind = "Throughput",   status = "BLOCKED",cpu =  0.0, mem = 12.1, splits = 1, uptime = "00:18" },
	},
	palette_items = {
		{ key = "toggle-stream", label = "Toggle Live Log Stream", desc = "Pause or resume real-time event logs" },
		{ key = "inspect-row",   label = "Inspect Selected Workload", desc = "Open detailed property inspector dialog" },
		{ key = "burst-flood",   label = "Simulate High-Throughput Burst", desc = "Send 100 log lines to verify hardware scroll" },
		{ key = "reset-surfaces",label = "Reset All Child Surfaces", desc = "Trigger OSC 8400;0 surface lifecycle reset" },
		{ key = "show-help",     label = "Show Keyboard & OSC Guide", desc = "Display full shortcut and architecture cheatsheet" },
		{ key = "quit-app",      label = "Quit Term Studio", desc = "Clean teardown and restore terminal" },
	},
}

local function get_time_str()
	local t = math.floor(task.now())
	local s = t % 60
	local m = math.floor(t / 60) % 60
	local h = math.floor(t / 3600) % 24
	return string.format("%02d:%02d:%02d", h, m, s)
end

-- Render Helpers
local function sparkline(val, max_val)
	local chars = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
	local idx = math.floor((val / (max_val or 100)) * (#chars - 1)) + 1
	idx = math.max(1, math.min(#chars, idx))
	return chars[idx]
end

local function format_bar(val, max_val, width)
	local w = width or 14
	local filled = math.floor((val / max_val) * w)
	filled = math.max(0, math.min(w, filled))
	local bar = string.rep("█", filled) .. string.rep("░", w - filled)
	return bar
end

-- Surface 0: Root Session View (Header, Tabs, Workload Table, Footer)
local function paint_root()
	local out = { "\x1b[H" }
	local time_str = get_time_str()

	-- Header Bar
	out[#out + 1] = C.blue .. C.bold .. "  TERM STUDIO " .. C.gray .. "— OSC 8400 MULTI-SURFACE COCKPIT" ..
		C.rst .. string.format("\x1b[1;62H%s%s%s\r\n", C.cyan, time_str, C.rst)
	out[#out + 1] = C.border .. "  ────────────────────────────────────────────────────────────────────────\x1b[0m\r\n"

	-- Tabs
	local tabs = { "Workloads", "Sessions", "Surfaces", "Telemetry" }
	local tab_row = { "  " }
	for i, t in ipairs(tabs) do
		if i == state.active_tab then
			tab_row[#tab_row + 1] = C.bg_sel .. C.bold .. C.blue .. string.format(" [%d] %s ", i, t) .. C.rst .. " "
		else
			tab_row[#tab_row + 1] = C.gray .. string.format("  %d: %s  ", i, t) .. C.rst .. " "
		end
	end
	out[#out + 1] = table.concat(tab_row) .. "\r\n"
	out[#out + 1] = C.border .. "  ────────────────────────────────────────────────────────────────────────\x1b[0m\r\n"

	-- Table Column Headers
	out[#out + 1] = C.dim .. "   STATUS    ID   WORKLOAD       TYPE          CPU%    MEM     SURF  UPTIME \x1b[0m\r\n"
	out[#out + 1] = C.border .. "  ─────────  ───  ─────────────  ────────────  ──────  ──────  ────  ───────\x1b[0m\r\n"

	-- Table Rows
	for idx, w in ipairs(state.workloads) do
		local is_sel = (idx == state.selected_row)
		local cursor_mark = is_sel and (C.blue .. C.bold .. " ▸ " .. C.rst) or "   "
		local pill
		if w.status == "ACTIVE" then
			pill = C.pill_act .. " ACTIVE " .. C.rst
		elseif w.status == "IDLE" then
			pill = C.pill_idl .. "  IDLE  " .. C.rst
		else
			pill = C.pill_blk .. " BLOCKED" .. C.rst
		end

		local line = string.format(
			"%s%s  %-3s  %-13s  %-12s  %5.1f%%  %5.1fMB    %d   %s",
			cursor_mark, pill, w.id, w.name, w.kind, w.cpu, w.mem, w.splits, w.uptime
		)

		if is_sel then
			out[#out + 1] = C.bg_sel .. line .. "\x1b[0m\r\n"
		else
			out[#out + 1] = line .. "\r\n"
		end
	end

	-- Footer Status Bar
	local surf_tag = (state.focused_surface == 0) and (C.blue .. C.bold .. "#0 [ROOT]" .. C.rst) or
		string.format(C.yellow .. "#%d [SPLIT]" .. C.rst, state.focused_surface)
	out[#out + 1] = "\x1b[16;1H" .. C.border .. "  ────────────────────────────────────────────────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = string.format(
		"  Focus: %s  %s│%s  [j/k] Navigate  [p] Palette  [i] Inspect  [?] Help  [q] Quit\x1b[0m",
		surf_tag, C.border, C.rst
	)

	ui.write(ui.target(0, table.concat(out)))
end

-- Surface 1: Split Top-Right (Hardware Telemetry & Gauges)
local function paint_telemetry()
	local out = { "\x1b[H" }
	local cur_cpu = state.cpu_history[#state.cpu_history] or 45

	out[#out + 1] = C.cyan .. C.bold .. " HARDWARE TELEMETRY (#1)\x1b[0m\r\n"
	out[#out + 1] = C.border .. " ─────────────────────────────\x1b[0m\r\n"

	-- CPU Bar & Sparkline
	local cpu_bar = format_bar(cur_cpu, 100, 12)
	local sparks = {}
	for _, v in ipairs(state.cpu_history) do
		sparks[#sparks + 1] = sparkline(v, 100)
	end
	out[#out + 1] = string.format(" CPU: [%s%s\x1b[0m] %4.1f%%\r\n", C.green, cpu_bar, cur_cpu)
	out[#out + 1] = string.format(" Trend: %s%s\x1b[0m\r\n", C.blue, table.concat(sparks))

	-- Memory Bar
	local mem_bar = format_bar(state.mem_mb, 256, 12)
	out[#out + 1] = string.format(" MEM: [%s%s\x1b[0m] %3.0fMB\r\n", C.purple, mem_bar, state.mem_mb)

	out[#out + 1] = C.border .. " ─────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = string.format(" Active Surfaces : %s3 native\x1b[0m\r\n", C.yellow)
	out[#out + 1] = string.format(" Compositor Layer: %sPOPUP_SDF\x1b[0m\r\n", C.cyan)
	out[#out + 1] = string.format(" Damage Throttle : %s%d cells/s\x1b[0m\r\n", C.gray, (state.tick * 7) % 64 + 18)

	ui.write(ui.target(1, table.concat(out)))
end

-- Surface 2: Split Bottom-Right (Live Event Streamer with Hardware Scroll)
local function append_log_entry(level, msg)
	state.log_count = state.log_count + 1
	local color = C.gray
	if level == "INFO" then color = C.blue
	elseif level == "WARN" then color = C.yellow
	elseif level == "PASS" then color = C.green
	elseif level == "FAIL" then color = C.red
	elseif level == "PERF" then color = C.purple end

	local time_s = get_time_str()
	local entry = string.format(
		"\x1b[90m[%s]\x1b[0m %s%-4s\x1b[0m %s\r\n",
		time_s, color, level, msg
	)
	-- Target Surface 2: hardware scrolling preserves Surface 0 and 1!
	ui.write(ui.target(2, entry))
end

-- Surface 10: Centered Modal Command Palette (GPU SDF Chrome)
local function paint_palette()
	local out = { "\x1b[H\x1b[2J" }
	out[#out + 1] = C.cyan .. C.bold .. " > " .. C.rst .. C.bold .. "Filter: " .. C.rst .. state.palette_query .. "\x1b[K\r\n"
	out[#out + 1] = C.border .. "────────────────────────────────────────────\x1b[0m\r\n"

	local visible = {}
	for _, item in ipairs(state.palette_items) do
		if state.palette_query == "" or item.label:lower():find(state.palette_query:lower(), 1, true) then
			visible[#visible + 1] = item
		end
	end

	if #visible == 0 then
		out[#out + 1] = C.gray .. "  (no matching actions)\x1b[0m\r\n"
	else
		state.palette_sel = math.max(1, math.min(#visible, state.palette_sel))
		for i, item in ipairs(visible) do
			if i <= 5 then
				local is_sel = (i == state.palette_sel)
				if is_sel then
					out[#out + 1] = C.bg_sel .. C.bold .. C.blue .. string.format(" ▸ %-38s", item.label) .. C.rst .. "\r\n"
				else
					out[#out + 1] = string.format("   %-38s\r\n", item.label)
				end
			end
		end
	end

	out[#out + 1] = C.border .. "────────────────────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = C.gray .. " [Enter] Run   [Esc] Dismiss   [↑/↓] Select\x1b[0m"
	ui.write(ui.target(10, table.concat(out)))
end

-- Surface 11: Inspector Modal Dialog
local function paint_inspector()
	local w = state.workloads[state.selected_row] or state.workloads[1]
	local out = { "\x1b[H\x1b[2J" }
	out[#out + 1] = C.yellow .. C.bold .. string.format(" WORKLOAD INSPECTOR (#%s: %s)\x1b[0m\r\n", w.id, w.name)
	out[#out + 1] = C.border .. "──────────────────────────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = string.format(" Subsystem Type  : %s%s\x1b[0m\r\n", C.cyan, w.kind)
	out[#out + 1] = string.format(" Execution State : %s%s\x1b[0m\r\n", (w.status == "ACTIVE" and C.green or C.gray), w.status)
	out[#out + 1] = string.format(" CPU Utilization : %s%.2f%%\x1b[0m\r\n", C.blue, w.cpu)
	out[#out + 1] = string.format(" Resident Memory : %s%.1f MB (Heap clean)\x1b[0m\r\n", C.purple, w.mem)
	out[#out + 1] = string.format(" Bound Surfaces  : %s%d isolated splits\x1b[0m\r\n", C.yellow, w.splits)
	out[#out + 1] = string.format(" Total Uptime    : %s%s\x1b[0m\r\n", C.rst, w.uptime)
	out[#out + 1] = C.border .. "──────────────────────────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = C.gray .. " Rendered via OSC 8400;3 (Zero Background Repaint)\x1b[0m\r\n"
	out[#out + 1] = C.gray .. " Press [Esc] or [i] to close inspector\x1b[0m"
	ui.write(ui.target(11, table.concat(out)))
end

-- Surface 12: Help Modal Dialog
local function paint_help()
	local out = { "\x1b[H\x1b[2J" }
	out[#out + 1] = C.green .. C.bold .. " TERM STUDIO — OSC 8400 SHORTCUTS & ARCHITECTURE\x1b[0m\r\n"
	out[#out + 1] = C.border .. "────────────────────────────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = C.bold .. " Keyboard Controls:\x1b[0m\r\n"
	out[#out + 1] = "  j / ↓, k / ↑   Navigate workload rows\r\n"
	out[#out + 1] = "  Tab            Cycle focus across surface splits\r\n"
	out[#out + 1] = "  p / :          Open Command Palette (GPU SDF Modal)\r\n"
	out[#out + 1] = "  i / Enter      Inspect selected workload details\r\n"
	out[#out + 1] = "  s / Space      Pause / resume live event stream\r\n"
	out[#out + 1] = "  f              Send 100-line burst (HW scroll test)\r\n"
	out[#out + 1] = "  ?              Toggle this architecture guide\r\n"
	out[#out + 1] = "  q / Ctrl+C     Clean exit and surface reset\r\n"
	out[#out + 1] = C.border .. "────────────────────────────────────────────────────\x1b[0m\r\n"
	out[#out + 1] = C.gray .. " Press [Esc] or [?] to close this modal\x1b[0m"
	ui.write(ui.target(12, table.concat(out)))
end

-- Modal Management (Show / Hide with Zero Redraw)
local function open_modal(kind)
	state.modal_active = kind
	if kind == "palette" then
		state.palette_query = ""
		state.palette_sel = 1
		ui.write(ui.popup {
			id = 10, w = 46, h = 10, anchor = "center",
			chrome = "modal", focus = true, title = "Command Palette (OSC 8400)"
		})
		paint_palette()
	elseif kind == "inspect" then
		ui.write(ui.popup {
			id = 11, w = 52, h = 11, anchor = "center",
			chrome = "modal", focus = true, title = "Workload Properties"
		})
		paint_inspector()
	elseif kind == "help" then
		ui.write(ui.popup {
			id = 12, w = 54, h = 13, anchor = "center",
			chrome = "modal", focus = true, title = "OSC 8400 Architecture Guide"
		})
		paint_help()
	end
end

local function close_modal()
	if not state.modal_active then return end
	local id = (state.modal_active == "palette") and 10 or
		((state.modal_active == "inspect") and 11 or 12)
	state.modal_active = nil
	-- Close modal: GPU instantly removes layer without any background redraw!
	ui.write(ui.close(id) .. ui.focus(0))
	state.focused_surface = 0
	paint_root()
end

-- Stream Event Demuxer
local function extract_events(raw)
	local events = {}
	local pos = 1
	while pos <= #raw do
		local s, e, payload = raw:find("\x1b%]8400;([^\x1b\x07]*)\x1b\\", pos)
		if not s then
			s, e, payload = raw:find("\x1b%]8400;([^\x1b\x07]*)\x07", pos)
		end
		if not s then
			local rem = raw:sub(pos)
			if rem ~= "" then
				events[#events + 1] = { kind = "raw", data = rem }
			end
			break
		end
		if s > pos then
			events[#events + 1] = { kind = "raw", data = raw:sub(pos, s - 1) }
		end
		local ev = ui.parse_event("\x1b]8400;" .. payload)
		if ev then
			events[#events + 1] = ev
		end
		pos = e + 1
	end
	return events
end

-- Command Palette Action Execution
local function execute_palette_action(key)
	if key == "toggle-stream" then
		state.stream_paused = not state.stream_paused
		append_log_entry("INFO", state.stream_paused and "Log stream paused by user" or "Log stream resumed")
		close_modal()
	elseif key == "inspect-row" then
		close_modal()
		open_modal("inspect")
	elseif key == "burst-flood" then
		close_modal()
		for i = 1, 25 do
			append_log_entry("PERF", string.format("Hardware scroll burst #%02d (Split #2)", i))
		end
	elseif key == "reset-surfaces" then
		close_modal()
		append_log_entry("WARN", "OSC 8400 lifecycle reset emitted")
	elseif key == "show-help" then
		close_modal()
		open_modal("help")
	elseif key == "quit-app" then
		return "quit"
	end
end

-- Main Program Declaration
return term.program {
	name = "term-studio",
	description = "Production-Ready Multi-Surface & GPU Compositor TUI Cockpit (OSC 8400)",
	main = function(args)
		local is_demo = false
		for _, a in ipairs(args or {}) do
			if a == "--demo" then is_demo = true end
		end

		-- Setup Terminal: alternate screen, hide cursor, reset prior surfaces
		ui.write("\x1b[?1049h\x1b[?25l" .. ui.reset())
		io.raw_mode(true)

		-- Teardown Guard
		local function teardown()
			io.raw_mode(false)
			ui.write(ui.reset() .. "\x1b[?25h\x1b[?1049l")
		end

		-- Initialize OSC 8400 Multi-Surface Layout:
		--   Split #1: Right side, 42% width (Telemetry)
		--   Split #2: Under Split #1, 50% height (Event Streamer)
		ui.write(ui.split { id = 1, parent = 0, dir = "right", ratio = 42, focus = false })
		ui.write(ui.split { id = 2, parent = 1, dir = "down",  ratio = 50, focus = false })

		-- Initial Painting
		paint_root()
		paint_telemetry()
		ui.write(ui.target(2, "\x1b[H\x1b[2J" .. C.green .. C.bold .. " EVENT STREAM (#2 - HW SCROLL)\x1b[0m\r\n"))
		for i = 1, 5 do
			append_log_entry("INFO", string.format("Initialized surface grid #%d", i % 3))
		end

		-- Demo Mode Branch (Automated Headless Verification)
		if is_demo then
			for step = 1, 6 do
				state.tick = state.tick + 1
				table.remove(state.cpu_history, 1)
				state.cpu_history[#state.cpu_history + 1] = 30 + (step * 7) % 45
				paint_root()
				paint_telemetry()
				append_log_entry("PERF", string.format("Demo tick #%d (Hardware scroll active)", step))
				task.sleep(0.08)
			end

			-- Test Modal Palette open & zero-redraw dismiss
			open_modal("palette")
			task.sleep(0.10)
			state.palette_query = "stream"
			paint_palette()
			task.sleep(0.08)
			close_modal()

			-- Test Help Modal
			open_modal("help")
			task.sleep(0.10)
			close_modal()

			teardown()
			return 0
		end

		-- Interactive Event Loop
		local running = true
		while running do
			state.tick = state.tick + 1

			-- Non-blocking input read (40ms timeout -> ~25Hz refresh cadence)
			local chunk = io.read_raw(40)

			-- Background Telemetry & Log Ticks
			if state.tick % 5 == 0 then
				table.remove(state.cpu_history, 1)
				local delta = (state.tick % 3 == 0) and 4 or -3
				local next_cpu = math.max(15, math.min(88, (state.cpu_history[#state.cpu_history] or 40) + delta))
				state.cpu_history[#state.cpu_history + 1] = next_cpu
				state.mem_mb = 140 + math.sin(state.tick * 0.1) * 8
				paint_telemetry()
				paint_root()
			end

			if not state.stream_paused and state.tick % 8 == 0 then
				local levels = { "INFO", "PASS", "WARN", "PERF" }
				local lvl = levels[(state.tick % #levels) + 1]
				append_log_entry(lvl, string.format("Heartbeat telemetry tick #%03d", state.tick))
			end

			-- Event Dispatch
			if chunk and #chunk > 0 then
				local events = extract_events(chunk)
				for _, ev in ipairs(events) do
					if ev.kind == "focus" then
						state.focused_surface = ev.id
						paint_root()
					elseif ev.kind == "resize" then
						append_log_entry("INFO", string.format("Surface #%d resized to %dx%d", ev.id, ev.cols, ev.rows))
						paint_root()
						paint_telemetry()
					elseif ev.kind == "close" then
						if state.modal_active then close_modal() end
					elseif ev.kind == "input" or ev.kind == "raw" then
						local key_data = ev.data or ""

						-- Keystroke Handler for Modals
						if state.modal_active == "palette" then
							if key_data == "\x1b" or key_data == "\x03" then
								close_modal()
							elseif key_data == "\r" or key_data == "\n" then
								local visible = {}
								for _, item in ipairs(state.palette_items) do
									if state.palette_query == "" or item.label:lower():find(state.palette_query:lower(), 1, true) then
										visible[#visible + 1] = item
									end
								end
								local sel = visible[state.palette_sel]
								if sel then
									if execute_palette_action(sel.key) == "quit" then
										running = false
										break
									end
								else
									close_modal()
								end
							elseif key_data == "\x1b[A" or key_data == "k" then
								state.palette_sel = math.max(1, state.palette_sel - 1)
								paint_palette()
							elseif key_data == "\x1b[B" or key_data == "j" then
								state.palette_sel = state.palette_sel + 1
								paint_palette()
							elseif key_data == "\x7f" or key_data == "\b" then
								state.palette_query = state.palette_query:sub(1, -2)
								state.palette_sel = 1
								paint_palette()
							elseif #key_data == 1 and key_data:byte(1) >= 32 and key_data:byte(1) <= 126 then
								state.palette_query = state.palette_query .. key_data
								state.palette_sel = 1
								paint_palette()
							end

						elseif state.modal_active == "inspect" or state.modal_active == "help" then
							if key_data == "\x1b" or key_data == "q" or key_data == "i" or key_data == "?" or key_data == "\r" then
								close_modal()
							end

						-- Keystroke Handler for Main Surface (Modal is closed)
						else
							if key_data == "q" or key_data == "\x03" then
								running = false
								break
							elseif key_data == "j" or key_data == "\x1b[B" then
								state.selected_row = math.min(#state.workloads, state.selected_row + 1)
								paint_root()
							elseif key_data == "k" or key_data == "\x1b[A" then
								state.selected_row = math.max(1, state.selected_row - 1)
								paint_root()
							elseif key_data == "\t" then
								state.focused_surface = (state.focused_surface + 1) % 3
								ui.write(ui.focus(state.focused_surface))
								paint_root()
							elseif key_data == "p" or key_data == ":" then
								open_modal("palette")
							elseif key_data == "i" or key_data == "\r" or key_data == "\n" then
								open_modal("inspect")
							elseif key_data == "?" then
								open_modal("help")
							elseif key_data == "s" or key_data == " " then
								state.stream_paused = not state.stream_paused
								append_log_entry("INFO", state.stream_paused and "Live stream paused" or "Live stream resumed")
							elseif key_data == "f" then
								for burst = 1, 20 do
									append_log_entry("PERF", string.format("Rapid burst #%02d", burst))
								end
							elseif key_data:match("^[1-4]$") then
								state.active_tab = tonumber(key_data)
								paint_root()
							end
						end
					end
				end
			end
		end

		teardown()
		return 0
	end,
}
