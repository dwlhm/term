# IPC baseline

These are the numbers that the IPC package work (approved IPC spec, section 7.9)
must not make worse. They were recorded on 2026-11-08 at commit `7b4a4e4`, after
slice 0 and before any package work, on the owner's laptop (macOS, Apple
silicon). The machine was otherwise idle.

Re-run with the same commands. Attach the new numbers to the reports of slices
I3, M2 and M3.

## `make bench-session`

Headless suite, release build. Only 3.1, 4.1 and 5.1 touch the session tiers.

| Scenario | p50 | p95 | p99 | Throughput | Alloc | Verdict |
|---|---|---|---|---|---|---|
| 3.1 Session inbox ring | 125 ns/4KB | 125 ns/4KB | 208 ns/4KB | 32.77 GB/s | 0 B | PASS |
| 4.1 Keystroke roundtrip | 0.1 ms | 32.6 ms | 53.5 ms | < 1.0 ms gate | 0 B | PASS |
| 5.1 Zero alloc gate | 0 B | 0 B | 0 B | 0 bytes allocated | 0 B | PASS |

The suite reports 2.2 (damage journaling) and 2.3 (EGC pool dedup) as FAIL.
Both are terminal-core scenarios, not IPC, and they failed before this work too.
The 4.1 tail (p95/p99) is noisy from run to run, so compare p50 and the gate.

## `python3 -I scripts/stress/throughput.py -t bin/term -m noview,view`

Median of 3 runs. `short` is 1..10M with one number per line; `long` is 300k
lines of 199 characters. The `gui` mode needs a window and is not part of the
baseline.

| Mode | Payload | Median | CPU of one run (user+sys) |
|---|---|---|---|
| noview | short | 155 MB/s | core 477+34 ms, holder 52+434 ms |
| noview | long | 222 MB/s | core 216+50 ms, holder 38+222 ms |
| view | short | 127 MB/s | core 511+110 ms, holder 64+430 ms, viewer 380 ms |
| view | long | 171 MB/s | core 242+108 ms, holder 46+235 ms, viewer 310 ms |

## `python3 -I scripts/stress/session_tiers.py bin/term`

All checks passed.

| Check | Result |
|---|---|
| Core back after `kill -9` mid-flood | 3.15 s |
| Healthy viewer while another is SIGSTOPped | 79.0 MB/s |
| RSS during the stop | holder max 21.4 MB, core max 50.8 MB |
| Idle CPU of core + holder over 5 s | 0 s, 0 s |
| Keystroke → echo, 2000 keys | p50 0.036 ms, p99 0.122 ms, max 0.679 ms |
| Orphans after `kill -9` of the holder | 0 of 7 |
