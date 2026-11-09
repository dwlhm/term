# term CLI

`term` runs in three processes: the **holder** owns PTYs and child processes,
the **core** parses every session and serves clients over a unix socket
(`$TERM_SESSION_DIR`, default `/tmp/term-<uid>`), and **viewers** (the window,
the CLI) show or drive sessions. Sessions outlive the window.

The CLI documents itself, so this file only says where to look:

| What | Where |
|---|---|
| Commands | `term --help` |
| One session verb | `term session <verb> --help` |
| Lua Scripting (`term run`) | [`docs/SCRIPTING.md`](SCRIPTING.md) |
| Guide for AI agents | `term skill show` (installed by `term skill setup`) |
| The socket protocol (any program can use it) | [`docs/PROTOCOL.md`](PROTOCOL.md) |

Interacting with another session uses non-invasive reading and atomic sending:
- `term session read [id] --tail --prompt` waits reactively for command completion.
- `term session read [id] --last` retrieves clean command output.
- `term session send [id] "command" --key Enter` sends input directly to the PTY.
- `term split <right|down> [id]` and `term tab [id]` control GUI window layout.
- `term run <script.lua>` executes Effect-style Fiber automation scripts.

Every program in a session gets `TERM_SESSION_ID=<id>`; `observe` and `read`
default to it. Exit codes: 0 ok · 1 error · 2 no session core · 3 timed out ·
4 the session ended first · 5 rejected.
