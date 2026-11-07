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
| Guide for AI agents | `term skill show` (installed by `term skill setup`) |
| The socket protocol (any program can use it) | [`docs/PROTOCOL.md`](PROTOCOL.md) |

Work in another session goes through requests: `run` types a command at a
shell prompt and returns its output, `tell` asks whatever waits in `next`
(an agent, a script, an app behind a `new --endpoint` session) and returns its
`answer`. One request, one result, no queue.

Every program in a session gets `TERM_SESSION_ID=<id>`; `observe` and `read`
default to it, and requests are sent and taken as it. Exit codes: 0 ok ·
1 error · 2 no session core · 3 timed out · 4 the session ended first ·
5 rejected.
