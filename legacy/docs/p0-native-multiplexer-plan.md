# P0 native multiplexer: complete implementation plan

**Approved for implementation on 2026-10-06 by the user’s “oke implement”.** User intent is confirmed: detach an entire tab, preserve its panes and processes through actual Quit/Cmd+Q, and monitor Term-owned sessions in the macOS menu bar. The approval covers the full plan, including technical policies and final-explicit-close empty view. Prototype, regression, resource, security, packaging, and performance gates remain required; approval does not establish passing results. Completed prerequisites and actual checks are recorded in [the implementation handoff](p0-implementation-handoff.md).

Latest user clarification (2026-10-06): detaching the last visible tab closes the whole GUI window without a replacement shell; red-button close preserves jobs; the recommended reopen chooser, natural-exit review, and root-exit/background-job monitoring behaviors are confirmed. These initial confirmations were followed by broad approval of this complete plan (“oke implement”), including host/IPC, budget, command-map, packaging, and retention policies; experimental validation remains pending.

Historical formal approval of the existing architecture documents has not been independently verified in this task. Treat them as the current implementation baseline while the approved replacement/extension is implemented; this plan does not claim implementation alignment or resolved drift.

## Result / Crack / Need

**Result:** host-owned shells emit bytes through PTYs to terminal workers/parsers and authoritative terminal state. Versioned snapshots reach the attached Term GUI and its renderer; metadata reaches a separate native menu-bar monitor. GUI commands target stable session/pane identities and reach the owning PTY or topology transaction. Detach and GUI Quit remove presentation subscriptions without destroying running sessions. Close and explicit service shutdown are destructive operations with clearly named scope.

**Crack:** transport loss, stale identities, observer congestion, attach rejection, unsupported renderer, on-demand helper launch failure, host crash, and uncertain process observations receive distinct states. A failed command must not mutate a different target or drop the original tab. Stale monitoring must not look empty or idle. A GUI/helper upgrade must not terminate live work as an implicit migration step.

**Need:** one per-user host; one worker/reader per PTY; renderer-independent topology; complete pointer-free terminal serialization; bounded authenticated local IPC; distinct window-close and application-quit intents; native menu routing that executes once; truthful process observation; on-demand helper packaging/launch compatible with the approved deployment minimum; approved performance budgets and regression evidence.

## Scope, intent, and limits

| ID | Confirmed intent | Work | Acceptance |
| --- | --- | --- | --- |
| I1 | Whole-tab detach keeps all panes running | W3, W5 | T3, T5 |
| I2 | Actual Quit/Cmd+Q does not kill jobs | W1, W3, W5, W7 | T5, T11 |
| I3 | Menu-bar monitoring remains after GUI quit | W7, W8 | T8, T11 |
| I4 | Native, discoverable pane operations | W2, W6 | T1, T6 |
| I5 | Keyboard navigation fits existing splits | W2, W6 | T1, T2 |
| I6 | Explicit failure and close consequences | W4, W5, W6 | T4, T7, T9 |

P0 includes the lifetime/ownership extension because an in-process background registry cannot meet I2. It includes menus, shortcut migration, focus routing, pane close, split feedback, host snapshots, attach/detach transactions, monitoring, packaging, upgrade handling, and approved-document reconciliation.

P0 excludes remote/cloud multiplexing, moving panes across windows, a system-wide task manager, restoring live processes after reboot/host crash, automatic command replay, a new shell, automatic macOS setting changes, login registration, CPU/RSS metrics, and full terminal-content VoiceOver. New controls must support VoiceOver and keyboard access. Start-at-login is future optional scope. Common runtime/IPC uses POSIX on macOS and Linux with portable-host parity and Linux GUI/runtime regression coverage; no Linux tray is proposed. MCP retains independent private PTYs and tools, with no automatic host sharing.

## Decision ledger

All decisions below are approved for implementation by “oke implement” on 2026-10-06. “Proposed” wording elsewhere preserves the original design history or identifies an unmeasured experimental policy; it does not require renewed architectural approval. Changes beyond the approved contract still require approval. Validation and release gates remain pending.

| ID | Decision | Status | Approval / experiment required |
| --- | --- | --- | --- |
| D1 | Entire tab is the detach unit | User-confirmed | Preserve pane identities/layout on attach. |
| D2 | Sessions survive actual GUI Quit/Cmd+Q | User-confirmed | Host ownership and packaging must satisfy T5. |
| D3 | Monitor is separate from the GUI process | Approved for implementation; verification pending | Required lifetime separation verified by T8. |
| D4 | One Session Host per OS user owns sessions from creation | Approved for implementation; verification pending | Singleton, topology extraction, and PTY ownership prototype. |
| D5 | GUI and monitor use local versioned Unix-domain IPC | Approved for implementation; verification pending | Peer authentication, bundle path, throughput, snapshot limits. |
| D6 | Cmd+D detach; Cmd+W close pane; Cmd+Shift+W close current/targeted tab and all its panes only | Approved for implementation; verification pending | Other tabs/workspaces remain alive; migration/exact dispatch T1. |
| D7 | Cmd+Option+Arrow performs spatial focus | Approved for implementation; verification pending | Existing primitive wired into common action dispatcher. |
| D8 | Busy/ShellReady/Unknown; Unknown warns on close | Approved for implementation; verification pending | Census includes attributable background jobs; no empty-name Idle claim. |
| D9 | No cross-process zero-copy claim | Approved for implementation; verification pending | Implement and verify the approved cross-process variant of the in-process contract. |
| D10 | Recommended actual macOS minimum is 14 | Approved for implementation; verification pending | Do not silently raise supported minimum; reconcile build and plist. |
| D11 | Last visible detach closes GUI window after acknowledgment; red close preserves all visible jobs | User-confirmed 2026-10-06 | T5/T6; no empty view/replacement shell after detach; host/monitor survive. |
| D12 | Natural exit retains read-only review; relaunch explicit; root-exit background work remains monitored | User-confirmed behavior 2026-10-06 | T4/T8; technical retention/census/incarnation rules remain proposed. |
| D13 | On-demand bundled helpers; login registration off | Approved for implementation; verification pending | Prove independent host/monitor lifetime without launchctl/root. |
| D14 | Versioned NativeV1/Legacy command map and explicit existing-install migration | Approved for implementation; verification pending | T1, invalid reload retains last valid map. |
| D15 | One GUI writer lease per workspace; monitor status capability | Approved for implementation; verification pending | Reservation/commit race tests and takeover rejection. |
| D16 | Numeric limits and release budgets below | Approved for implementation; verification pending | Validate/adjust openly before prototype GO. |
| D17 | Explicit close of final visible tab leaves an empty view while background jobs survive | Approved for implementation; verification pending | Separate from last-detach/window-close; T6 implementation/verification pending. |
| D18 | Normal reopen chooser for live/reviewable work; targeted attach; default shell only with zero sessions | User-confirmed recommendation 2026-10-06 | T5/T6; no automatic replay or extra shell. |

