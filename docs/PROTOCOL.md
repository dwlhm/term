# term session protocol

Every `term session` verb is a thin client of one unix socket. Any program can
speak it directly, without spawning the CLI: an app that answers requests for
an endpoint, a forked tool that asks a session for something, a daemon.

## Connecting

| | |
|---|---|
| Socket | `$TERM_SESSION_DIR/core.sock`, default `$TMPDIR/term-<uid>/core.sock` (`/tmp` when `TMPDIR` is unset) |
| Who may connect | the same uid only (the core checks the peer) |
| Your own session | `$TERM_SESSION_ID` (set in every program a session runs) |

The core runs while a window or a session exists. `term session ls` (or
`term session new …`) starts it when nothing runs.

## Framing and encoding

Wire version **0.1.0** (the session link; the core ↔ holder link stays 0.0.2).
A frame is `[kind u8][channel u32][length u32][payload]`, 9-byte header, at
most 1 MiB of payload. Requests and answers use channel 0. Every integer is
little-endian. `bool` is one byte (0 or 1). `str` is a `u32` byte length
followed by UTF-8 bytes, without a terminator. Enums are `u8`.

**Every channel 0 frame after HELLO starts with `u32 req`**, in both
directions. You pick a new non-zero `req` per request; every answer to it
carries the same `req`, so answers never mix, whatever else is in flight on
the connection. `req` 0 is a notice (`EVENT`, `REMOVED`, `LEASE_EVENT`). The
payloads below are what follows `req`.

### Handshake

Send `HELLO` (10), and read the core's `HELLO` before anything else. HELLO has
no `req`:

| field | type | value |
|---|---|---|
| version | u32 | `0x000100` (major<<16 · minor<<8 · patch = 0.1.0) |
| role | u8 | 4 (a client: `Cli`) |
| caps | u64 | 0 |
| build | str | anything (informational) |

Before 1.0 major and minor must match the core's; patch may differ. A refusal
is the core's `HELLO`, then `FAIL` with `req` 0, then the core closes: code 6
(`Version`, the reason names both versions), 5 (`Busy`: every connection slot
is taken) or 3 (a role that may not connect). A connection that sends no
HELLO within 2 s is closed.

### Answers you may get to any request

| kind | payload (after `u32 req`) |
|---|---|
| `OK` (85) | empty, unless the request says otherwise |
| `FAIL` (84) | u8 code · str reason |
| `EVENT` (83), `req` 0 | a session row that changed (sent to every client: skip it, or follow rows) |

Each request gets exactly one final answer: its answer kind or `FAIL`. Some
get progress answers before it (`TELL`, `RESULT`). The core answers by itself
a request with `req` 0, a `req` still open, an unknown kind or a body that does
not decode (`FAIL` 3), and the 33rd request open at once (`FAIL` 5).

FAIL codes: 1 Not_Found · 2 Exited (a request ended) · 3 Bad_Request ·
4 Spawn_Failed · 5 Busy · 7 Timeout · 8 Unsupported (the program did not
ask for that input: mouse reports, a key it has no encoding for). 6 is the
handshake's alone.

## Requests (the broker)

A request asks a session to process some text and ends with exactly one
result. It is taken by a worker of that session waiting in `NEXT`, or by the
session's shell adapter (a shell at its OSC 133 prompt: the text is typed as a
command, and its output and exit status are the result). There is no queue: a
target that cannot take it rejects it at once.

| kind | request payload | answer |
|---|---|---|
| `TELL` (74) | u32 to · u32 from · u32 timeout_ms · u64 parent · bool wait · bool shell · str body | `TELL_RESULT` Accepted or Rejected; with `wait`: `TELL_PROGRESS` Accepted, Progress…, then `TELL_RESULT` Finished (or Rejected) |
| `CANCEL` (75) | u64 request | `OK` / `FAIL` 1 |
| `NEXT` (76) | u32 session · u32 timeout_ms (0 = no limit) | `REQUEST` when one comes / `FAIL` 7 |
| `ANSWER` (79) | u32 by · u64 request · bool failed · str text | `OK` / `FAIL` 1, 2 or 3 |
| `PROGRESS` (100) | same as `ANSWER` (failed ignored) | `OK` / `FAIL` |
| `RESULT` (101) | u32 caller · bool wait · bool follow · u32 timeout_ms · u32 n · n × u64 request (n = 1..8) | `TELL_RESULT` Running or Finished (follow: `TELL_PROGRESS` Progress… first) / `FAIL` 1 or 7 |
| `ENDPOINT` (102) | str name (1..64 bytes) · bool owned | `OK` + u32 session id |

The fields:
- **`from`** is the sender's own session, or 0 from outside term.
- **`parent`** names the request the sender is working on that this one
  serves. 0 means: the only request the sender works on, if there is exactly
  one.
- **`shell`** means only the shell adapter may take it. This is `term session run`.
- **`by`** is the worker's session. Only the session a request went to may
  report on it.
- **`caller`** is the reader's session. A sender that reads its own finished
  result takes it, and the result is freed.
