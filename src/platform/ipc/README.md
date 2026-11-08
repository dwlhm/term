# Platform IPC Package (`platform/ipc`)

The `platform/ipc` package provides a standalone, robust, zero-allocation Unix domain socket communication foundation for the `term` architecture.

It is strictly decoupled from `term` feature semantics: it imports only `base:` and `core:` stdlib packages, linking OS primitives via system libc where necessary.

---

## 1. Core Abstractions

The package exposes three primary communication models and an asynchronous poll loop:

```
+--------------------------------------------------------------------------+
|                               Poll_Set                                   |
|             (kqueue on Darwin / epoll on Linux, wake pipe)               |
+---------------------+-------------------------------+--------------------+
                      |                               |
              +-------v-------+               +-------v-------+
              |    Server     |               |     Link      |
              | (1-to-N, RPC) |               | (1-to-1, P2P) |
              +-------^-------+               +---------------+
                      |
              +-------+-------+
              |    Client     |
              |  (Request/    |
              |   Response)   |
              +---------------+
```

### `Server` & `Client` (1-to-N Multiplexed RPC)
- **`Server`**: Listens on a Unix socket, manages a fixed preallocated pool of peer slots (`Server_Opts.max_peers`). Dispatches requests strictly matched against a declarative `Protocol` message catalog.
- **`Client`**: Synchronous or event-driven RPC client with automatic server startup (`start` argv options) and per-request timeout. Channels and 32-bit request IDs (`req`) ensure replies never cross-talk.
- **Wire Framing**: 9-byte header `[kind u8][channel u32][length u32]`, followed by payload up to 1 MiB.

### `Link` (1-to-1 Streaming Duplex Connection)
- Designed for continuous streaming and lifecycle handoffs (e.g. terminal multiplexer core ↔ holder).
- Automatic reconnection absorption: the caller can queue data immediately after dialing without waiting for the internal two-way `HELLO` handshake to settle.
- Buffered control channel and bulk data channel separation with credit-based flow control.

### `Poll_Set` (High-Performance Event Loop)
- Wraps OS event multiplexing (`kqueue` on macOS/Darwin, `epoll` on Linux).
- Supports registered socket/fd interest (`.IN`, `.OUT`), timeouts (`due` deadlines), and signal-safe thread waking (`poll_set_wake`).

---

## 2. Security & Invariants (K2 Boundary)

1. **Strict Peer Identity (`_peer_uid`)**:
   - Darwin: `getpeereid`. Linux: `SO_PEERCRED`.
   - Connections from any effective UID different from the process UID are rejected immediately at `accept()` / `dial()`.
2. **Endpoint Validation (`private_dir`, `_endpoint_path`)**:
   - Socket directories must be owned by the caller's UID and have strict permissions (`0700`, no group/other access).
   - Symlinks in the socket directory path are rejected.
3. **Stale Socket Healing (`_bind_listener`)**:
   - Safely differentiates between live listeners and dead processes left behind.
   - Probes existing sockets 3 times with 50 ms backoff before considering them stale, preventing unlinking during temporary listen backlog congestion.
4. **Inode-Guarded Cleanup (`_unlink_if_ours`)**:
   - Unlinks socket paths on shutdown only if the target file's inode still matches the inode recorded at bind time, preventing accidental unlinking if replaced.

---

## 3. Allocation & Performance Characteristics

- **Zero-Allocation Steady State**: Buffer pools and connection slots are allocated during initialization (`server_open`, `client_open`, `link_dial`, `poll_set_init`). Routine message processing, event polling, and framing perform zero heap allocations.
- **Flow Control & Backpressure**: Sockets apply windowed buffering (`STREAM_WINDOW`) preventing slow readers from consuming unbounded server memory.

---

## 4. Verification

The package boundary and contracts are verified continuously:
- **Unit & Property Tests**: `make test-ipc` (runs `src/platform/ipc`, `src/platform/ipc/tests`, and `src/platform/ipc/contract`).
- **Boundary Import Check (P38)**: Enforced in `make check` via `src/platform/ipc/tests/imports_test.odin`.
