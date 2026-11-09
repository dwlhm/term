# Programmable Automation with `term run`

`term run <script.lua> [args...]` provides a modern, programmable scripting runtime for orchestrating terminal sessions, long-running processes, and UI window layouts.

Its runtime is inspired by the **Effect mental model**:
- **Fibers**: Lightweight cooperative green threads (Lua coroutines) scheduled efficiently inside the term runtime.
- **Scope LIFO Resource Teardown**: Automatic guaranteed teardown of spawned background sessions, subprocesses, and open resources when a scope or script exits.
- **Structured Concurrency**: Cascading cancellation and combinators (`task.race`, `task.all`, `task.fork`, `task.join`) where child tasks never leak.
- **Capability-Gated Sandboxing**: Sandboxed Lua 5.4 VM with 64 MiB memory bounds and safe standard libraries (`string`, `table`, `math`, `utf8`, `coroutine`).

---

## Script Structure: `term.program`

Every script returns a program manifest constructed via `term.program` (or `term.script`):

```lua
local term = require "term"
local session = term.session
local task = term.task
local window = term.window
local io = term.io

return term.program {
    name = "dev-workflow",
    description = "Spin up backend server and test runner side-by-side",

    main = function(argv)
        io.print("Starting development environment...")

        -- 1. Spawn persistent background sessions with names
        local server = session.spawn {
            name = "api-server",
            command = "go run ./cmd/server",
            cwd = "~/project/api",
        }

        local client = session.spawn {
            name = "web-client",
            command = "npm run dev",
            cwd = "~/project/web",
        }

        -- 2. Wait reactively for server to become ready
        server:wait { text = "Server listening on :8080", timeout = 10 }
        io.print("Server is live!")

        -- 3. Arrange window layout
        window.split { direction = "right", session = client }

        -- 4. Monitor both concurrently
        task.race({
            function() server:wait { exit = true } end,
            function() client:wait { exit = true } end,
        })
    end,
}
```

---

## Core Modules

### 1. `term.session`

Orchestrates terminal sessions with persistent PTYs and OS command lifecycles:

- `session.spawn { name = "...", command = "...", cwd = "...", env = { ... } }`: Spawns a background session. Tracked in the script's scope and cleaned up on exit.
- `session.find(name_or_id)`: Look up an active session by name or numeric ID.
- `session.list()`: Returns an array of session tables (`id`, `name`, `state`, `pid`, `cwd`, `title`, `cmd_seq`, `has_cmd_exit`, `last_cmd_exit`).
- `session.me()`: Returns the `Session` object corresponding to `$TERM_SESSION_ID`.

#### `Session` Methods:
- `s:send(text, opts)`: Send atomic text, keys (`--key Enter`, `Ctrl-C`), or mouse clicks.
- `s:read(opts)`: Read terminal buffer text, last command output (`last = true`), or JSON UI elements (`elements = true`).
- `s:wait(opts)`: Wait reactively without polling:
  - `prompt = true`: Wait until shell returns to the command prompt.
  - `exit = true`: Wait until the session or command process exits.
  - `text = "pattern"`: Wait until text pattern appears on screen.
  - `timeout = seconds`: Maximum wait duration.
- `s:cancel(timeout)`: Send SIGINT and wait for the shell prompt.
- `s:signal(sig)`: Send UNIX signal (`"INT"`, `"TERM"`, `"KILL"`, or integer).
- `s:kill()`: Terminate process and teardown session immediately.
- `s:split(direction_or_opts)`: Split GUI window and attach this session (`"right"` or `"down"`).
- `s:attach()`: Show this session in a new window tab.

---

### 2. `term.task`

Structured concurrency and cooperative timing:

- `task.sleep(seconds)`: Non-blocking cooperative sleep yielding to the scheduler.
- `task.fork(fn)`: Spawn a child fiber linked to the caller's scope.
- `task.join(fiber)`: Await completion of a child fiber.
- `task.race({ fn1, fn2, ... })`: Run multiple tasks concurrently; first to complete wins, others are cleanly cancelled.
- `task.all({ fn1, fn2, ... })`: Run multiple tasks concurrently; awaits all to complete.

---

### 3. `term.window`

Control GUI terminal window layout and focus:

- `window.split { direction = "right"|"down", session = s }`: Split active pane horizontally or vertically.
- `window.tab({ session = s })`: Open a new tab (optionally displaying session `s`).
- `window.show()`: Bring the Term window to the foreground.
- `window.attach(session)`: Attach session into the running window.

---

### 4. `term.io`

Console I/O for scripts:

- `io.print(...)`: Print formatted message to standard output.
- `io.eprint(...)`: Print formatted message to standard error.
- `io.read_line()`: Read a line of input from standard input.