## Verified source baseline

Each cited symbol below exists. Proposed destinations later in this plan are labeled [new]. Evidence is static; it is not a runtime observation.

| Existing symbol / source | Verified relevance |
| --- | --- |
| `app_destroy :: proc(a: ^App)` — `src/app/main.odin:934` | Registry clear at line 939 and manager destruction tear down sessions on exit. |
| `session_destroy :: proc(s: ^Tab_Session)` — `src/app/session.odin:263` | Destroys pane backends and tab resources. |
| `session_manager_destroy :: proc(sm: ^Session_Manager)` — `src/app/session.odin:289` | Iterates current tabs and destroys them. |
| `session_detach_tab :: proc(sm: ^Session_Manager, idx: int) -> bool` — `src/app/session.odin:434` | Requires one embedded singleton backend; splits are rejected. |
| `session_attach_tab :: proc(sm: ^Session_Manager, persistent_session: ^session_core.Core_Session) -> (int, bool)` — `src/app/session.odin:564` | Existing attachment is in-process and accepts a pointer, not a wire identity. |
| `session_close_others :: proc(sm: ^Session_Manager, keep_idx: int) -> int` — `src/app/session.odin:755` | Existing bulk destructive close needs unified confirmation. |
| `session_close_to_right :: proc(sm: ^Session_Manager, idx: int) -> int` — `src/app/session.odin:767` | Existing right-side bulk close needs stable target set. |
| `_app_execute_tab_menu :: proc(a: ^App, item: platform_tabs.Tab_Menu_Item, target_idx: int)` — `src/app/main.odin:642` | Close Others/To Right directly destroy sessions without shared confirmation. |
| `ui_shortcut_label :: proc(a: Shortcut_Action) -> string` — `src/ui/shortcuts.odin:44` | Hardcoded action labels: Cmd+D close tab and Option+Cmd+B detach. |
| `ui_shortcut_matches :: proc(action: Shortcut_Action, ev: input.Input_Event) -> bool` — `src/ui/shortcuts.odin:99` | Existing exact physical shortcut matcher. |
| Shortcut branch — `src/app/main.odin:1400` | Option+Cmd+D closes others; Shift+Option+Cmd+D closes right. |
| Broad Cmd+D rune branch — `src/app/main.odin:1442` | Must be replaced; unwanted modifiers can reach destructive branch. |
| `Config` — `src/config/config.odin:80` | No configurable keybinding fields exist; migration cannot claim current per-user shortcut settings. |
| `_app_split_pane :: proc(a: ^App, direction: Split_Direction) -> bool` — `src/app/pane_manager.odin:125` | Validates split and inherits live shell cwd where query succeeds. |
| `_app_pane_focus_changed :: proc(a: ^App, previous: ^Backend)` — `src/app/pane_manager.odin:163` | Existing backend focus routing. |
| `_app_route_pane_pointer :: proc(a: ^App, p: input.Input_Pointer_Event) -> bool` — `src/app/pane_manager.odin:220` | Divider interaction precedes focus click routing. |
| `pane_tree_navigate_spatially :: proc(tree: ^Pane_Tree, dir: Split_Direction, forward: bool) -> bool` — `src/app/pane.odin:606` | Reuse spatial neighbor selection; preserve no-neighbor behavior. |
| `Backend` — `src/app/backend.odin:97` | Mixes PTY/parser/grid ownership with renderer, interaction state, callbacks, and pointers. Cannot be serialized wholesale. |
| `_terminal_sync_to_front :: proc(b: ^Backend)` — `src/app/backend.odin:1057` | In-process snapshot; copies the value-owned Style_Table at line 1079 (fixed entries, count, Theme; src/terminal/style.odin:133). Grid cells/rows/ext-colors, scrollback/graphics allocations, and callback pointers still require explicit serialization rather than pointer transfer. |
| Graphics snapshot block — `src/app/backend.odin:1187` | Deep snapshot of graphics stores must retain fidelity across host boundary. |
| `Core_Session` — `src/session_core/session.odin:40` | Existing core representation is not a complete wire/GUI replacement. |
| `session_extract_screen :: proc(s: ^Core_Session, scrollback_lines: int = 0, allocator := context.allocator) -> string` — `src/session_core/session.odin:498` | Text extraction is not a graphical snapshot format. |
| `session_stop :: proc(s: ^Core_Session)` — `src/session_core/session.odin:430` | Signals shell group, closes PTY, joins worker, escalates; not proof every descendant job is terminated. |
| `pty_has_running_processes :: proc(p: ^Pty) -> bool` — `src/platform/pty/pty.odin:679` | Error paths return false and foreground checks miss background jobs. |
| `pty_foreground_name :: proc(p: ^Pty, dst: []u8) -> int` — `src/platform/pty/pty.odin:754` | Foreground-name evidence only; empty result is ambiguous. |
| `pty_working_directory :: proc(p: ^Pty, dst: []u8) -> int` — `src/platform/pty/pty.odin:773` | Directory source; query may fail. |
| `session_query_taskinfo :: proc(pid: int) -> (rss_mb: int, cpu_pct: f32)` — `src/platform/tabs/session_switcher_darwin.odin:8` | CPU always returns 0; must not label this as measured usage. |
| `input_translate_sdl :: proc(ev: sdl3.Event, out: []Input_Event) -> (n: int, quit: bool, resized: bool)` — `src/platform/input/pump.odin:192` | QUIT and WINDOW_CLOSE_REQUESTED are merged. |
| `window_poll_events :: proc(w: ^Window) -> bool` — `src/platform/window/window.odin:223` | Both intents close the window; new lifecycle semantics require separation. |
| `pty_write :: proc(p: ^Pty, data: []u8) -> bool` — `src/platform/pty/pty.odin:528` | May write a prefix then fail at EAGAIN; callers lose the written-byte offset. Host input needs counted/resumable writes. |
| `backend_global` — `src/app/backend.odin:180`; assignment at `src/app/backend.odin:643` | Callback paths use a global owner, a potential concurrent-pane response-routing hazard to verify, not a demonstrated runtime defect. |
| `_session_response_owner` — declaration `src/session_core/session.odin:198`, thread-local annotation at line 197 | Core callback ownership uses thread-local context; extraction must retain explicit per-pane routing. |
| `persistence_restore_tab :: proc(a: ^App, layout: Persisted_Layout, context_dir: string = "") -> (tab_idx: int, ok: bool)` — `src/app/persistence.odin:902` | Explicit restore starts new shells/commands; not live attachment. |
| `persistence_save_tab_odin :: proc(tab: ^Tab_Session, target_path: string, name: string = DEFAULT_LAYOUT_NAME) -> bool` — `src/app/persistence.odin:993` | Save must obtain coherent host descriptors rather than dereferencing GUI-owned runtime. |
| `Input_Event` — `src/platform/input/input.odin:108`; `input_encode` — `src/platform/input/input.odin:284` | Portable event/encoding logic currently shares the SDL pump package. |
| Package imports — `src/platform/input/pump.odin:5` / `:7`; `src/interaction/dispatcher.odin:4` | SDL/window imports propagate through shared interaction input dependencies; moving Backend alone does not remove GUI linkage. |