- An **owned** endpoint ends when this connection closes. One made without
  `owned` lives until `KILL` (62, payload `u32 session`).

`TELL_RESULT` (89) and `TELL_PROGRESS` (96): u64 id · u8 phase · u8 reject · u8 status · i32 exit_code ·
u32 from · u32 to · str progress · str text.

| enum | values |
|---|---|
| phase | 1 Accepted · 2 Rejected · 3 Running · 4 Progress · 5 Finished |
| reject | 0 None · 1 Empty · 2 Too_Large (body > 16 KiB) · 3 Busy · 4 Not_Listening · 5 Multi_Line (a shell takes one line) · 6 Full · 7 Leased (an automation holds it) |
| status | 0 Done · 1 Failed · 2 Cancelled · 3 Interrupted (a person typed into the shell) · 4 Timeout · 5 Error (a side went away) |

`REQUEST` (91): u64 id · u32 from · u64 parent · str body.

### Lifecycle rules

- **Who takes a request.** A free worker (one `NEXT` waiting) takes it, and each
  waiting `NEXT` is one slot. If no worker waits, a shell at its prompt takes
  it. A session still starting (no prompt and no worker yet, for up to 10 s)
  gives it to whichever of the two is ready first.
- **When it is rejected.** Busy: every slot is taken, or the shell runs
  something. Not_Listening: nothing can take it.
- **When it ends.** A request ends on `ANSWER`, when its command finishes, on
  `CANCEL`, at its timeout (default 30 min), when its sender's or target's
  session goes away, or when a sender waiting with `wait` closes its
  connection.
- **Children.** Ending a request ends the requests sent while working on it
  (its children, by parent).
- **Ending a shell command.** It is interrupted with SIGINT, repeated until the
  command ends (at most 5 s). The shell is busy until then.
- **Results.** A result waits for its sender for 10 minutes, then it is freed.
  After that, `RESULT` and `ANSWER` get `FAIL` 1.

## Sessions

`LIST` (60) answers `SESSIONS` (80): u32 count, then one row per session. A row
is:
u32 id · u8 state (1 Idle, 2 Busy, 3 Exited) · bool active · bool attached ·
u32 pid · u32 elapsed_s · u32 quiet_s (since its program last printed) ·
i32 exit_code · bool endpoint · u32 serving · u64 serving_id · u32 awaiting ·
u32 listening · str process · str cwd · str title · str status · str controller
(the automation holding its lease, empty when none) · bool controller_pass (its
lease passes a person's input through: a handoff).

`CREATE` (61, a Spawn_Msg) and `ATTACH` (63, an Attach_Msg) answer `ATTACHED`
(82): u32 session · u32 channel. The screen then streams as `DATA` (0) on that
channel, limited by credit: send `CREDIT` (1, u32 bytes) on the channel for
what you consumed. Input goes on the same channel (`V_INPUT` 70, `V_RESIZE` 71,
…). Detaching is `CLOSE` (2) on the channel; the core closes it the same way
when the session ends.

The other verbs (`observe`, `read`, `send`, `signal`, `watch`, `new`) are in
`src/features/session_proto/msg.odin` and `msg_req.odin`, next to the message
numbers.

## Automation: snapshot, settle, act and lease

The primitives `term auto` is built on ([AUTOMATION.md](AUTOMATION.md) describes
contracts, steps, elements and adapters).

What a program shows, parsed once by the core (never raw PTY bytes), a wait
for the screen to change, and input for it. None of them resizes, scrolls or
focuses the session.
Field-by-field types are in `src/features/session_proto/msg_auto.odin`, the order
in `codec_auto.odin`.

| kind | payload | answer |
|---|---|---|
| `SNAPSHOT` (103) | u32 session · u32 history (≤ 10 000) · i64 since (< 0: none) | `SNAPSHOT_RESULT` (92) · `FAIL` 1 / 3 / 5 (a `read` is scrolling it) |
| `SETTLE` (104) | u32 session · u64 since · u32 quiet_ms · u32 timeout_ms (0: none) | `SETTLE_RESULT` (93) u32 session · u64 gen · bool exited · i32 exit_code · `FAIL` 1 / 7 |
| `ACT` (105) | u32 session · u8 kind (1 keys · 2 text · 3 mouse) · body | `ACT_RESULT` (94) u32 session · u64 gen (the generation the input went in at) · `FAIL` 1 / 2 / 3 / 5 / 8 |
| `LEASE` (106) | u32 session · str owner (1..64 bytes, shown in windows) | `OK` · `FAIL` 3 / 5 (leased, or a request runs there) |
| `LEASE_RELEASE` (107) | u32 session · bool flush (held input reaches the program) | `OK` · `FAIL` 1 (no lease of this connection) |
| `LEASE_MODE` (108) | u32 session · bool pass (a person's input goes through: a handoff) | `OK` · `FAIL` 1 |

- **Generation.** `gen` grows with every output chunk and every resize. `SETTLE`
  answers when `gen > since` and the program printed nothing for `quiet_ms`, or
  at once when the session exited. Pass the `gen` of your last snapshot.
- **Input.** The core encodes `ACT` with the modes the program has asked for
  at that moment (DECCKM, Kitty flags, ?2004, mouse mode and format), the same
  encoder the window uses. Keys: u32 n (1..64) + n × (u8 key · u32 char ·
  u8 mods); key and mods are `core/terminal/input_encode` `Key` and `Mods`
  (1 Shift, 2 Alt, 4 Ctrl, 8 Super), char is printable ASCII for `Key.Char`;
  each key is a tap (press, then release when the program reports releases).
  Text: bool paste · str (1 byte..64 KiB). Typed text is one key tap per
  character (`\n` Enter, `\t` Tab, an uppercase letter is Shift + the
  letter); a paste is one bracketed paste when the program enabled ?2004
  (an embedded `ESC [201~` is dropped), else typed. Mouse: u8 kind (0 press,
  1 release, 2 motion, 3 wheel up, 4 wheel down) · u8 button (0 left,
  1 middle, 2 right, 3 none) · u8 mods · u16 col · u16 row (1-based cells).
  Input counts as typing: it ends a shell-adapter request like `send`.
- **Lease.** One connection may hold a session's input. While it does, input
  from anyone else (`ACT`, `SEND`, `SIGNAL`, `SESSION_SIZE`, a history `READ`
  of a full-screen program) gets `FAIL` 5, `TELL` is rejected with reject 7
  (`Leased`), and what people type in windows is held (≤ 64 KiB) unless pass
  mode is on. The owner gets `LEASE_EVENT` (95) frames at any time: u32
  session · u8 kind (1 Human, 2 Takeover, 3 Exited, 4 Removed) · bool
  interrupt (^C or Esc) · u32 bytes held · i32 exit code · str bytes typed.
  The lease ends on `LEASE_RELEASE`, when the owner's connection closes (held
  input is dropped), when a window sends `V_TAKEOVER` (109) on its attach
  channel after the person confirmed, or when the session exits or is killed.
- **Lines.** A line number is `top_line + row`; it stays the same as the line
  scrolls into history. `history` returns at most that many lines above the
  screen, only lines `>= since` when since is set: pass the last `top_line` to
  get what scrolled off since then. `history_truncated` says more matched.
- **Result.** A head (gen, size, `top_line`, cursor, modes: alt screen, DECCKM,
  ?2004, ?1004, ?2026, Kitty flags, mouse mode and format; OSC 133 state and
  the last command's output as lines [output_start, output_end) (-1: none / still
  running); exit; OSC 7501 state, app, kind, message; title; process), then
  u32 n + n history rows, u32 n + n screen rows, u32 n + n links (u16 id ·
  str uri). A row is i64 line · bool wrap · bool prompt · u32 n + n runs; a
  run is u16 cells (a wide character counts 2) · u8 fg · u8 bg · bool rgb fg ·
  bool rgb bg · 3 × u8 fg rgb · 3 × u8 bg rgb · u8 style bits (bold, dim,
  italic, underline, inverse, strike, blink, hidden) · u8 underline shape ·
  u16 link · str text. Rows end at their last cell with content or
  attributes. fg 7 / bg 0 are also the defaults: the grid does not tell them
  apart. A snapshot that does not fit in one frame drops history first.

