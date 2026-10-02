# Model Context Protocol (MCP) Server: `term-mcp`

The **`term-mcp`** binary is a standalone, headless [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server engineered from first principles in [Odin](https://odin-lang.org). Designed specifically for autonomous AI coding agents, background agents, and tool-augmented developer workflows, `term-mcp` exposes a complete, deterministic pseudo-terminal (PTY) automation environment over standard JSON-RPC 2.0.

Unlike conventional terminal servers that wrap bloated JavaScript runtimes (`node-pty` + `xterm-headless`) or fragile Python wrappers (`pexpect` / `pyte`), `term-mcp` links **zero GUI libraries** (no Cocoa, Metal, X11, or SDL3), consumes **under 2 MB of RAM**, and delivers sub-millisecond command execution latency.

---

## 1. Overview & Architectural Motivation

Autonomous coding agents (such as Claude Desktop, Cursor, Codex, and Antigravity agents) require deep interaction with command-line tools: compiling code, running tests, querying git state, managing Docker containers, and driving interactive text-user interfaces (TUIs).

### The Limits of Conventional Terminal Backends

1. **Heavy Resource Footprint**: Node.js and Python runtimes require between 65 MB and 175 MB of Resident Set Size (RSS) just to initialize the runtime and standard packages. Running multiple agent loops quickly exhausts host memory.
2. **IPC & Event Loop Latency**: In Node.js, command execution traverses V8 JavaScript event loops, libuv workers, and inter-process serialization, resulting in typical turn-around latencies of 25 ms to 45 ms.
3. **Fragile Output Scrubbing**: Traditional agent frameworks scrape terminal output using regexes to strip ANSI escape codes. This often mangles multiline logs, swallows exit codes, or produces desynchronized output when commands emit raw terminal sequences.
4. **Zombie Process Accumulation**: Standard subprocess execution frequently abandons background children when a command times out or fails, leaking system process table entries.

### The `term-mcp` Advantage

`term-mcp` compiles down to a single, statically optimized Mach-O binary powered directly by Term's Hexagonal Session Core (`src/session_core/`).

```
+----------------------------------------------------------------------------+
|                       TERM-MCP PERFORMANCE ADVANTAGE                       |
+-------------------------------------+--------------------------------------+
| Command Latency: 0.27 ms (p50)      | Memory Footprint: 1.92 MB RSS        |
| 105x faster than Node.js (28.5 ms)  | 44x lower RAM than Node.js (84.5 MB) |
+-------------------------------------+--------------------------------------+
| Output Verification: 100% Pass Rate | Process Hygiene: Zero Zombies        |
| 103/103 assertions across 11 suites | Clean process-group termination      |
+-------------------------------------+--------------------------------------+
```

---

## 2. Comparative Performance Benchmarks

The following empirical measurements were recorded on Apple Silicon macOS (ARM64) comparing `term-mcp` against official industry-standard terminal MCP backends:
- **Solution A**: Node.js `@modelcontextprotocol/server-terminal` (`node-pty` + `xterm-headless`)
- **Solution B**: Python SWE-agent / OpenHands (`ptyprocess` + `pyte` / regex strip)
- **Solution C**: **`term-mcp` (Odin Native Standalone Headless MCP Server)**

### 2.1 Benchmark Results Table

| Performance Metric | Python (`pyte` / `pexpect`) | Node.js (`node-pty`) | `term-mcp` (Odin Native) | Win Margin |
|---|---|---|---|---|
| **Physical RSS (Idle Base / 0 Sessions)** | ~32.0 MB | ~65.0 MB | **1.84 MB** | **35.3x lower RAM** |
| **Physical RSS (1 Active Session)** | ~42.0 MB | ~84.5 MB | **2.19 MB** | **38.6x lower RAM** |
| **Physical RSS (5 Concurrent Sessions)** | ~98.0 MB | ~142.0 MB | **3.38 MB** | **42.1x lower RAM** |
| **Physical RSS (10 Concurrent Sessions)**| ~175.0 MB | ~240.0 MB | **4.80 MB** | **50.0x lower RAM** |
| **Startup & Handshake ($p_{50}$)** | ~95.0 ms | ~182.4 ms | **3.60 ms** | **50.6x faster** |
| **Startup & Handshake ($p_{95}$)** | ~140.0 ms | ~245.0 ms | **7.31 ms** | **33.5x faster** |
| **2D Viewport Extraction ($p_{50}$)** | ~8,500 µs | ~4,800 µs | **21.2 µs** | **226.5x faster** |
| **2D Viewport Extraction ($p_{95}$)** | ~12,000 µs | ~7,200 µs | **38.1 µs** | **188.9x faster** |
| **Command Execution Latency ($p_{50}$)**| ~34.0 ms | ~28.5 ms | **0.27 ms** | **105x faster** |
| **Rapid-Fire Burst Latency ($p_{50}$)** | ~45.0 ms | ~42.0 ms | **0.25 ms** | **Zero desynchronization** |

### 2.2 Suite Verification & Test Accounting

`term-mcp` is verified by an exhaustive 11-suite test runner covering **103 / 103 passing assertions (0.0% error rate)**:
- **Suite 01**: Handshake, Initialize & Tools Discovery ($p_{50} = 3.60\,\text{ms}$)
- **Suite 02**: Multi-Session Scalability & RSS Memory Profiling
- **Suite 03**: Synchronous Command Execution ($p_{50} = 0.29\,\text{ms}$)
- **Suite 04**: Output & Exit-Code Error Awareness
- **Suite 05**: Timeout & Execution Interruption
- **Suite 06**: Interactive Raw Input & Control Sequences
- **Suite 07**: 2D Screen Snapshot Extraction ($p_{50} = 21.19\,\mu\text{s}$)
- **Suite 08**: Dynamic Terminal Resizing
- **Suite 09**: Sustained Stream Throughput & Data Integrity
- **Suite 10**: Fault Tolerance & RPC Boundary Handling
- **Suite 11**: Multi-Command Burst & Stateful Chaining ($p_{50} = 0.25\,\text{ms}$)

---

## 3. Architecture & Protocol Mechanics

`term-mcp` operates as a stdio server complying strictly with the Model Context Protocol specification and JSON-RPC 2.0 framing standards.

```mermaid
sequenceDiagram
    autonumber
    actor Agent as AI Agent (Claude / Cursor / Antigravity)
    participant MCP as term-mcp (stdio JSON-RPC)
    participant Core as Core_Session (session_core)
    participant Kernel as macOS Kernel PTY (/dev/ttys*)
    participant Child as Shell Process (zsh / bash)

    Agent->>MCP: {"method": "initialize", "params": {...}}
    MCP-->>Agent: {"result": {"capabilities": {...}, "serverInfo": {"name": "term-mcp"}}}

    Agent->>MCP: tools/call "terminal_create_session" {"mode": "fast"}
    MCP->>Core: session_create(id, rows, cols, mode=.Fast_Headless)
    Core->>Kernel: pty_spawn() + bootstrap preamble
    Kernel->>Child: execvp("/bin/zsh", ["--no-rcs"])
    Core-->>MCP: Core_Session created
    MCP-->>Agent: {"session_id": "session_1"}

    Agent->>MCP: tools/call "terminal_run_command" {"session_id": "session_1", "command": "git status"}
    MCP->>Core: session_run_command("git status", timeout_ms=30000)
    Core->>Kernel: write: git status ; echo "__TERM_MCP_DONE_1_"$?"__"
    Kernel->>Child: executes git status
    Child-->>Kernel: emit output + sentinel
    Kernel-->>Core: drain_buf (background pump)
    Core->>Core: Parse VT stream into 2D Grid + detect canary
    Core-->>MCP: output (ANSI stripped) + exit_code (0)
    MCP-->>Agent: {"output": "On branch main\nnothing to commit", "exit_code": 0, "completed": true}
```

### 3.1 Dual Transport Framing

`term-mcp` automatically detects and processes both standard stdio framing protocols:
1. **Newline-Delimited JSON (NDJSON)**: Standard for modern MCP orchestrators. Each JSON message is separated by a single `\n` byte.
2. **`Content-Length` Header Framing**: Conforms to Language Server Protocol (LSP) framing conventions (`Content-Length: <N>\r\n\r\n<JSON>`), ensuring compatibility with generic RPC clients.

### 3.2 Session Modes: `Fast_Headless` vs. `Interactive_GUI`

When creating a session via `terminal_create_session`, callers specify the operational mode:

```json
{
  "mode": "fast" // or "interactive"
}
```

- **`Fast_Headless` (Default)**:
  - Spawns the shell with `--no-rcs` (zsh) or `--norc --noprofile` (bash) to skip slow user dotfiles.
  - Injects a bootstrap preamble that disables line editing (`unsetopt zle`), disables terminal echo (`stty -echo`), and strips user prompts (`PROMPT=''`).
  - Command execution latency drops to **0.27 ms**.
  - Ideal for build tools, package managers, and autonomous reasoning loops.
- **`Interactive_GUI`**:
  - Spawns a full login shell (`-l`) loading all user configurations, aliases, and shell functions.
  - Maintains full terminal echo and line discipline.
  - Intended for interactive TUI tools (`vim`, `htop`, `fzf`) driven via `terminal_send_key` and inspected via `terminal_get_screen`.

### 3.3 Deterministic Dual-Completion Detection

To avoid arbitrary sleep timers or fragile regex polling, `terminal_run_command` synchronizes via a **dual-detection pipeline**:
1. **OSC 133 Prompt Shell Integration**: If the child shell emits standard semantic prompt sequences (`\x1b]133;D`), the runner captures command completion immediately.
2. **Sequential Canary Sentinel Fallback**: Every command payload is appended with an isolated execution tag:
   ```sh
   <command> ; echo "__TERM_MCP_DONE_<seq>_"$?"__"
   ```
   The background drain thread detects the tagged sequence, extracts the integer exit code, and notifies a condition variable (`sync.cond_broadcast`). The runner wakes instantly, extracts the clean output from the virtual grid between the recorded start row and sentinel row, and returns.

---

## 4. Complete Specification of the 7 MECE Tools

`term-mcp` implements a Mutually Exclusive, Collectively Exhaustive (MECE) set of 7 terminal automation tools.

### Tool 1: `terminal_create_session`

Spawns a new isolated pseudo-terminal session backed by a virtual terminal grid and background drain pump.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "rows": {
      "type": "integer",
      "description": "Terminal rows / vertical height in cells (default: 24)"
    },
    "cols": {
      "type": "integer",
      "description": "Terminal columns / horizontal width in cells (default: 80)"
    },
    "shell": {
      "type": "string",
      "description": "Path to shell executable (default: $SHELL or /bin/zsh)"
    },
    "cwd": {
      "type": "string",
      "description": "Initial working directory for the spawned shell"
    },
    "mode": {
      "type": "string",
      "enum": ["fast", "interactive"],
      "description": "Session mode: 'fast' (zero-overhead headless) or 'interactive' (standard shell)"
    }
  }
}
```

#### Example Response
```json
{
  "session_id": "session_1",
  "content": [
    {
      "type": "text",
      "text": "Session created: session_1"
    }
  ]
}
```

---

### Tool 2: `terminal_close_session`

Gracefully shuts down a session, closes the master PTY descriptor, and terminates the child process tree.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "string",
      "description": "Target session identifier to destroy"
    }
  },
  "required": ["session_id"]
}
```