## Architectural ownership and data model

Session Host [new] is the sole authoritative owner of shell launch, PTY descriptors, parser responses, live terminal state, CPU-side graphics, scrollback retention, pane topology/ratios/focus/zoom, worker-handled per-view selection/search/scroll interaction, and lifecycle. ViewerID associates interaction and snapshots. The GUI owns windows, pixel rectangles/font/DPI, pure hit-tests that submit commands, GPU resources/render mirrors, native controls, and authorized clipboard access. The monitor owns its NSStatusItem/menu and metadata cache, never a PTY or terminal renderer.

Extract a renderer-independent runtime from Backend; preserve parser/worker shape and existing graphical capabilities. Keep renderer LUT/cursor objects and GUI pointers outside the host. Do not solve the boundary by using text extraction or copying process-local addresses. Shared existing terminal/parser/graphics code remains reusable by MCP without forcing headless clients through GUI code.

Mandatory extraction includes pure input-event/types and encoding into `src/input_core/types.odin` and `src/input_core/encoding.odin` [new]. Keep SDL pumping in the platform adapter; update interaction, app, and MCP imports without semantic encoding changes. Extract semantic cursor/style records where needed so the host does not import the entire renderer package. Portable packets own validated key/mouse flags and coordinates; never serialize SDL events/pointers. Linkage inspection and runtime no-GUI/GPU proof are prototype GO requirements.

| Conceptual record [new] | Required fields / contract |
| --- | --- |
| HostIdentity | Protocol version, host generation, user identity, build/runtime version. |
| SessionIdentity | Opaque stable WorkspaceID within HostGeneration; session/tab terminology refers to this workspace. |
| PaneIdentity | Opaque PaneID under WorkspaceID plus PaneIncarnation for explicit relaunch; PID/start stamp are internal process evidence, not routing IDs. |
| SessionRecord | Title/override, topology revision, pane IDs, lifecycle, presentation lease, retained exit data. |
| PaneRecord | PTY/worker ownership; spawn recipe/environment provenance; cwd observation; root-process exit, PTY EOF and owned-job evidence tracked separately. |
| TopologyRecord | Leaf/split variants, orientation, ratios, focused pane, zoomed pane, monotonic revision. |
| ActivityObservation | Busy/ShellReady/Unknown, observation source/timestamp/query outcome, foreground and attributable background labels. |
| WorkLiveness | VerifiedLive/Completed/Uncertain from separate root exit, PTY EOF and owned-job evidence; RootProcessExited alone is insufficient. |
| CommandEnvelope | RequestID, HostGeneration, WorkspaceID/PaneID/PaneIncarnation or explicit target set, ViewerID, expected revision, action. |
| CommandOutcome | Rejected before acceptance, or Accepted then Applied/Failed; Unknown after result-cache expiry/host crash; revision, typed error, exact targets. Never replay input blindly after Unknown. |
| SnapshotEnvelope | Generation, session/pane IDs, snapshot revision, topology revision, full/delta marker. |
| GUILease | ViewerID, targeted workspace subscription, presentation state, liveness/release reason; at most one GUI writer per workspace. |

Avoid serialized pointers, callbacks, arbitrary executable replay, or borrowed process-local strings. IDs must be validated before lookup; every borrowed snapshot has a deterministic release. A topology mutation occurs inside host authority and publishes an accepted revision only after resources are ready.

## Wire protocol and transport

Unix-domain socket transport is approved for implementation, with authentication, limits, portability, and benchmark gates still pending. Restrict user directory to 0700 and socket to 0600; check peer UID, handshake nonce, and capability. This is a same-user security model, not cryptographic same-application authentication. Validate endpoint path length, symlinks, singleton lock, and stale endpoint ownership before unlinking; concurrent launch has one winner. Exact filesystem location and peer-validation APIs are prototype outcomes. Never expose a TCP listener as fallback or reuse MCP access implicitly.

Handshake negotiates major version 1, supported minor/capabilities, HOSTVERSION, binary location, and generation. Incompatible clients receive an explanation without stopping jobs. Length-prefixed tagged unions distinguish CONTROL, INPUT, SNAPSHOT_DELTA, METADATA, and CLIPBOARD; bound before allocation and reject unknown variants. Use monotonic revisions plus generation for ordering. Accepted requests subsequently publish Applied/Failed; acknowledgment alone never implies PTY delivery.

| Message family [new] | Direction | Required contract |
| --- | --- | --- |
| Hello / Welcome / Incompatible | Both | Version, capabilities, generation, authenticated peer. |
| ListSessions / MetadataSnapshot / MetadataDelta | Host to client | Bounded lists, source/freshness, revision, stale recovery. |
| CreateSession / SplitPane | GUI to host | Validated spawn context and expected topology revision. |
| Subscribe / FullSnapshot / SnapshotDelta | Both | Full state before deltas; revision mismatch forces resync. |
| Input / Paste / Resize / Focus | GUI to host | Lease-authorized pane target; acknowledgment/backpressure semantics. |
| Detach / Attach / CloseTargets | GUI to host | Stable identities and explicit transaction outcomes. |
| Observe / AttachRequest | Monitor to host/launcher | Metadata only or exact target launch request; no raw input. |
| ClipboardRequest / ClipboardResponse | Host and attached GUI | Authorization, request lifetime, bounded payload, no monitor authority. |
| Ping / Goodbye / HostStopping | Both | Liveness, subscription cleanup, truthful pending state. |

Snapshot schema covers grid cells, styles and extended colors, graphemes, alternate-screen state, cursor, dimensions, modes needed for input encoding, scrollback, graphics namespaces/images/frames/placements, and parser-driven presentation metadata. Large data uses bounded chunking with integrity/revision checks; do not require one allocation for an entire image/history snapshot. A failed full snapshot never replaces a valid GUI state with partial data.

A slow GUI can lose obsolete presentation deltas and request a full resync; it cannot make the host discard PTY bytes before parsing. Bound queues by count and bytes, with independent bulk-transfer credits and resize coalescing. Input rejection is visible without silent truncation. After uncertain acknowledgment, query RequestID outcome instead of replaying input or spawn. The deduplication horizon is a named unresolved budget below.

Add counted/resumable PTY write adapter [new] returning bytes_written plus error; each queue entry retains an offset across partial writes/EAGAIN. Schedule finite writable retries; never resend the whole payload after a prefix was written. Preserve the public bool wrapper for MCP unless an explicit migration is approved. Parser replies use a separate ordered bounded path; prove worst-case expansion/batch limits and pressure handling before prototype GO. Never perform socket writes or PTY readiness waits under shared terminal/snapshot locks. Concurrent two-pane parser-query tests prove replies return to the originating PTY through explicit context/TLS, not an ambiguous global.