## Example: a worker in Python

```python
import itertools, os, socket, struct

reqs = itertools.count(1)
def frame(kind, payload=b"", req=None):  # channel 0; HELLO has no req
    if req is not None: payload = struct.pack("<I", req) + payload
    return struct.pack("<BII", kind, 0, len(payload)) + payload
def s(text): b = text.encode(); return struct.pack("<I", len(b)) + b

def read_frame(sock):
    kind, _, n = struct.unpack("<BII", sock.recv(9, socket.MSG_WAITALL))
    return kind, sock.recv(n, socket.MSG_WAITALL) if n else b""

def call(sock, kind, payload):
    """Sends one request; its final answer (kind, payload after req)."""
    req = next(reqs)
    sock.sendall(frame(kind, payload, req))
    while True:
        k, p = read_frame(sock)
        if len(p) >= 4 and struct.unpack_from("<I", p)[0] == req: return k, p[4:]  # 84 = FAIL

path = os.path.join(os.environ.get("TERM_SESSION_DIR") or
                    f"{os.environ.get('TMPDIR', '/tmp').rstrip('/')}/term-{os.getuid()}", "core.sock")
sock = socket.socket(socket.AF_UNIX); sock.connect(path)
sock.sendall(frame(10, struct.pack("<IBQ", 0x000100, 4, 0) + s("example")))
assert read_frame(sock)[0] == 10                        # the core's HELLO

_, payload = call(sock, 102, s("echo-app") + b"\x01")    # an owned endpoint
me = struct.unpack("<I", payload)[0]
print("endpoint", me)
while True:
    kind, payload = call(sock, 76, struct.pack("<II", me, 0))  # NEXT → REQUEST (91)
    rid, sender, parent, n = struct.unpack_from("<QIQI", payload)
    body = payload[24:24 + n].decode()
    call(sock, 79, struct.pack("<IQB", me, rid, 0) + s(body.upper()))  # ANSWER → OK
```
