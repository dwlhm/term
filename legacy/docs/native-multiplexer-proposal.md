# Native multiplexer and persistent background sessions

**Approved for implementation on 2026-10-06 by the user’s “oke implement”.** This document records the approved target contract; it does not assert implemented functionality. The user explicitly requires sessions to survive actual Quit / Cmd+Q and monitoring in the macOS menu bar next to the clock.

Planning is elaborated in [the complete P0 plan](p0-native-multiplexer-plan.md). That plan supplies the proposed policies, source evidence, budgets, blockers, migration, failure matrix, and acceptance traceability; its refined details supersede this initial summary where noted below. The approved target extends the current in-process architecture; runtime integration and acceptance gates remain pending. See [the implementation handoff](p0-implementation-handoff.md) for completed prerequisites and actual verification.

User clarification (2026-10-06) confirms last-visible-tab detach closes the GUI window, red close preserves all jobs, and the recommended reopen/review/background-job monitoring behavior. The subsequent broad “oke implement” approved host/IPC, budgets, keymap migration, retention, final-explicit-close empty view, and the other plan decisions for implementation. Measurements and release gates remain pending.

Historical formal approval of existing documents was not independently verified here; they remain the current implementation baseline while this approved extension is implemented.

## Result

Native means discoverable pane operations, predictable focus and clipboard routing, clear close versus detach consequences, and persistent sessions whose state remains visible after the GUI exits.

Proposed flow: shell output enters host-owned PTYs, passes through the existing parser/worker model, and updates authoritative terminal state. Attached GUI clients consume serialized snapshots and render to the screen. A separate menu-bar client consumes session metadata and publishes a native status item. Input from the attached GUI is validated and dispatched to the targeted host-owned pane and PTY. These are conceptual boundaries, not existing APIs.

### P0 interaction contract

| Action | Proposed macOS shortcut | Behavior |
| --- | --- | --- |
| Detach tab | Cmd+D | Hide the entire tab, preserving all panes and running processes in Background Sessions. |
| Close pane | Cmd+W | Terminate the focused pane; the final pane closes its tab. |
| Close tab | Cmd+Shift+W | Close the current/targeted tab and all panes within it; other tabs/workspaces remain alive. |
| Split right / down | Cmd+\\ / Cmd+Option+\\ | Retain existing bindings and inherit the active shell's directory when available. |
| Previous / next pane | Cmd+[ / Cmd+] | Retain cyclic tree-order navigation. |
| Focus by direction | Cmd+Option+Arrow | Select the adjacent pane; no neighbor means no focus change. |
| Resize pane | Cmd+Option+Shift+Arrow | Retain existing directional resize. |
| Equalize panes | Cmd+Option+= | Retain existing equalization. |
| Zoom pane | Cmd+Shift+Enter | Retain existing zoom; changing focus while zoomed displays the new pane. |
| Sessions | Cmd+O | Open the session switcher for attach or focus. |

This deliberately changes the existing destructive Cmd+D binding. The detailed plan proposes a new app-command map/preset with explicit NativeV1/Legacy migration, consistent map-derived labels, preserved explicit overrides, and last-valid-map reload behavior. Native Close Others / Close To Right move to confirmed menu actions; retain Option+Cmd+B as a safe exact detach alias. Existing Config has no keybinding subsystem; this is new scope, not a claim about current overrides.

Application menus and pane context menus expose split, focus, resize, equalize, zoom, close pane, close tab, detach, and sessions with actual shortcuts and enabled-state explanations. A pane context menu targets the clicked pane by stable identity. Menu, keyboard, and pointer paths dispatch the same action rather than owning competing pane state.

Click changes focus; hover does not. Divider dragging takes precedence over focus clicks and uses native resize feedback. Dismissing search or a menu restores its originating pane, or a surviving pane if that target disappeared. Arrow keys without application modifiers remain terminal input. Shell/TUI selection, copy, paste, bracketed paste, and mouse reporting retain their semantics. Split rejection receives inline feedback without stealing keyboard focus.

Close and detach differ. Cmd+Shift+W closes one targeted tab and its panes only, never all tabs; Cmd+W closes one pane and removes its tab only if final. Destructive close warns about affected active/uncertain work. User-confirmed last-visible detach destroys the GUI window after host acknowledgment and releases GUI/GPU resources, with no empty view/new shell; host/jobs/monitor remain alive. Red close releases all visible GUI leases without stopping any jobs. Final-explicit-close empty-view behavior is approved by “oke implement”; implementation and verification remain pending. Root-exit review and continued background-work monitoring are user-confirmed; archival/relaunch cannot discard active work. Stop All is a separate proposed all-target operation requiring explicit confirmation at execution.