History is paged (proposed 256-row pages) and search runs host-side; do not retransmit all history every frame. Reconstruct graphics assets/style/grapheme IDs locally. Preserve parser modes, theme, geometry and last accepted detached cols/rows/pixels. Accepted resize publishes complete per-pane actual dimensions asynchronously, with desired clipping as in the current renderer.

## Lifecycle states and transactions

Lifecycle and presentation are orthogonal. Running does not mean Busy; Detached does not mean Exited. Last-known stale records retain labels and age rather than silently changing to Exited.

| Event | Before | Host action | Presentation outcome |
| --- | --- | --- | --- |
| Create | No session | Spawn PTY/worker then commit identity/topology | Attach on success; reject without ghost tab on failure. |
| Split | Running session | Validate limits, start pane, commit topology revision | Original topology remains if allocation/spawn fails. |
| Detach tab | Attached | Commit detached presentation and acknowledge | Hide after acknowledgment; if last visible tab, close GUI window and release GUI resources; keep host/jobs/monitor. |
| Attach | Detached | Validate capability/capacity/identity and reserve attachment | Show only after complete initial state; rollback lease on failure. |
| GUI Quit | Attached sessions | Release GUI leases and subscriptions | Host keeps sessions; monitor keeps running. |
| Red-button window close | Attached sessions | Release all visible GUI leases/subscriptions without termination | Close window; host preserves all visible and previously detached jobs; monitor continues. |
| GUI connection dies | Attached sessions | Expire/release leases without PTY destruction | Mark detached; reconnection requests full state. |
| Root process exits | Running pane | Sole worker reaps root and independently tracks PTY EOF/owned jobs | Retain output; active attributable work remains live; uncertain census is Uncertain, not completed. |
| Close pane | Any retained pane | Confirm target scope, terminate if running, remove leaf | Collapse topology; final pane removes tab. |
| Close tab / Cmd+Shift+W | Targeted/current tab exists | Confirm stable pane set within that one tab; terminate/remove it | Other tabs/workspaces remain alive; not Close All Tabs. |
| Stop all sessions/service | Host active | Confirm scope; atomically enter HostStopping admission barrier then stop captured validated targets | Partial stop keeps host running and reports remaining work; no GUI-Quit alias. |
| Host crash/reboot | Any | No survival guarantee | Report lost/unavailable state; no automatic command replay. |

Attach uses a prepare/reserve, coherent full snapshot, GUI/GPU-ready, commit sequence. A finite timeout abort preserves the original attached/detached state; GUI crash revokes the orphan writer lease to background. Already attached sessions focus their existing surface or return explicit lease conflict. The monitor cannot acquire an input-writing lease.

User-confirmed: after the host acknowledges detaching the last visible tab, close the whole GUI window. Do not show an empty workspace or create a new tab/window/shell. In P0's single-window model the GUI process may exit; release window/GPU/client resources while host and monitor remain independent. Rejected detach retains the original window/tab. This intentionally replaces the current replacement-shell behavior.

Route acknowledged last-detach through actual close-window/GUI teardown, not hide-window state. Destroy the SDL window and Metal/GPU resources and stop the GUI frame loop. T5 verifies released resources and the GUI PID outcome of the chosen single-window lifecycle, while host/monitor/job PIDs remain intact.

Approved by the broad “oke implement”: explicit final-pane close removes its tab; explicit close of the final visible tab leaves an empty view with New Tab/Sessions while background jobs survive. This differs from last-detach window closure; runtime implementation and T6 remain pending.

User-confirmed: the red close button releases all visible GUI leases and closes the window without terminating their jobs or already-detached jobs, and without creating a shell. In the single-window model the GUI process may exit, but its intent remains distinct from Quit. Cmd+Q releases all visible views; manually undetached sessions also survive. Neither operation calls host close/terminate.

User-confirmed recommendation: normal reopening chooses among live/reviewable host workspaces without replaying saved commands or opening new shells automatically. A targeted launch attaches the requested identity. Only with zero host sessions does normal reopen create exactly one default shell. Explicit New Tab represents a new request.

RootProcessExited does not mean the pane/workspace is completed when attributable background jobs or open-PTY output remain. Show **shell exited, background work continues**, retain drain/monitoring, and count verified owned work as live. Root-exited with unknown job evidence is Uncertain, never authoritative zero. Read-only presentation may begin at root exit, but archival eviction/relaunch must not discard active work. Only completion evidence across root exit, PTY EOF, and owned-job census admits an exited record to Review.

Natural shell exit retains output and exit status/code. Explicit Relaunch is permitted only after no owned jobs remain or after a confirmed stop transaction safely completes; it creates a new PaneIncarnation/process identity and invalidates old confirmations. Fully completed workspaces appear under Review, not Attach Live, with zero verified live work. No deliberate termination is automatically resurrected.

Proposed in-memory exit retention: maximum 32 completed workspaces, 256 MiB aggregate retained terminal/graphics data, 24-hour TTL. Evict oldest inactive completed review record with a visible retention notice. Open review is pinned and counted fully toward the same hard budget. If no safe archival capacity remains, publish ReviewUnavailable with visible reason rather than allocating beyond the cap. Never evict running work or classify active jobs as exited to fit the budget. Validate proposed defaults; retention is not disk/reboot persistence.

Stop All confirmation captures and revalidates scope before commit; changed scope refreshes the preview. Commit atomically enters HostStopping and rejects new create/split/attach mutations as appropriate while stopping the validated target set. Never kill work outside that set. Partial stop keeps the host running, reports remaining work, and does not pretend to quit; the admission/retry state is explicit.

Idle host shutdown is permitted only with no active sessions or retained review data, after a documented bounded idle policy or explicit stop. Exact idle timeout is a named baseline decision. The monitor can exit independently; it warns once that jobs remain running and never terminates the host as a side effect.

## UI actions and shortcut migration

All actions carry stable targets and use a single common command dispatcher. Native NSMenu key equivalents and SDL events must execute an action exactly once; define one authority for dispatch and suppression of duplicate delivery. Key-down repeat must not duplicate destructive commands. Exact modifier matching applies to every new binding and removes the broad Cmd+D branch.