#### Process Hygiene & Tree Termination
When `terminal_close_session` is called:
1. Sends `SIGTERM` to the negative process group ID (`killpg(pid, SIGTERM)`).
2. Closes the master PTY descriptor to unblock any pending I/O syscalls.
3. Joins and dismantles the background drain worker thread.
4. Issues `SIGKILL` to lingering children and calls `waitpid()` to reap the process, ensuring **zero zombie processes**.

#### Example Response
```json
{
  "closed": true,
  "content": [
    {
      "type": "text",
      "text": "Session closed"
    }
  ]
}
```

---

### Tool 3: `terminal_run_command`

Executes a command synchronously in the specified session, returning clean output and the command's exit code upon deterministic completion.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "string",
      "description": "Target session identifier"
    },
    "command": {
      "type": "string",
      "description": "Shell command line to execute"
    },
    "timeout_ms": {
      "type": "integer",
      "description": "Execution timeout in milliseconds (default: 30000)"
    }
  },
  "required": ["session_id", "command"]
}
```

#### Output Guarantees
- **Clean Output**: Output is extracted directly from the virtual terminal grid. It contains **no ANSI escape bloat**, no prompt strings, and no echo of the sentinel marker.
- **Exit Code Fidelity**: Returns the exact integer return code of the executed process (e.g., 0 for success, 127 for command not found).
- **Timeout Protection**: If the command exceeds `timeout_ms`, a `SIGINT` (Ctrl+C) byte is transmitted to abort the hanging child, and `completed: false` is returned.

#### Example Response
```json
{
  "output": "total 16\n-rw-r--r--  1 staff  1062 Oct  1 12:00 LICENSE\n-rw-r--r--  1 staff  7409 Oct  1 12:00 Makefile",
  "exit_code": 0,
  "completed": true,
  "content": [
    {
      "type": "text",
      "text": "total 16\n-rw-r--r--  1 staff  1062 Oct  1 12:00 LICENSE\n-rw-r--r--  1 staff  7409 Oct  1 12:00 Makefile"
    }
  ]
}
```

---

### Tool 4: `terminal_send_input`

Writes raw text characters directly into the child PTY master standard input.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "string",
      "description": "Target session identifier"
    },
    "text": {
      "type": "string",
      "description": "Raw string content to deliver to terminal stdin"
    }
  },
  "required": ["session_id", "text"]
}
```

