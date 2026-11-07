package term

// The agent skill `term skill setup` installs. Single source: AGENTS.md and
// docs point here (`term skill show`); verb flags live in cli_help.odin.

TERM_SKILL_NAME: string : "term"

TERM_SKILL_CONTENT: string : `---
name: term
description: >-
  Drive sessions of the term terminal emulator with its ` + "`" + `term session` + "`" + ` CLI. Use when the
  shell runs inside term ($TERM_PROGRAM is "term" or $TERM_SESSION_ID is set) or the user
  mentions "term session": run a command in another shell and get its output, ask another
  agent or program in a session and get its answer, take requests as a worker, start
  background sessions, look at a session's screen, drive a TUI (lazygit, vim, fzf, an agent
  TUI) with a contract (` + "`" + `term auto` + "`" + `).
  This is NOT Luvus: never use the luvus CLI/skill for term sessions.
---

# term sessions

Every shell in a term window or started with ` + "`" + `term session new` + "`" + ` is a session with a numeric id;
programs in it get ` + "`" + `TERM_SESSION_ID=<id>` + "`" + ` (` + "`" + `term session whoami` + "`" + `). Sessions keep running when the
window closes. ` + "`" + `term session new --endpoint <name>` + "`" + ` makes a virtual session (no program) that an
app outside term answers for.

## Rules
- Work in another session goes through a **request**: one request, exactly one result.
  ` + "`" + `run <id> '<cmd>'` + "`" + ` for a shell (its output and ` + "`" + `[exit N]` + "`" + `), ` + "`" + `tell <id> '<text>'` + "`" + ` for whatever
  waits there in ` + "`" + `next` + "`" + ` (an agent, a script, an app).
- No queue: a target that cannot take it now rejects at once (exit 5). Pick another, or wait
  until it can: ` + "`" + `wait <id> --listening` + "`" + `.
- Block on the event instead of polling: ` + "`" + `run` + "`" + `, ` + "`" + `tell` + "`" + `, ` + "`" + `result --wait` + "`" + `, ` + "`" + `next` + "`" + `, ` + "`" + `wait` + "`" + `, ` + "`" + `watch` + "`" + `.
  Never loop ` + "`" + `sleep` + "`" + ` + ` + "`" + `observe` + "`" + `. For long waits run the command in the background: your
  harness wakes you when it exits.
- A request you send while working on one you took is its child: it ends when yours ends.
- ` + "`" + `send` + "`" + ` types raw keys (REPLs, TUIs, ^C as ` + "`" + `\x03` + "`" + `). Typing into a shell that runs a request
  ends that request, as if a person did it.
- Exit codes: 0 ok · 1 error · 2 no term running · 3 timed out · 4 the session ended first ·
  5 rejected.

## Commands
| Goal | Command |
|---|---|
| Who am I · list sessions | ` + "`" + `term session whoami` + "`" + ` · ` + "`" + `term session ls [--json]` + "`" + ` |
| Start a session (prints id) | ` + "`" + `term session new [-d dir] [-- prog args…]` + "`" + ` · ` + "`" + `new --endpoint <name>` + "`" + ` |
| Run a shell command, get output | ` + "`" + `term session run <id> '<cmd>' [-t sec] [-n lines] [--json]` + "`" + ` |
| Ask a session, wait for the answer | ` + "`" + `term session tell <id> '<text>' [-t sec]` + "`" + ` (` + "`" + `-` + "`" + ` reads stdin) |
| Ask, go on, collect later | ` + "`" + `tell … --async` + "`" + ` → id; ` + "`" + `term session result <id>… --wait [-t sec]` + "`" + ` |
| Read a result or progress now | ` + "`" + `term session result <id> [--follow]` + "`" + ` · ` + "`" + `term session cancel <id>` + "`" + ` |
| Take the next request (worker) | ` + "`" + `term session next [-t sec] [--as <id>]` + "`" + ` → ` + "`" + `#<id> from <session>` + "`" + ` + text |
| Report on a request you took | ` + "`" + `term session progress <id> '<text>'` + "`" + ` · ` + "`" + `term session answer <id> '<text>' [--failed]` + "`" + ` |
| Wait until a worker listens | ` + "`" + `term session wait <id> --listening [--quiet sec] [-t sec]` + "`" + ` |
| Look at a screen | ` + "`" + `term session observe [id] [-n lines] [--json]` + "`" + ` · ` + "`" + `term session read [id] [-n lines]` + "`" + ` |
| Wait for prompt / exit / text | ` + "`" + `term session watch <id> [--prompt\|--exit]` + "`" + ` · ` + "`" + `term session wait <id> [--exit\|--text s]` + "`" + ` |
| Keys · signal · end | ` + "`" + `term session send <id> '<keys>'` + "`" + ` · ` + "`" + `signal <id> INT` + "`" + ` · ` + "`" + `kill <id>` + "`" + ` |

` + "`" + `ls` + "`" + ` shows REQUEST per session: ` + "`" + `serves #7` + "`" + `, ` + "`" + `awaits 2` + "`" + `, ` + "`" + `listens 1` + "`" + ` (free worker slots).

## Recipes
` + "`" + `` + "`" + `` + "`" + `bash
# Tests in a background shell
SH=$(term session new -d ~/project)
term session run "$SH" 'make test' -t 900 -n 40

# Be a worker: take one request, do it, answer, take the next (run ` + "`" + `next` + "`" + ` in the background)
term session next                     # → "#7 from 1" and the request text
term session progress 7 'tests running'
term session answer 7 - <<'EOF'
done: 3 files changed, tests pass
EOF

# Orchestrate: start workers, wait until they listen, fan out, collect
W=$(term session new -d ~/project -- claude "You are a term worker. Read: term skill show")
term session wait "$W" --listening --quiet 120
A=$(term session tell "$W" 'implement X in src/a' --async)
B=$(term session tell "$SH" 'make lint' --async)
term session result "$A" "$B" --wait -t 1800   # the first one that ends; then wait for the other

# Other agent CLIs as helpers: a one-shot run in their own shell session; its output is
# the result. Brief in a file, quoted so the helper's shell expands it; -c continues it.
# Long reports: have the brief say "write the report to <file>" (results keep 64 KiB).
H=$(term session new -d "$PWD")
C=$(term session tell "$H" 'opencode run "$(cat .term-tasks/a.md)"' --async)
#   agy: 'agy -p "$(cat .term-tasks/b.md)"' (-p takes the prompt: put other flags before it)
#   Only if a helper stops on a permission, rerun it with opencode --auto / agy --dangerously-skip-permissions.
term session result "$C" --wait -t 1800        # then verify its work yourself

# An app outside term takes requests for an endpoint
EP=$(term session new --endpoint indexer)
term session next --as "$EP"
` + "`" + `` + "`" + `` + "`" + `
The socket protocol behind these verbs is in docs/PROTOCOL.md: any program can speak it directly.

## Driving TUIs: term auto
For a full-screen program (lazygit, vim, fzf, dialog, an agent TUI) write a contract instead of
sending raw keys: steps wait for screens, encode keys for the program's modes, and stop when a
person takes over. Look first, then write steps against what you saw:
` + "`" + `` + "`" + `` + "`" + `bash
term auto snapshot <id>                      # screen + elements: @e1 Button "OK" [21,37 8x1] focused
term auto adapters                           # lazygit, fzf, claude_code, opencode, …
term auto check flow.lua && term auto run --session <id> flow.lua save --name notes.txt  # runner options first
` + "`" + `` + "`" + `` + "`" + `
` + "`" + `` + "`" + `` + "`" + `lua
local t = require "term"
return t.contract {
  save = function(name)   -- pure: params → steps
    return { t.expect("~"), t.press("i"), t.type("hello\n"), t.press("Escape"), t.type(":w " .. name .. "\n"), t.expect("written") }
  end,
}
` + "`" + `` + "`" + `` + "`" + `
Steps: press(keys) · type(text) · paste(text) · click(target) · scroll(target, n) · expect/gone(target) ·
read(target, fn) · choose · retry · call · ask · handoff · done(value) · fail(msg). A target is screen text,
a locator {role=, name=, match=, selected=, …}, or fn(screen). Exit 0 ok · 6 the screen did not come (the
error shows the step, the screen and its elements) · 7 a person took it back. Asks print a JSON line with
the reply command (` + "`" + `term auto reply <id> <answer>` + "`" + `). Reference: docs/AUTOMATION.md.

When ` + "`" + `term auto serve` + "`" + ` hands you a request, do it, then run (not just write) the command it names:
` + "`" + `term session answer <id> '<your answer>'` + "`" + `.
`