| Action | P0 binding | Target / behavior |
| --- | --- | --- |
| Detach tab | Cmd+D | Whole tab, with no termination. |
| Close pane | Cmd+W | Focused pane; final pane closes tab. |
| Close tab | Cmd+Shift+W | Close the current/targeted tab and all panes within it after scoped confirmation; other tabs/workspaces remain alive. |
| Split right | Cmd+\\ | Retained exact physical backslash binding. |
| Split down | Cmd+Option+\\ | Retained; not pipe character. |
| Focus previous/next | Cmd+[ / Cmd+] | Retained cyclic order. |
| Focus direction | Cmd+Option+Arrow | Spatial neighbor, no wrap if none. |
| Resize direction | Cmd+Option+Shift+Arrow | Retained existing behavior. |
| Equalize | Cmd+Option+= | Retained. |
| Zoom/unzoom | Cmd+Shift+Enter | Retained; focus switch changes visible zoom pane. |
| Sessions | Cmd+O | Existing switcher entry retained. |
| Previous/next tab | Ctrl+Shift+Tab / Ctrl+Tab | Retained. |
| Overflow | Cmd+Shift+\\ | Retained. |

Current labels are hardcoded and Config has no keybinding fields. Add a narrowly scoped application command map/preset [new], not arbitrary VT encoding configuration. Clearly marked known-fresh installs may default to NativeV1. Versioned migration state does not retroactively identify older unmarked installs: an unmarked installation is Unknown and receives an explicit one-time preset choice, never inferred-fresh defaults. Known legacy installs receive the Legacy-to-Native choice listing old/new actions/consequences. This session targets Native; deployment migration remains explicit. Legacy routing exact-matches modifiers and uses all close confirmations.

Preserve explicit overrides once the new map exists. Resolve labels, hints, NSMenu equivalents and SDL matching from the same active map. Invalid/conflicting reload retains the last valid map and explains rejected entries. T1 proves known-fresh/legacy/unknown first-launch detection, state creation, repeated launch, chosen preset, and reload failures. Release notes and migration notice explain old Cmd+D close versus new detach and bulk-close changes.

Close Others and Close To Right move from Option+Cmd+D / Shift+Option+Cmd+D to explicit menus with shared scoped confirmation in NativeV1. Native modified D-family defaults are never destructive. Retain Option+Cmd+B as an exact safe detach alias. Legacy defaults can retain prior meanings only through the explicit selected preset with exact matching and confirmation. Unknown modifier combinations never trigger destructive rune fallthrough.

Menu application sections and pane context menus expose Split Right/Down, directional/ordered Focus, Resize, Equalize, Zoom, Close Pane, Close Tab, Detach, and Sessions. The context target is the clicked pane, not whichever pane happens to be focused when acknowledgment arrives. Disabled items explain unsupported renderer, size/capacity, exited target, or unavailable host.

Focus changes synchronize input target, cursor, paste, search, titles, and dimming through the common model. Divider hits retain priority over pane focus. Cancel/dismiss without an action restores the originating pane where possible; a successful focus action retains its chosen destination and menu closure must not undo it. Host errors update all surfaces for the same view consistently. Screen-reader/keyboard menus expose pane identity, selected state, action, and disabled reason; test actual accessibility behavior.

English and Indonesian localization is required for all new GUI/monitor/menu/migration/status/error strings and accessible labels. Extend shared `src/i18n/i18n.odin`, `src/i18n/strings_en.odin`, and `src/i18n/strings_id.odin`; no separate hardcoded monitor translations. Use locale-aware counts/plurals and shared action wording. T6 checks both locales, fallback behavior, counts, layout, and accessible labels.

## Process observation and destructive scope

Use Busy / ShellReady / Unknown observation states. Busy means credible observed owned work. ShellReady means foreground shell is observed, not that no background work exists. Unknown includes failed, stale, or incomplete census. Empty foreground name alone never proves Idle; avoid the Idle label unless complete trustworthy no-work evidence exists. A bounded census includes attributable background jobs; deliberately disowned/reparented/new-session daemon processes are outside the guaranteed observation scope and disclosed.

The existing CPU query returns a constant zero. CPU/RSS metrics are outside P0; across all touched surfaces omit the stub or mark unavailable, never present placeholder zero as measured usage. Directory/title remain observations with provenance, not immutable truths.

Close confirmation captures HostGeneration, stable target IDs, and scope revision. It lists affected pane/session count and known foreground labels; Unknown uses an uncertainty warning. Cancellation does not stop workers, close PTYs, modify topology, or change focus. If scope changes before confirmation commit, revalidate and ask again rather than adding newly created panes silently.

Cmd+Shift+W has exactly one-tab scope: for a tab containing four panes, it closes those four panes and that tab. It is not Close All Tabs, Quit, or Stop All Sessions. Other tabs/workspaces remain alive. Cmd+W closes one targeted pane, removing its tab only when that was its final pane. Stop All is the separately confirmed all-target operation.

Capture host generation, pane incarnation, and observation revision as well as topology scope. Termination signals validated owned groups and observed same-session descendants, including stopped jobs and groups different from the shell group. Require PID > 1, valid PGID, creation-stamp checks, and revalidation before signaling; do not sweep the user's entire process tree. Proposed TERM grace is 2 seconds followed by KILL with a 1-second reap deadline. Other workspaces stay untouched.

Existing shell-group signaling is not proof of all-job termination. Report incomplete termination/remaining observed jobs as partial failure, including exited root with background jobs. Escaped/disowned daemon guarantees are excluded explicitly. Final platform-specific census/termination algorithm and resource/join bounds are blocking prototype outcomes; do not report complete success merely because descriptors close.

## Native monitor, helpers, packaging, and environment

