# term auto: automating programs in term sessions

`term auto` drives programs that run in term sessions (shells, CLIs, full-screen
TUIs, agent TUIs) the way a headless browser drives pages. It works on live
sessions, including ones a person is using in a window. Every automation is a
**contract**: a Lua file of pure functions that return **steps**. The runner
carries the steps out, waits for screens, and handles the person at the
keyboard.

```lua
-- commit.lua
local t  = require "term"
local lg = require "term.adapter.lazygit"
return t.contract {
  adapter = lg,
  commit = function(msg)
    return { lg.steps.stage_all(), t.press("c"), t.type(msg), t.press("Enter"), t.expect(msg) }
  end,
}
```

```bash
term auto run commit.lua commit --msg "fix: typo"   # finds the lazygit session by itself
```

## Commands

| Command | What it does |
|---|---|
| `term auto run [--session id] [--trace f] <contract> <function> [params…]` | Run one function. Params are positional or `--name value`; missing ones are asked for. |
| `term auto serve [--session id] [--trace f] <contract>` | Answer requests sent to a session's program with the contract's `serve` function. |
| `term auto reply <id> <answer>` | Answer a running contract's question (`t.ask`, a missing param, the end of a handoff). |
| `term auto check <contract>` | Validate a contract without running anything. |
| `term auto snapshot <id> [-n lines] [--json] [--save f] [--adapter name]` | The parsed screen and its elements, for writing contracts. |
| `term auto adapters` | The adapters a contract can require. |

Without `--session`, a contract with an adapter drives the one live session its
`detect` accepts; with two candidates it asks for `--session` instead of
guessing. With `--session`, the adapter's `detect` must accept that session.

## Contracts

A contract file returns `t.contract{…}`. Every key that is not reserved is a
function: it takes params and **returns steps**; it never touches a session.
Reserved keys:

| Key | Meaning |
|---|---|
| `api` | `1` (the default). |
| `adapter` | An adapter (`require "term.adapter.<name>"`). |
| `params` | `{ fn = { name = "string" \| "number" \| "boolean" } }`; params are strings otherwise. |
| `timeouts` | Seconds: `expect` (10), `settle` (quiet time after output, 0.05), `run` (600). |
| `on` | `human = fn(input) → "hold" \| "cancel"`, `interrupt = { {target, steps}, … }`, `finally = steps \| fn`, `release = "discard" \| "flush"`. |
| `serve` | `fn(text, {id, from}) → steps`, for `term auto serve`. |

Defaults, so a contract only says what is particular to it:

- Every action waits for its target first, and gives the screen up to a second
  to settle after it.
  Waits look at a new snapshot each time the screen changes; nothing sleeps.
- The session is leased for the run: other drivers, `send`, broker requests
  and scrolling reads are refused. What a person types is held, not delivered.
  Esc or ^C from a person cancels the run; other held input is dropped at the
  end (`on.release = "flush"` delivers it).
- `on.finally` runs at the end while the session is still held, also after a
  failure.
- A known interruption (`on.interrupt`, then `adapter.interrupts`) that shows
  while waiting runs its steps, once per wait.
- When an expected screen does not come, the run fails with the step, what was
  expected, the screen and its elements (`--trace` writes NDJSON too).
- A program that exits after the last step is fine; one that exits while a step
  still needs it fails the run.

## Steps

| Step | Does |
|---|---|
| `t.press(key…)` | Key taps. Names: `Enter`, `Escape`, `Tab`, `Backspace`, `ArrowUp`, `F5`, `Space`, `a`, with `Ctrl+`, `Alt+`, `Shift+`, `Super+`. |
| `t.type(text)` | Text as key taps (`\n` is Enter). Use it for commands: vim inserts a *pasted* `:wq`. |
| `t.paste(text)` | One bracketed paste when the program enabled it, typed otherwise. |
| `t.click(target, {button})` / `t.scroll(target, n)` | At the middle of the target; fails `Unsupported` when the program does not report the mouse. |
| `t.expect(target, {timeout})` / `t.gone(target, {timeout})` | Wait until it shows / is gone. |
| `t.read(target, fn(value) → steps)` | Continue with an element's text (or name), or what a predicate returned. |
| `t.choose{ {target, steps}, …, default = steps }` | The first case on screen runs; the default when none is; else it waits. |
| `t.retry(steps, {times, until})` | Repeat steps that met an unexpected screen. |
| `t.call(name, …)` | Another function of the contract. |
| `t.ask({prompt, type, choices}, fn(answer) → steps)` | Ask whoever runs it (see below). |
| `t.handoff{reason, until}` | Let a person type in the program until `until` shows or they reply. |
| `t.done(value)` / `t.fail(msg)` | End: `done` prints the value (tables as JSON). |

Steps may be nested lists; each is checked before it runs.

### Targets

- `"text"`: text anywhere on the screen.
- `"@e3"`: a ref from `term auto snapshot`, for trying things out. It lasts one
  screen only.
- A locator: `{role, name, text, match (Lua pattern), selected, focused,
  checked, source, inside = locator, nth}`.
- A predicate: `function(screen) … end` that returns true or a value.

## Screens and elements