### Persistent lifecycle proposal

One per-user **Session Host [new]** owns PTYs, parser state, terminal state, scrollback, and renderer-independent tab/pane topology from creation. Existing pane descriptors live in the application layer and need extraction into that boundary. Detach changes presentation state; it does not transfer raw pointers between processes. A Term GUI client and separate **Menu Bar Monitor [new]** communicate with the host through local IPC. The monitor survives GUI Quit independently.

Normal GUI Quit releases subscriptions and GUI resources. It does not stop host PTYs. Close/terminate remains an explicit targeted operation. **Stop All Sessions and Quit Background Service** is a distinct destructive command with confirmation. Host shutdown and any monitor shutdown behavior are specified independently; ordinary monitor exit must not silently terminate sessions.

Attach launches Term normally and requests the exact stable session ID, preserving pane ratios/focus/history/output and rendering capabilities. User-confirmed normal reopen shows a live/reviewable-session chooser; only zero sessions creates one default shell, and no startup command replay occurs. Reconnect uses complete versioned snapshots before deltas, covering styles/graphemes/graphics/history/cursor/presentation state. No cross-process zero-copy guarantee is made.

Host crash, reboot, logout, or explicit host termination do not promise survival of running processes. Saved layouts are not live sessions; no automatic command replay occurs. Helpers launch on demand in P0; login registration and start-at-login are explicitly deferred. No system setting changes are authorized.

### Menu-bar monitoring

A compact indicator such as **Term 3** counts three detached **tab workspaces** with live PTYs or verified attributable live jobs, not three processes/tasks or root-running booleans. Root shell exit with background work remains live and monitored; incomplete evidence is Uncertain, never authoritative zero. Completed sessions have separate review entries. Native menus show title, directory, pane/jobs, source/freshness and targeted actions, using shared English/Indonesian strings.

Lifecycle (running/exited) is separate from presentation (attached/detached) and activity (Busy/ShellReady/Unknown). Include attributable background jobs in a bounded census with source/freshness; ShellReady does not claim no jobs. This monitors Term-owned sessions, with escaped/disowned-job limitations, not the whole system. Stale state is labeled and never authoritative zero. OS controls icon position; exact adjacency to the clock is not guaranteed.

## Crack

* Host unreachable or IPC lost: retain stale metadata with age/source and disabled destructive actions; offer reconnect or relaunch without replaying commands.
* Attach rejected, capacity exhausted, or GUI launch failed: leave the session detached and running. Acknowledge attach before removing its detached presentation.
* Target disappeared or host restarted: reject stale identities/generations; do not substitute another pane or session for a pending confirmation.
* Duplicate launch: enforce one host per user and one reader/worker per PTY. Clients never add a second PTY drain path.
* IPC congestion: bound queues/messages/snapshots, coalesce metadata, and resynchronize snapshots when revisions diverge. Do not drop terminal bytes or allow a slow observer to cause unbounded memory growth. Exact backpressure and disconnected-scroll-back policies require prototype validation.
* Invalid local messages: validate version, lengths, IDs, revisions, authorization, and target state before side effects. Rejected mutations preserve authoritative topology and ownership.
* Background clipboard requests: no clipboard callback without an attached authorized GUI client. Unavailable clipboard access follows a documented safe fallback; a menu-bar client is not a clipboard authority.
* Unsupported renderer or split size: retain the original layout and explain rejection. Every allocated worker, subscription, socket, snapshot, and native status item has deterministic cleanup.

## Need

Conceptual records **[new]**: HostGeneration, WorkspaceID, PaneID, PaneIncarnation, ViewerID, topology Revision, lifecycle Running/Exited, presentation Attached/Detached, activity Busy/ShellReady/Unknown, ObservationSource, ObservedAt, and targeted acknowledgments/errors. No implementation symbol or future line number is asserted.

A versioned, bounded Unix-domain socket protocol is a provisional transport choice. Use per-user restricted endpoints, peer validation, singleton coordination, and explicit resource limits. Validate its security, portability, serialization cost, and throughput before declaring the approved transport implementation ready. Existing remote/headless MCP surfaces remain isolated; the local host is not an implicit remote service.

The host must run without SDL windows or Metal/GPU work while no GUI is attached. Metadata updates are event-based and coalesced; bounded observation sampling is needed where process state lacks events. GUI rendering retains existing worker/snapshot discipline while dependencies move behind IPC. Production and test flows use the same ownership and command contracts, with substituted PTY/transport dependencies where appropriate.