The monitor uses a native NSStatusItem and menu, as described by [Apple NSStatusItem documentation](https://developer.apple.com/documentation/appkit/nsstatusitem). `Term N` counts detached workspaces with live PTYs or verified attributable live jobs, not root-running booleans/panes/CPU activity. Uncertain root-exited work has an explicit uncertainty indicator, not an authoritative zero. Position is OS-controlled. Open/Background sections list title, cwd, live-work/pane count, lifecycle, activity source/time, foreground and attributable background jobs; completed Review is separate. Sanitize control characters/invalid UTF-8; count the full owner registry, not a truncated row buffer.

Monitor launch and lifetime are independent of GUI lifetime. Closing its menu is not exiting it. Quit Monitor ends only the monitor, with a one-time jobs-still-running warning. Show/Hide Monitor is a preference; Sessions remains the GUI fallback. Separate Stop All Sessions and Quit Background Service names destructive scope and confirms it. Host-unavailable display remains visibly stale/offline and never authoritative zero.

Attach uses macOS normal application launch with exact stable identity and generation; concurrent clicks are coalesced/acknowledged rather than creating duplicate GUI ownership. If Term is already running, deliver the request to its authorized client. A session already attached focuses its existing presentation instead of stealing a lease silently.

[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) is future optional login-registration research, not a P0 dependency. Recommend on-demand launch through validated bundled executable paths with safe spawn, never fork in a multithreaded GUI. Host startup configures an independent process session and stdio/logging; an inherited GUI control pipe must not determine lifetime. Launch the AppKit monitor normally as an accessory helper. No launchctl, root action, or login-item registration is required or performed in this plan.

Apple's [register method](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) concerns registration that can bootstrap subsequent logins; do not call it while claiming launch-at-login is off. It is explicitly deferred, not hidden inside on-demand startup. P0 validates that quitting the parent GUI leaves both helper processes independent without such registration.

Three executables are packaged: Term GUI, renderer-independent term-host, and AppKit term-monitor. `make bundle` currently packages GUI, generated plist, fonts, notices, and frameworks (`Makefile:65`). Extend it with host/monitor artifacts and helper identity metadata; `make install`/`make dmg` package the same layout. Validate development-path fallback explicitly, avoid absolute build paths, and keep fonts in the main app. Sign/notarize nested helpers inside-out for distribution; the host must not load GUI/GPU dependencies. Labels/paths are structured arguments, never shell-injected commands.

The build sets minimum macOS 14.0 (`Makefile:10`) while `assets/Info.plist:25` declares 11.0. Recommend reconciling to the actual 14.0 build requirement, subject to approval; do not silently change supported OS claims. Validate clean bundle launch and installed helper path after moving the bundle. Signing/notarization/distribution requirements are not satisfied by local compilation.

Shell launch preserves session mode, configured shell/executable, argv, cwd, locale, TERM-related variables, and environment provenance. Use the requesting GUI's launch context for new sessions rather than silently replacing it with the monitor/host's environment; serialize owned values and retain the current shell/config behavior. Helpers may inherit a different PATH/cwd; test normal app and development launch. Do not expose environment secrets in logs/metadata. MCP remains independent and preserves its own private session environment/mode.

Adapt existing macOS Services in `src/app/macos_services.m`: explicit Open Term Here caller folder overrides cached/inherited cwd. New host GUI sessions stay interactive, never downgraded to FastHeadless mode. Save Layout consumes a coherent host descriptor snapshot with live cwd and safely escaped title/path literals. Restore Layout remains an explicit action starting new shells/commands; it never pretends to attach a live session and never runs automatically on startup.

Permission denial, quarantine, read-only install, unavailable process inspection, and helper launch failure surface actionable errors. No automatic privilege escalation, OS setting changes, Full Disk Access, or Accessibility permission request is part of P0; normal own-app controls need no external-app automation permission. Future login-registration errors cannot be described as a current P0 prerequisite. Offline retry never masks inability to start the host.

Upgrade must handshake with the existing host version. Keep a compatible live host running until sessions end or the user explicitly terminates them. Do not replace/restart it automatically to match the new GUI. Incompatible upgrades expose a safe compatibility path and explain why attachment is unavailable; never replay shells in a new host as recovery. Uninstall and rollback must distinguish removing GUI files from terminating live sessions/helper registration.

## Resource and performance gates

Existing hard constraints are evidence, not new promises:

| Existing constraint | Evidence | P0 treatment |
| --- | --- | --- |
| 32 tab capacity | `MAX_TABS`, `src/app/session.odin:16` | Preserve GUI capacity; host/session cap needs explicit policy. |
| 32 pane nodes, hence at most 16 leaves | `src/app/pane.odin:24` | Preserve bounded topology until separately approved. |
| Minimum 10 columns, 2 rows | `src/app/pane.odin:25` | Preserve split validation and resize failure shape. |
| Worker input queue capacity 1024 | `UI_EVENT_QUEUE_CAP`, `src/app/backend.odin:34` | Preserve bounded acceptance semantics, not arbitrary buffering. |
| Default scrollback 1000 lines | `src/config/config.odin:132` | Preserve configurable default; aggregate host memory remains separately bounded. |
| Graphics 256 images, 64 frames, 64 MiB per image | `src/graphics/store.odin:7` | Preserve parser limits; add aggregate host/IPC memory accounting. |

Proposed transport budgets: maximum 1 MiB wire chunk/message; per-peer control queue at most 1024 requests and 4 MiB queued bytes; independent bounded bulk-transfer credits; history page at most 256 rows; initially two clients (one GUI and one monitor). A 64 MiB permitted image is streamed in chunks, not rejected by a new lower image limit. Oversized input uses documented chunking or visible rejection, never silent truncation. Validate proposals and record adjustments.

Routine metadata is event-driven. Process/job observations sample at most once every 2 seconds with cache and source freshness. State becomes stale at 5 seconds without refresh or immediately on disconnect; suspend/wake forces a refresh. Stale state disables stop actions. No continuously sampled CPU metrics or GUI/GPU redraw loop is added.

Named blockers B1–B7 must be closed before prototype GO: B1 total live-workspace/pane and aggregate graphics/scrollback/memory caps (including queues and client mirrors); B2 bulk-transfer byte credits and full-snapshot assembly ceiling; B3 lease reservation/liveness and idle-host deadlines; B4 deduplication horizon/result-cache limits and uncertain-result expiry policy; B5 counted-write scheduling and parser-reply worst-case expansion proof; B6 validated per-platform process census/termination/completion algorithm, root-exit-with-background-job E2E proof and join bounds; B7 endpoint path/peer APIs and safe helper spawn/environment/linkage proof. Each needs numeric policy/algorithm, measured rationale, and fault test. These are disclosed experiments, not unspecified freedom to ship.

Proposed clipboard-read deadline is 1 second. Preserve default OSC52 reads disabled. Authorized opt-in reads use an async correlated request; timeout returns an empty protocol response and diagnostic without blocking the parser. Attached clipboard writes reach only the authorized GUI; detached requests deny safely and never defer a write until future attachment.

Proposed release budgets on the same hardware/warmup/workloads: p95 input-to-photon increase no greater than max(1 ms, 10% baseline); p99 no greater than max(2 ms, 20% baseline); sustained PTY throughput at least 95% baseline; no silent byte drops. Measure 1/4/16 panes and record p50/p95/p99/p99.9, burst throughput, CPU/wakeups, snapshot bandwidth, and summed GUI/host/monitor RSS including steady allocations. Validate these budgets and report any requested change before GO.

Measure graphics payloads, large history, idle observation cost, attached versus detached, and slow consumers. Existing UI staging/idle-allocation concerns are baseline unknowns, not a claimed fix. Preserve ongoing blur/opacity and resize-profiling work. A fidelity-correct but unbounded or budget-failing prototype requires redesign, not partial release.

Metadata is event-driven and coalesced; process inspection may need bounded sampling. With no GUI, there is no SDL window, Metal layer, GPU submission, or GUI frame loop. Host parsing continues within existing terminal retention limits. A slow monitor cannot force full-terminal snapshots or wake the GUI. Every thread, socket, native object, subscription, clipboard request, chunk assembly, and temporary allocation has deterministic release.

## Failure matrix

| Failure | Required result | Evidence / test |
| --- | --- | --- |
| Host offline | Stale/offline state, disabled destructive actions | T8, T9 |
| Duplicate host launch | Single authoritative host and no duplicated readers | T9 |
| Wrong user/invalid peer | Reject before any session enumeration/mutation | T9 |
| Oversized/malformed message | Reject boundedly; no large pre-validation allocation | T9 |
| Protocol mismatch | Explain incompatibility; keep running jobs | T10 |
| Delta gap | Preserve last good frame, request full snapshot | T3 |
| Partial snapshot/image | Never publish half-decoded replacement | T3 |
| Slow/disconnected GUI | Release lease, preserve host output, bounded queues | T3, T5 |
| Paste/input acknowledgment lost | No automatic duplicate replay | T4 |
| Partial PTY write/EAGAIN | Retain exact offset, resumable delivery without duplicate prefix | T4, T9 |
| Parser response pressure/concurrent queries | Ordered bounded replies to originating PTY, no loss | T3, T9 |
| Split spawn/limit failure | Original topology intact; cleanup allocated resources | T2 |
| Attach capacity/launch failure | Original session remains detached | T7 |
| Detach rejection | Original visible tab remains; no process loss | T7 |
| Target disappears/restarts | Reject generation/identity; never retarget | T7 |
| Busy/Unknown close | Scope-specific confirmation | T4 |
| Bulk close scope changes | Revalidate captured set; do not extend silently | T4 |
| Process query failure | Unknown and freshness shown, never fake CPU0/Idle | T8 |
| Clipboard requested while detached | Safe unavailable response, no monitor access | T4 |
| Host crash/reboot | Lost/unavailable explanation, no survival/replay claim | T9 |
| On-demand helper launch denied/failed | Explain and preserve already running host/jobs | T11 |
| Upgrade incompatibility | Keep old host/jobs; safe explicit next steps | T10 |
| Worker shutdown exceeds bound | Report incomplete stop; no false success | T4, T9 |

## Work packages, touched surfaces, and proposed symbols

Proposed signatures below are design sketches for review, not compiled Odin declarations or verified line references. Actual package/import shapes require the extraction prototype. No planned symbol receives a fictional source line.

| Work | Existing surfaces | Planned destination / conceptual signature [new] | Dependency |
| --- | --- | --- | --- |
| W1 Contract/model | `docs/architecture.md`, `docs/user-guide.md`, `src/app/pane.odin`, `src/app/backend.odin` | `src/session_runtime/model.odin`: HostGeneration/WorkspaceID/PaneID/PaneIncarnation/ViewerID/Topology/Observation | Approval, drift reconciliation. |
| W2 Common actions/map | `src/ui/shortcuts.odin`, `src/config/config.odin`, config loader/tests, `src/app/main.odin`, `src/app/pane_manager.odin` | `src/app/commands.odin`: `dispatch_command(AppClient, CommandTarget, Action) -> CommandResult`; command-map/preset and migration-state records [new] | W1, exact-routing migration. |
| W3 Runtime/host/input extraction | `src/app/backend.odin`, terminal/parser/graphics/PTY, `src/platform/input`, `src/interaction`, app/MCP input consumers | Runtime `create_pane(SpawnContext) -> PaneResult`; host `host_run(HostConfig) -> ExitResult`; `src/input_core/types.odin` / `encoding.odin` and semantic cursor/style types [new] | W1; portable encoding parity and no SDL/window/render linkage gate. |
| W4 Process/close/write | `src/platform/pty/pty.odin`, `src/session_core/session.odin`, confirmation UI | `src/session_runtime/process.odin`: `observe_activity(PaneID) -> Observation`; `close_targets(TargetSet, Confirmation) -> CloseResult`; counted write adapter `write_some(Pty, Bytes) -> (bytes_written, error)` [new] | W1, scoped signal/backpressure policy. |
| W5 IPC/client | `src/app/session.odin`, `src/app/main.odin`, input/window lifecycle | `src/session_ipc/protocol.odin`: `decode_message(Bytes, Limits) -> MessageResult`; `src/app/host_client.odin`: `attach_session(Identity) -> AttachResult` | W3, wire/resource approval. |
| W6 Native UX/localization | tab/pane menus, search, input routing, native bridge, `src/i18n/i18n.odin`, `src/i18n/strings_en.odin`, `src/i18n/strings_id.odin` | `src/platform/window/macos_commands.odin`: `dispatch_native_action(ActionID, Target)`; common pane actions and shared English/Indonesian keys [new] | W2, W4, W5. |
| W7 Helper lifecycle | `Makefile`, `assets/Info.plist`, bundle scripts, Darwin bridges | `src/platform/services/macos.odin`: `ensure_host(LaunchContext) -> ServiceResult`; helper metadata [new] under `assets`; POSIX host launcher [new] | Deployment/safe on-demand spawn proof; no registration. |
| W8 Menu monitor | session metadata/switcher reuse where appropriate | `src/cmd/term_monitor/main.odin`: `monitor_run(MonitorConfig) -> ExitResult`; native status-item bridge [new] | W5, W7. |
| W5a Consumer adaptation | `src/app/persistence.odin`, `src/app/macos_services.m`, shell/config spawn helpers, title/metadata consumers | Host descriptor/save/restore and explicit caller-cwd adapters [new] | W3, W5; preserve explicit action semantics. |
| W9 Verification/rollout | existing app/core/PTY/input tests, benchmark probes | Host/IPC/monitor tests and dedicated E2E harness [new] | All prior packages. |

Blast radius includes GUI lifecycle, parser publication, graphics/scrollback serialization, clipboard callbacks, session switcher, headless/MCP reuse, Linux compilation, bundle metadata, native menus, and installer behavior. Reuse existing divider, focus, split validation, worker queue, publication, and pane renderer logic instead of introducing parallel controllers. Current split/clipboard/publication fixes are invariants to retain.

## Milestones with stop conditions

M1 — record the approved contract and operational policies. Deliver decision ledger, approved architecture variant, deployment reconciliation, command-map/migration specification, measured baseline plan, and process-scope limitations. Resource blockers may remain named for M2 experiments but cannot remain unnamed. Stop if any destructive/lifetime/compatibility decision is implicit.

M2 — implement extraction and host/IPC prototype; close B1–B7. Deliver one-reader ownership, complete serialization, full-before-delta reconnect, counted input writes, bounded ordered parser replies, native-free host runtime, and measured baseline comparison. Stop if styles/graphemes/graphics/modes are lost, clipboard blocks parsers, bytes are dropped/replayed, memory is unbounded, pointers cross the wire, or performance budgets fail.

M3 — integrate the GUI client and lifecycle intents. Deliver host-backed session creation from the start, separate Close Window/Quit/Terminate commands, explicit lease release, preserved shell environment, clipboard authorization, and exact input delivery. Stop if GUI teardown kills host PTYs, lease recovery duplicates ownership, or MCP/Linux shape regresses.

M4 — whole-tab detach/attach and close. Deliver acknowledged last-detach GUI-window closure with no replacement shell, host/monitor independence, confirmed red-close/reopen/review behavior, one-tab-only Cmd+Shift+W, scoped close confirmation, and preserved output/layout. Implement the approved final-explicit-close empty-view policy and verify it independently from last-detach window closure. Stop if detach downgrades capabilities, closes before acknowledgment, destroys jobs, or attach rejection loses a session.

M5 — native actions and monitor/package. Deliver command-map/migration/reload correctness, menus/shortcuts, accessible new controls, independent NSStatusItem process, exact-session launch, full-registry truthful counts, complete bundle/helpers, and on-demand startup with login registration off. Stop if shortcuts dispatch twice, helper failure kills jobs, linkage includes GUI/GPU in host, or monitor needs the GUI frame loop.

M6 — regression, rollout, and completion. Deliver tests/measurements on the supported installed bundle, compatibility behavior, live-job-preserving rollback instructions, migration notice, updated documentation, and drift audit. Do not call P0 complete with pending required checks or mismatched approved contracts.

## Tests and acceptance evidence

Tests exercise the production command/runtime shape with replaceable PTY/transport/clock dependencies, rather than duplicating implementation logic. Real-process E2E checks are mandatory for lifetime claims.

| Test ID | Required check | Evidence expected |
| --- | --- | --- |
| T1 | Exact modifiers; menu/SDL once; repeat suppression; Native/Legacy migration/overrides/conflicting reload and map-derived labels | Command trace and configuration/state assertions. |
| T2 | Split/collapse/resize/equalize/spatial focus nested layouts, no neighbor, zoom, divider priority | Existing pane tests extended through dispatcher. |
| T3 | Full/delta snapshots: style/color/grapheme/graphics/alt-screen/scrollback, gap recovery, slow consumer | Wire schema tests plus rendered-state comparison. |
| T4 | Close cancel/scoped signals/stopped jobs/root-exit with background work; StopAll barrier/partial stop; clipboard timeout; partial writes | Target/PID/incarnation/byte/resource assertions; no false completion. |
| T5 | Four-pane last-tab detach destroys GUI window after ack, releases SDL/Metal/frame loop, verifies GUI PID lifecycle, no replacement shell/window; Quit/red close preserve jobs; reopen/reattach | Installed-app window/resource/GUI PID outcome and stable host/monitor/job PIDs/output/ratios/focus/history. |
| T6 | Last-detach no empty view; Cmd+Shift+W one tab only; approved final-explicit-close view; reopen chooser; menus/focus/i18n/accessibility | Target/window/localization assertions and manual accessibility report. |
| T7 | Attach/detach rejection, capacity limit, launch failure, generation mismatch, target race | Rollback/ownership assertions. |
| T8 | Monitor survives Quit; root-exit/background-job and Uncertain counts; stale/suspend; completion/review/pins/ReviewUnavailable | Process/menu/budget evidence; no CPU placeholder on any touched surface. |
| T9 | Invalid peers/messages, duplicate launches, disconnect/crash, bounds, timeouts | Fault injection and bounded-resource evidence. |
| T10 | Compatible/incompatible upgrade and rollback preserve jobs without command replay | PID continuity and version-handshake evidence. |
| T11 | Clean/moved bundle, helper launch denial, dev launch, environment, login off, independent helper parentage | Installed artifact process/linkage test report. |
| T12 | Baseline latency/throughput/RSS/idle; no GUI/GPU work while GUI absent | Reproducible workload and agreed-budget comparison. |
| T13 | Linux/core/MCP behavior unchanged in shape | Existing compile and regression suite results. |
| T14 | Save/explicit restore, Open Term Here caller cwd, shell env/mode, escaped labels/paths | Coherent descriptor and explicit-spawn assertions. |
| T15 | Two-pane parser replies/theme OSC colors, physical DPI resize, synchronized output timeout, Unicode/graphics/TUI | Cross-PTY isolation and current rendering/protocol parity evidence. |

Existing relevant tests include `test_pane_production_split_resize_focus_and_zoom` (`src/app/tests/pane_dispatch_test.odin:65`), `test_pane_focused_key_dispatch_and_pointer_scale` (`src/app/tests/pane_dispatch_test.odin:113`), `test_app_pending_clipboard_preserves_complete_payload` (`src/app/tests/app_test.odin:115`), and `test_backend_paste_shadow_worker_routing` (`src/app/tests/app_test.odin:752`). Preserve pane GPU/publication suites in `src/app/tests/pane_present_test.odin` and `src/app/tests/backend_publication_test.odin`; new IPC tests must cover the same publication invariants rather than replace them with text-only assertions.

Specific publication references: `test_app_pane_present_reaches_gpu_and_releases_borrowed_snapshots` at `src/app/tests/pane_present_test.odin:214`; `test_backend_publication_notifies_after_unlock` at `src/app/tests/backend_publication_test.odin:27`; `test_backend_locked_publication_does_not_notify` at `src/app/tests/backend_publication_test.odin:49`. Retain synchronized-output behavior and verified 100 ms timeout (`APP_SYNC_OUTPUT_TIMEOUT_NS`, `src/app/contract.odin:64`); test timeout/publication parity without claiming measurements now. Linux real-process checks must be labeled separately from cross-compilation. MCP protocol/performance checks remain isolated from GUI host/client experiments.

Existing commands: `make check`, `make check-linux`, `make test`, `make test-app`, `make test-input`, `make test-tabs`, `make test-ui`, `make test-render`, `make test-pty`, `make test-session-core`, `make test-mcp`, `make build-mcp`, and `make bundle`. They exist in Makefile and require the documented toolchain/platform; none has been run for this document-only task. Add proposed `test-session-host`, `test-session-ipc`, `test-monitor`, `test-native-multiplexer-e2e`, and `bench-session-ipc` targets [new] with documented dependencies, supported environments, and exit status semantics.

## Rollout, rollback, and specification completion

Experimental host-backed mode is a development gate only. Full P0 release is host-backed, with no second production runtime or silent legacy-lifetime fallback. Existing sessions in the old binary cannot be live-migrated by copying raw pointers; preserve old jobs through the compatible old client/host path or require explicit user-approved shutdown before adoption. GUI migration must state the old sessions' lifetime rather than promising retroactive survival.

Rollback keeps a compatible host and monitor available for live sessions; reverting the GUI alone must not restart the host. If attachment compatibility cannot be maintained, provide the tested compatible client path and explicit terminate option. Never “recover” by launching replacement shells or resetting topology. Stop/remove helpers only after no live jobs remain or explicit user termination.

Before completion reconcile: architecture in-process zero-copy versus new IPC variant; singleton-only versus whole-tab detach; background-dies-with-app versus host lifetime; GUI worker/clipboard/publication contracts; user-guide cwd mismatch; actual deployment minimum versus plist; all shortcut labels and bulk-close descriptions; monitor count/activity terminology; helper install/uninstall/upgrade instructions; and known crash/reboot/process-observation limitations.

Final evidence maps I1–I6 to work/tests above, records actual command results and measurements, names remaining limitations, and verifies approved specifications agree with implementation. Document review alone cannot close implementation acceptance. This plan records blockers rather than concealing them.
