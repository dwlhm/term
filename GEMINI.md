# Agent Steering Guidelines: `term-mcp`

This guide instructs AI coding agents on maximizing speed, reliability, and token efficiency when interacting with the `term-mcp` terminal tool suite.

---

## 1. Default Session Persistence & Smart Auto-Routing

- **Omit `session_id` by default**: When calling `terminal_run_command`, omit `session_id` or pass `"auto"`. The server automatically routes commands to the persistent default session.
- **Stateful Environment**: Shell variables, exports (`export PATH=...`), and directory changes (`cd ...`) persist across command calls in the same session.
- **Autonomous Fallback**: If the active session is currently busy (e.g. running a long-lived dev server or watcher), `term-mcp` automatically provisions an auxiliary session inheriting the exact working directory (`cwd`) of the active session.

---

## 2. High-Throughput Concurrent Execution (`terminal_run_parallel`)

- **When to use**: Whenever you need to run multiple independent tasks simultaneously, use `terminal_run_parallel` instead of sequential `terminal_run_command` calls.
  - Typical use cases: running tests while running a linter, checking multiple git submodules, parallel package installation, or multi-directory builds.
- **Worker Isolation**: Each command in `terminal_run_parallel` executes concurrently in its own isolated headless PTY worker session with deterministic exit codes and clean output capture.
- **Automatic Cleanup**: Worker sessions are dismantled immediately upon task completion to prevent resource leakage.

---

## 3. Zero-Re-execution Buffer Queries (`terminal_get_output`)

- **Token Saver Truncation**: When command output exceeds 250 lines, `terminal_run_command` automatically compresses repeated logs and returns head/tail slices with `"truncated": true`.
- **Never Re-run to Read Logs**: When `truncated: true` is returned, **DO NOT** re-execute the command with pipes or pagers.
- **Direct Memory Queries**: Call `terminal_get_output` using the `command_id` (or leave empty for the latest command) with:
  - `grep`: Case-insensitive substring filtering directly against the complete raw output in memory.
  - `offset` and `limit`: Slice specific line ranges (pagination) without spawning child processes.

---

## 4. Session Control: Manual vs. Automatic

- **Default (Automatic)**: Let `term-mcp` manage session lifecycles without specifying session IDs.
- **Explicit / Manual Control**:
  - `terminal_list_sessions`: View all active sessions, including busy/idle status, active commands, and working directories.
  - `terminal_switch_session`: Designate which background session should receive subsequent default commands.
  - `terminal_create_session`: Spawn a dedicated isolated session (e.g., for persistent background daemons).
  - `terminal_close_session`: Terminate an active session and cleanly reap child process groups.
- **History Inspection**:
  - `terminal_list_commands`: Inspect previously executed commands, exit codes, durations, and summaries within a session.
