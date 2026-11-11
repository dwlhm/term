-- examples/tui_surfaces.lua
-- Single-PTY Multi-Surface & Native Popup TUI Showcase powered by OSC 8400 (`term.ui`).
-- Run interactively:  ./build/term run examples/tui_surfaces.lua
-- Run automated demo: ./build/term run examples/tui_surfaces.lua --demo

local term = require "term"
local ui   = require "term.ui"
local task = require "term.task"
local io   = require "term.io"

local function paint_editor()
	ui.write(ui.target(0, table.concat({
		"\x1b[2J\x1b[H",
		"\x1b[1;38;2;120;200;255m  TERM OSC 8400 — SINGLE-PTY COMPOSITOR TUI\x1b[0m\r\n",
		"\x1b[38;2;140;148;165m  ──────────────────────────────────────────────────\x1b[0m\r\n",
		"\r\n",
		"  \x1b[38;2;180;140;255m1\x1b[0m  local ui = require \x1b[38;2;150;220;140m\"term.ui\"\x1b[0m\r\n",
		"  \x1b[38;2;180;140;255m2\x1b[0m  \r\n",
		"  \x1b[38;2;180;140;255m3\x1b[0m  \x1b[38;2;120;130;150m-- Split right pane (independent VT grid)\x1b[0m\r\n",
		"  \x1b[38;2;180;140;255m4\x1b[0m  ui.write(ui.split {\r\n",
		"  \x1b[38;2;180;140;255m5\x1b[0m    id = 1, parent = 0, dir = \x1b[38;2;150;220;140m\"right\"\x1b[0m, ratio = 42\r\n",
		"  \x1b[38;2;180;140;255m6\x1b[0m  })\r\n",
		"  \x1b[38;2;180;140;255m7\x1b[0m  \r\n",
		"  \x1b[38;2;180;140;255m8\x1b[0m  \x1b[38;2;120;130;150m-- Spawn GPU-composited SDF Modal Popup\x1b[0m\r\n",
		"  \x1b[38;2;180;140;255m9\x1b[0m  ui.write(ui.popup {\r\n",
		" \x1b[38;2;180;140;255m10\x1b[0m    id = 10, w = 44, h = 9, anchor = \x1b[38;2;150;220;140m\"center\"\x1b[0m,\r\n",
		" \x1b[38;2;180;140;255m11\x1b[0m    chrome = \x1b[38;2;150;220;140m\"modal\"\x1b[0m, title = \x1b[38;2;150;220;140m\"Command Palette\"\x1b[0m\r\n",
		" \x1b[38;2;180;140;255m12\x1b[0m  })\r\n",
		"\r\n",
		"  \x1b[1;38;2;250;200;100mArchitecture Highlights:\x1b[0m\r\n",
		"  • 1 Process, 1 PTY, Multiple Isolated VT Grids\r\n",
		"  • Native hardware scrolling inside every split\r\n",
		"  • Zero background repaint when closing popups\r\n",
		"  • Surface-local mouse coordinates (1..cols, 1..rows)\r\n",
	})))
end

local function paint_inspector(popup_open, log_count)
	local state_str = popup_open and "\x1b[1;32mOPEN (Modal SDF)\x1b[0m" or "\x1b[90mHIDDEN\x1b[0m"
	ui.write(ui.target(2, table.concat({
		"\x1b[2J\x1b[H",
		"\x1b[1;38;2;255;190;100mSURFACE INSPECTOR (#2)\x1b[0m\r\n",
		"──────────────────────────\r\n",
		"Root (#0)  : Editor Grid\r\n",
		"Split (#1) : Live Stream\r\n",
		"Split (#2) : Inspector\r\n",
		"Popup (#10): " .. state_str .. "\r\n",
		string.format("Stream Logs: %d lines\r\n", log_count),
	})))
end

local function paint_popup()
	ui.write(ui.target(10, table.concat({
		"\x1b[2J\x1b[H",
		"\x1b[1;38;2;130;220;255m > \x1b[0m\x1b[1msearch surfaces...\x1b[0m\r\n",
		"\x1b[38;2;90;98;115m────────────────────────────────────────────\x1b[0m\r\n",
		" \x1b[48;2;45;65;95;1;37m ▸ [1] Toggle Split Log Stream      #1    \x1b[0m\r\n",
		"   [2] Inspect Surface Cell Budget  #2    \r\n",
		"   [3] Test VT420 Rectangular Fill  DECFRA\r\n",
		"   [4] Reset All Surfaces           OSC 0 \r\n",
		"\x1b[38;2;90;98;115m────────────────────────────────────────────\x1b[0m\r\n",
		" \x1b[90mRendered on POPUP_LAYER_ID (GPU SDF Chrome)\x1b[0m",
	})))
end

return term.program {
	name = "tui-surfaces",
	description = "Single-PTY Multi-Surface & Popup TUI Showcase (OSC 8400)",
	main = function(args)
		local is_demo = false
		for _, a in ipairs(args or {}) do
			if a == "--demo" then is_demo = true end
		end

		-- Enter alternate screen & reset any prior surfaces
		ui.write("\x1b[?1049h\x1b[?25l" .. ui.reset())

		-- Create Split #1 on the right (42% width) and Split #2 at bottom-right (38% height)
		ui.write(ui.split { id = 1, parent = 0, dir = "right", ratio = 42, focus = false })
		ui.write(ui.split { id = 2, parent = 1, dir = "down",  ratio = 38, focus = false })

		paint_editor()
		ui.write(ui.target(1, "\x1b[2J\x1b[H\x1b[1;38;2;140;230;160mLIVE EVENT STREAM (#1)\x1b[0m\r\n"))

		local log_count = 0
		local function append_log(msg)
			log_count = log_count + 1
			ui.write(ui.target(1, string.format(
				"\x1b[90m[%02d]\x1b[0m %s\r\n", log_count, msg
			)))
		end

		for i = 1, 6 do
			append_log("Hardware scroll in Split #1 (Root #0 untouched)")
		end
		paint_inspector(false, log_count)

		-- Spawn centered Modal Popup (#10) with native SDF frame & title
		ui.write(ui.popup {
			id = 10, w = 44, h = 8, anchor = "center",
			chrome = "modal", focus = true, title = "Command Palette (OSC 8400)"
		})
		paint_popup()
		paint_inspector(true, log_count)

		if is_demo then
			task.sleep(0.15)
			for i = 1, 8 do
				append_log("Background stream tick #" .. tostring(i) .. " under popup")
			end
			paint_inspector(true, log_count)
			task.sleep(0.15)
			-- Hide popup (zero background repaint required!)
			ui.write(ui.hide(10))
			paint_inspector(false, log_count)
			task.sleep(0.10)
			-- Show popup again, then close
			ui.write(ui.show(10))
			task.sleep(0.10)
			ui.write(ui.close(10))
		else
			local popup_open = true
			while true do
				ui.write(ui.target(0, "\x1b[22;1H\x1b[K  \x1b[1;36mCommand [p=popup, s=scroll, q=quit]:\x1b[0m "))
				local line = io.ask("")
				if not line or line == "q" then break end
				if line == "p" then
					popup_open = not popup_open
					ui.write(popup_open and ui.show(10) or ui.hide(10))
					paint_inspector(popup_open, log_count)
				elseif line == "s" then
					for _ = 1, 5 do
						append_log("Independent hardware scroll in Split #1")
					end
					paint_inspector(popup_open, log_count)
				end
			end
		end

		-- Clean teardown: reset all child surfaces and leave alternate screen
		ui.write(ui.reset() .. "\x1b[?25h\x1b[?1049l")
	end,
}