A screen is the program's screen, parsed by term (never raw PTY bytes). It is
read-only: `cols`, `rows`, `gen`, `cursor{row, col, visible}`, `alt`, `title`,
`process`, `prompt` (OSC 133 state), `status{state, app, kind, msg}`
(OSC 7501). Its methods are `line(n)`, `lines()`, `history()`, `cell(row, col)`
(raw attributes: `char`, `fg`, `bg`, `rgb_fg`, `bold`, `inverse`, `link`, …),
and `elements()`. Rows and columns are 1-based.

Each element has `{ref, role, name, text, row, col, width, height, parent,
selected, focused, checked, source}`. There are three sources:

1. **marked**: what the program says itself. OSC 133 gives the prompt rows,
   the line being typed and the last command's output; OSC 8 gives links.
   Inference never overrides these.
2. **inferred**: generic rules for how terminal UIs draw:
   - panels with box-drawing borders, including ones a dialog covers;
   - dialogs, and column panes;
   - `[x]` and `( )` toggles, `[___]` fields;
   - `<OK>` / `[ OK ]` buttons (not key hints like `<enter>`), and padded
     "pill" buttons;
   - the selected list item (a lit row, or a pointer like `>`/`❯`) and its
     siblings;
   - status bars, scrollbars, and the input at the cursor.
3. **adapter**: what an adapter adds or refines for its program.

## Adapters

```lua
return t.adapter {
  name = "lazygit",
  detect = function(s) return s.process == "lazygit" end,   -- whose screen is it
  elements = function(s, base) … return list end,            -- refine the elements
  state = { files = { role = "panel", match = "Files" } },   -- named targets
  interrupts = { { "Thanks for using lazygit!", t.press("Enter") } },
  steps = { stage_all = function() return t.press("a") end }, -- reusable steps
  cancel = function() return t.press("Escape") end,          -- stop it (serve)
}
```

`require "term.adapter.<name>"` looks in `./.term/adapters/<name>.lua`, then
`~/.config/term/adapters/<name>.lua` (or `$XDG_CONFIG_HOME/term/adapters`), then
among the bundled adapters: `lazygit`, `fzf`, `agent`, `claude_code`, `opencode`, `agy`.
A file replaces a bundled adapter of the same name.

Test an adapter on saved screens with plain asserts:

```bash
term auto snapshot 3 --save lazygit.json
```
```lua
local s = require("term.screen").load("lazygit.json")
assert(lg.detect(s))
```

## Serving agent TUIs

`term auto serve` turns an agent TUI into a broker taker, so
`term session tell <id> '<task>'` gets its answer back. The runner waits in
`next` **as the agent's session**. Each request is:

1. refused while the agent reports `working` or `blocked`;
2. otherwise the session is leased, and `serve(text, req)` pastes the task
   with the instruction to run `term session answer <req.id> '<answer>'`;
3. ended when the agent answers. If its turn ends without an answer, the
   request fails. If the sender cancels it, the adapter's `cancel` presses
   Esc. A permission prompt mid-turn is handed to a person.

```lua
local cc = require "term.adapter.claude_code"   -- or term.adapter.opencode, term.adapter.agy
return t.contract { adapter = cc, serve = function(text, req) return cc.steps.serve(text, req) end }
```

Agent TUIs report their state with OSC 7501. Claude Code only does so once the
terminal answers its `OSC 7501 ; ?` probe; term answers it. `term skill setup`
also lets Claude Code and OpenCode run `term session answer|progress` without
asking. It merges exactly those rules into `~/.claude/settings.json` and
`~/.config/opencode/opencode.json`, keeps a `.term-backup` of each, and
never rewrites a config with comments. `term skill remove` takes the rules out
again.

## Questions and handoffs

`t.ask`, a missing param and `t.handoff` print one JSON line on stdout:

```json
{"ask":"who?","type":"string","choices":["ada","bob"],"reply":"term auto reply 7 <answer>"}
```

Answer with `term auto reply <id> <answer>`, or type the answer when the runner
runs on a terminal. An invalid answer is refused and asked again. A handoff
passes a person's input through to the program until its `until` target shows
or `term auto reply <id> done`. Its input never reaches the trace.

## In the window

A pane an automation holds shows who drives it. After a person types there, it
shows that the input is held. During a handoff it shows that the automation
waits for them. **⇧⌘.** (or "Take Over from Automation" in the Command Center)
asks to take the session back: the automation stops with `Interrupted`. It
targets the focused pane, else the held pane of the active tab.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | the contract is invalid or its Lua failed |
| 2 | no term session core runs |
| 3 | the run, an ask or a handoff ran out of time |
| 4 | the program ended while a step still needed it |
| 5 | the session is held by another automation, or busy |
| 6 | an expected screen did not come, the input was unsupported, or `t.fail` |
| 7 | a person took the session back, pressed Esc/^C, or the runner got SIGINT |

## Sandbox

Contracts and adapters run in Lua 5.4 with these libraries only: `string`
(no `dump`), `table`, `math` (no `random`), `utf8` and the base library
(no `load`, `loadfile`, `dofile`, `print`). Only text chunks load, never
bytecode. Memory is capped at 64 MiB, and each call into Lua has 100 ms.
`require` reaches only the `term` modules and adapters.

The wire behind it (`SNAPSHOT`, `SETTLE`, `ACT`, `LEASE`) is in
[PROTOCOL.md](PROTOCOL.md).