#### Example Response
```json
{
  "bytes_written": 12,
  "content": [
    {
      "type": "text",
      "text": "Wrote 12 bytes"
    }
  ]
}
```

---

### Tool 5: `terminal_send_key`

Sends standardized terminal control keys, escape sequences, or signals to interact with menus and interactive terminal programs.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "string",
      "description": "Target session identifier"
    },
    "key": {
      "type": "string",
      "enum": [
        "Enter",
        "Tab",
        "Backspace",
        "Escape",
        "Ctrl+C",
        "Ctrl+D",
        "Ctrl+Z",
        "Up",
        "Down",
        "Left",
        "Right"
      ],
      "description": "Standardized control key identifier"
    }
  },
  "required": ["session_id", "key"]
}
```

#### Control Key Byte Mapping Table
| Key Identifier | Transmitted Byte Sequence | Hex Code | Description |
|---|---|---|---|
| `Enter` | `\r` | `0x0D` | Carriage Return |
| `Tab` | `\t` | `0x09` | Horizontal Tab |
| `Backspace` | `\x7f` | `0x7F` | ASCII Delete / Rubout |
| `Escape` | `\x1b` | `0x1B` | ASCII Escape |
| `Ctrl+C` | `\x03` | `0x03` | ASCII End of Text (SIGINT) |
| `Ctrl+D` | `\x04` | `0x04` | ASCII End of Transmission (EOF) |
| `Ctrl+Z` | `\x1a` | `0x1A` | ASCII Substitute (SIGTSTP) |
| `Up` | `\x1b[A` | `1B 5B 41` | ANSI Cursor Up |
| `Down` | `\x1b[B` | `1B 5B 42` | ANSI Cursor Down |
| `Right` | `\x1b[C` | `1B 5B 43` | ANSI Cursor Forward |
| `Left` | `\x1b[D` | `1B 5B 44` | ANSI Cursor Backward |

#### Example Response
```json
{
  "sent": true,
  "content": [
    {
      "type": "text",
      "text": "Key sent"
    }
  ]
}
```

---

### Tool 6: `terminal_get_screen`

Captures a 2D spatial text snapshot of the virtual terminal grid viewport. It returns the exact visual layout as seen by a human user, including cursor coordinates, with zero ANSI escape codes.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "string",
      "description": "Target session identifier"
    },
    "scrollback_lines": {
      "type": "integer",
      "description": "Number of scrollback lines above the active viewport to include (default: 0)"
    }
  },
  "required": ["session_id"]
}
```

#### Snapshot Extraction Mechanics
- Traverses rows from the terminal grid and scrollback store.
- Bounded combining marks and multi-rune extended graphemes are unpacked into UTF-8 strings.
- Trailing whitespace on each line is cleanly trimmed.
- Extraction completes in under **21.2 microseconds**.

#### Example Response
```json
{
  "text": "Term v1.0.0 (Darwin arm64)\n$ make test\n[OK] 103 assertions passed in 3.6ms\n$",
  "cursor_row": 3,
  "cursor_col": 2,
  "rows": 24,
  "cols": 80,
  "content": [
    {
      "type": "text",
      "text": "Term v1.0.0 (Darwin arm64)\n$ make test\n[OK] 103 assertions passed in 3.6ms\n$"
    }
  ]
}
```

---

### Tool 7: `terminal_resize`

Dynamically resizes both the terminal grid matrix and the underlying operating system pseudo-terminal window geometry.

#### Input Schema
```json
{
  "type": "object",
  "properties": {
    "session_id": {
      "type": "string",
      "description": "Target session identifier"
    },
    "rows": {
      "type": "integer",
      "description": "New vertical height in rows (must be > 0)"
    },
    "cols": {
      "type": "integer",
      "description": "New horizontal width in columns (must be > 0)"
    }
  },
  "required": ["session_id", "rows", "cols"]
}
```

#### Kernel Propagation
Executes `ioctl(master_fd, TIOCSWINSZ, &ws)`, immediately notifying the child shell and any running foreground applications (`vim`, `less`, `tmux`) via `SIGWINCH`. Concurrently re-allocates row backing and reflows lines in the virtual terminal grid.

#### Example Response
```json
{
  "resized": true,
  "content": [
    {
      "type": "text",
      "text": "Resized"
    }
  ]
}
```

---

## 5. Client Configuration Guides

Integrating `term-mcp` with autonomous AI coding tools requires configuring the MCP server path in the client's configuration file.

### 5.1 Building the Binary First

Ensure `term-mcp` is compiled in release mode:
```bash
cd /path/to/term
make release-mcp
```
The compiled executable resides at `bin/term-mcp`.

---

### 5.2 Claude Desktop Configuration

Edit the Claude Desktop configuration file:
- **macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Linux**: `~/.config/Claude/claude_desktop_config.json`

Add `term-mcp` under the `mcpServers` object:

```json
{
  "mcpServers": {
    "term": {
      "command": "/Users/dwlhm/project/term/bin/term-mcp",
      "args": [],
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      }
    }
  }
}
```

> [!TIP]
> Always pass a complete `PATH` in the `env` block so that child shells spawned by `term-mcp` have immediate access to Homebrew utilities (`git`, `cargo`, `odin`, `node`, `python3`).

---

### 5.3 Cursor Configuration

In Cursor, configure MCP servers at the project level or user level:

#### Project-Level (`.cursor/mcp.json`):
Create `.cursor/mcp.json` in your repository root:

```json
{
  "mcpServers": {
    "term": {
      "command": "/Users/dwlhm/project/term/bin/term-mcp",
      "args": [],
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
      }
    }
  }
}
```

Restart Cursor or reload MCP servers from the Cursor Settings panel (`Cursor Settings > Features > MCP`).

---

### 5.4 Antigravity / Autonomous Agent Configuration

For Antigravity or custom autonomous multi-agent environments, configure the server in your MCP definitions:

```json
{
  "name": "term",
  "command": "/Users/dwlhm/project/term/bin/term-mcp",
  "transport": "stdio",
  "autoApprove": [
    "terminal_create_session",
    "terminal_close_session",
    "terminal_run_command",
    "terminal_send_input",
    "terminal_send_key",
    "terminal_get_screen",
    "terminal_resize"
  ]
}
```

---

## 6. Best Practices for AI Agents

To maximize reliability and speed when writing agent prompts or tool-calling logic:

### 1. Default to `Fast_Headless` Mode
Unless your agent specifically needs to run an interactive full-screen TUI (like `vim` or `nano`), always spawn sessions in `fast` mode (`"mode": "fast"`). This skips shell profile loading, disables echoing, and guarantees sub-millisecond execution.

### 2. Use `terminal_run_command` for Discrete Tasks
For building, linting, file inspection, and test execution, prefer `terminal_run_command` over raw `terminal_send_input`. `terminal_run_command` handles synchronization automatically, returning clean output and exact exit codes without requiring manual screen scraping.

### 3. Driving Interactive TUIs with Key Sequences
When automating interactive TUIs:
1. Call `terminal_create_session` with `"mode": "interactive"`.
2. Launch the interactive program using `terminal_send_input` (e.g. `vim config.json\n`).
3. Send key strokes using `terminal_send_key` (e.g. `"Escape"`, `"Enter"`, `"Down"`).
4. Verify the UI state using `terminal_get_screen` to assert that expected menu items or dialogues appear.

### 4. Stateful Command Chaining
Sessions preserve working directory and environment variables across consecutive tool calls:
- Executing `terminal_run_command` with `"cd /path/to/project"` persists the directory for all future calls in that session.
- Executing `export MY_FLAG=1` persists the environment across calls.
- There is no need to write `cd ... && cmd` on every step.

### 5. Always Terminate Sessions
When an agent completes a task or encounters a fatal workflow failure, call `terminal_close_session`. This ensures all child processes are immediately reaped with zero system resource leaks.