Apple's [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) supplies the native menu-bar surface. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) is future optional registration research, not a P0 dependency. The detailed plan specifies on-demand bundled helpers, independent lifecycle, version compatibility, and deployment/signing validation.

## Verified baseline and specification changes required

| Evidence | Current behavior / implication |
| --- | --- |
| `docs/architecture.md:517` | Approved background interaction is in-process singleton detach; split detach and post-exit survival are excluded. The proposal intentionally extends that contract and is approved for implementation and requires verification. |
| `docs/architecture.md:221` | Existing detach advertises zero memory copies. The approved cross-process snapshot variant revises this contract without claiming the same guarantee. Style_Table is a value record (src/terminal/style.odin:133), copied by value at src/app/backend.odin:1079; grid cells/rows/ext-colors, scrollback/graphics allocations, and callbacks are pointer-bearing serialization hazards. |
| `docs/architecture.md:506` | Pane topology, worker ownership, snapshot locking, and failure cleanup are approved constraints to preserve. |
| `session_detach_tab` at `src/app/session.odin:434` | Rejects split trees and separately allocated active backends before detach. |
| `app_destroy` at `src/app/main.odin:934` | Clears the registry and destroys session/backend resources on application teardown. Persistence requires a real ownership/lifetime change. |
| `session_destroy` at `src/app/session.odin:263` | Destroys tab pane backends; destructive close must remain distinct from subscription detach. |
| `ui_shortcut_label` at `src/ui/shortcuts.odin:44`; `ui_shortcut_matches` at `src/ui/shortcuts.odin:99` | Existing Cmd+D means Close Tab, Option+Cmd+B means detach, and split/navigation/resize labels are centralized. |
| `pane_tree_navigate_spatially` at `src/app/pane.odin:606` | Existing spatial navigation primitive; proposed binding still needs production integration verification. |
| `_app_split_pane` at `src/app/pane_manager.odin:125` | Queries live shell directory before split. `docs/user-guide.md:398` says configured initial directory instead: verified documentation drift requiring reconciliation. |
| `_app_pane_focus_changed` at `src/app/pane_manager.odin:163`; `_app_route_pane_pointer` at `src/app/pane_manager.odin:220` | Existing focus routing and divider-priority paths should remain coherent with new commands. |
| `pty_foreground_name` at `src/platform/pty/pty.odin:754`; `pty_working_directory` at `src/platform/pty/pty.odin:773` | Available metadata sources; they do not prove all background work is observable. |
| `session_update_title` at `src/app/session.odin:967` | Existing foreground/directory/title heuristics are presentation evidence, not a complete activity monitor. |
| `Makefile:10`; `assets/Info.plist:25` | Build minimum is macOS 14.0 while bundle metadata declares 11.0. Verified deployment metadata disagreement must be reconciled with approval before helper compatibility claims. |

This approved target changes the architectural contract; current production remains in-process until implementation and acceptance verification complete. The two verified documentation/deployment mismatches remain recorded pending reconciliation; architectural completion cannot be claimed while they persist.

## Phases and completion gate

1. Approve lifecycle, ownership, interaction, and shortcut migration contracts; resolve deployment minimum and specification drift.
2. Prototype renderer-independent host ownership and versioned IPC snapshots. Measure input-to-photon latency, PTY throughput, CPU, and memory against the current baseline; demonstrate visual/protocol fidelity including graphemes, styles, graphics, resize, scrollback, and parser responses.
3. Integrate GUI host clients without duplicate readers or lost rendering capabilities; preserve focus, input, clipboard, worker, and snapshot guarantees.
4. Implement whole-tab detach/attach, normal-Quit persistence, and distinct close/terminate commands with transaction acknowledgments and explicit migration.
5. Add the separate native menu-bar monitor and validated on-demand launch; defer login registration/start-at-login.
6. Verify end-to-end regression and update the approved architecture/user guide to match verified behavior.

Acceptance includes four-pane last-visible-tab detach: close the GUI window after acknowledgment, no replacement window/shell, host/monitor remain alive, stable child PIDs/output, and correct reopen/reattach. Actual Cmd+Q and red close preserve all visible/background jobs. Cmd+Shift+W affects one tab only. Verify confirmed natural-exit review/root-exit background monitoring plus rollback, stale state, input/clipboard/rendering regressions and no GUI/GPU work after exit. Final-explicit-close empty-view behavior is approved and requires separate runtime verification. No passing measurements are claimed.

Completion requires approved specifications, verified affected implementation/tests, documented remaining limitations, and no unresolved specification drift. Approval is recorded; completed prerequisite checks are in the handoff. No host-backed persistence or passing performance result is claimed.
