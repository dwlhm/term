# Term User Guide

Welcome to the **Term User Guide**. This manual details the operational mechanics, interaction paradigms, window and tab workflows, session persistence architecture, keyboard shortcuts, mouse gestures, search functionality, and modern terminal protocol integration of Term.

Term is a keyboard-first, native macOS terminal emulator engineered from first principles in [Odin](https://odin-lang.org) on top of Apple Metal and Cocoa AppKit. It is designed to combine low-latency typing, fluid animations, robust session persistence, and deep macOS integration into an ergonomic daily driver.

---

## Table of Contents

1. [Window & Tab Management](#window--tab-management)
   - [Creating and Closing Tabs](#creating-and-closing-tabs)
   - [Closing Other Tabs & Tabs to the Right](#closing-other-tabs--tabs-to-the-right)
   - [Inline Tab Renaming](#inline-tab-renaming)
   - [Tab Navigation & Direct Selection](#tab-navigation--direct-selection)
   - [Tab Overflow Dropdown](#tab-overflow-dropdown)
   - [Confirmation Dialog on Close](#confirmation-dialog-on-close)
2. [Session Detachment & Persistence](#session-detachment--persistence)
   - [The Persistence Architecture](#the-persistence-architecture)
   - [Detaching Tabs (`Alt+Cmd+B`)](#detaching-tabs-altcmdb)
   - [Headless Virtual Grid Drain Loop](#headless-virtual-grid-drain-loop)
   - [Window Usability Preservation](#window-usability-preservation)
3. [Session Switcher & Quick Palette (`Cmd+O`)](#session-switcher--quick-palette-cmdo)
   - [Invoking the Quick Palette](#invoking-the-quick-palette)
   - [Fuzzy Subsequence Matching](#fuzzy-subsequence-matching)
   - [Live Process Telemetry (PID, RSS, CPU)](#live-process-telemetry-pid-rss-cpu)
   - [Palette Actions & Keyboard Navigation](#palette-actions--keyboard-navigation)
4. [In-Terminal Search Overlay (`Cmd+F`)](#in-terminal-search-overlay-cmdf)
   - [Activating Live Search](#activating-live-search)
   - [Match Highlighting & Scrollback Traversal](#match-highlighting--scrollback-traversal)
   - [Search Shortcuts & Dismissal](#search-shortcuts--dismissal)
5. [Mouse Interactions & Selection Modes](#mouse-interactions--selection-modes)
   - [Selection Paradigms (Char, Word, Line, Block)](#selection-paradigms-char-word-line-block)
   - [Option + Drag Rectangular Block Selection](#option--drag-rectangular-block-selection)
   - [Clipboard Operations (Copy & Paste)](#clipboard-operations-copy--paste)
   - [Clickable Hyperlinks & OSC 8 Integration](#clickable-hyperlinks--osc-8-integration)
   - [Alternate Screen Mode Mouse Routing](#alternate-screen-mode-mouse-routing)
6. [Modern Protocols & Shell Integration](#modern-protocols--shell-integration)
   - [Kitty Keyboard Protocol](#kitty-keyboard-protocol)
   - [OSC 133 Semantic Prompt Integration](#osc-133-semantic-prompt-integration)
   - [Bracketed Paste Mode](#bracketed-paste-mode)
   - [Synchronized Output (CSI ? 2026 h/l)](#synchronized-output-csi--2026-hl)
   - [Fish Shell Compatibility Sequences](#fish-shell-compatibility-sequences)
7. [Comprehensive Keyboard Shortcuts Reference](#comprehensive-keyboard-shortcuts-reference)

---

## Window & Tab Management

Term provides a responsive tab bar with smooth linear animations, inline title editing, and safety guardrails against accidental command termination.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ [ 1: zsh ⌘1 ]  [ 2: htop ⌘2 ]  [ 3: nvim ⌘3 ]   ...   [ + ⌘T ] [ ✕ ⌘D ] [ ▼ ⇧⌘\ ]│
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                          Active Terminal Viewport                                │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Creating and Closing Tabs

- **New Tab (`⌘T` / `Cmd+T`)**: Spawns a new interactive shell session according to your configuration (or system default `$SHELL`), using the configured initial working directory.
- **Close Tab (`⌘D` / `Cmd+D`)**: Closes the currently active tab. If an active foreground process is executing inside the tab's PTY, Term intercepts the action and presents an in-app confirmation card to prevent accidental data loss.

### Closing Other Tabs & Tabs to the Right

When multitasking with numerous workspaces, Term allows batch cleanup:
- **Close Others (`⌥⌘D` / `Option+Cmd+D`)**: Closes all tabs except the currently selected tab. Any tab running an active child process triggers a confirmation check before closing.
- **Close Tabs to the Right (`⌥⇧⌘D` / `Option+Shift+Cmd+D`)**: Closes all tabs positioned to the right of the current tab index.

### Inline Tab Renaming

- **Rename Tab (`⌘R` / `Cmd+R`)**: Activates an inline text editor directly on the active tab label in the tab bar.
  - Type the desired custom title.
  - Press **`Enter` (`⏎`)** to commit the new title.
  - Press **`Escape` (`esc`)** to discard changes and retain the existing title.
  - If dynamic title reporting (e.g. `OSC 0` or `OSC 2`) is emitted by a running shell program, manually renaming the tab overrides automatic title tracking.

### Tab Navigation & Direct Selection

Switching between active tabs is instant and flicker-free:
- **Direct Tab Selection (`⌘1` through `⌘8`)**: Switches directly to the tab at physical positions 1 through 8.
- **Last Tab Selection (`⌘9`)**: Switches directly to the **last** open tab, regardless of total tab count.
- **Sequential Cycling**:
  - **Next Tab (`^⇥` / `Ctrl+Tab`)**: Cycles to the next tab in circular order ($i \to (i + 1) \pmod N$).
  - **Previous Tab (`^⇧⇥` / `Ctrl+Shift+Tab`)**: Cycles to the previous tab in circular order ($i \to (i - 1 + N) \pmod N$).

### Tab Overflow Dropdown

When the number of open tabs exceeds the horizontal width of the window, Term automatically compresses tab widths down to a readable minimum and exposes the tab overflow menu.

- **Open Overflow Menu (`⇧⌘\` / `Shift+Cmd+\`)**: Opens a floating dropdown menu anchored to the tab bar's trailing edge, listing all active tabs with their indices and titles.
- **Mouse Activation**: Click the down-chevron button (`▼`) located at the right side of the tab bar.
- **Navigation**: Use the **`Up`** and **`Down`** arrow keys to highlight an item, and press **`Enter`** to switch to it, or press **`Escape`** to dismiss the dropdown.

### Confirmation Dialog on Close

Term features an integrated modal confirmation dialog (`Confirm_Dialog_State`) rendered directly on top of the terminal viewport:

```
┌──────────────────────────────────────────────┐
│  Close tab with running process?             │
│                                              │
│  The process running in this tab will be     │
│  terminated.                                 │
│                                              │
│             [ Cancel (Esc) ]  [ Close (Enter) ]│
└──────────────────────────────────────────────┘
```

- **Trigger Condition**: When closing a tab via `⌘D`, tab bar close buttons, or batch closing actions, Term inspects the tab's PTY master handle via `pty_has_running_processes`. If a non-shell child process or active worker is detected, the dialog appears.
- **Keyboard Handling**:
  - **`Enter`** or **`y` / `Y`**: Confirms termination. Sends `SIGHUP` / `SIGTERM` to the process tree and closes the tab.
  - **`Escape`** or **`n` / `N`**: Cancels the close request; the tab remains open and undisturbed.
- **Mouse Handling**: Click the **Close** or **Cancel** button directly.

> [!TIP]
> If you wish to close a tab window while keeping a long-running process (e.g., a local server, compiler, or background watcher) alive without interruption, use **Session Detachment** (`⌥⌘B`) instead of closing the tab!

---

## Session Detachment & Persistence

Term features a native session persistence subsystem built into `src/session_core/session.odin` and `src/app/session.odin`. This enables decoupling terminal processes from the visual GUI tab chrome.

### The Persistence Architecture

Traditional terminal emulators tie the lifecycle of a child process directly to the GUI window or tab view. Closing a tab typically sends a hangup signal (`SIGHUP`) to the process group, killing background jobs.

In Term, sessions can transition seamlessly between two operational states:
1. **Interactive Tab (`Backend`)**: Attached to a GUI tab, receiving GPU command buffer updates, layout passes, and active keyboard/mouse events.
2. **Persistent Core Session (`Core_Session`)**: Detached from GUI chrome and stored in the thread-safe global `Session_Registry`.

```
                    ┌───────────────────────────┐
                    │     Interactive Tab       │
                    │   (Metal GPU Rendering)   │
                    └─────────────┬─────────────┘
                                  │
                       ⌥⌘B (Detach)  ⌘O (Attach)
                                  │
                                  ▼
                    ┌───────────────────────────┐
                    │    Persistent Session     │
                    │   (Headless Drain Loop)   │
                    └───────────────────────────┘
```

### Detaching Tabs (`Alt+Cmd+B`)

Pressing **`⌥⌘B` (`Alt+Cmd+B`)** performs an instantaneous atomic detachment of the current active tab:
- **No SIGHUP**: The PTY master file descriptor, child process PID, virtual grid, scrollback ring, and escape state machine remain fully alive.
- **Thread Safety**: Any background PTY reader threads are safely coordinated, preserving byte streams without race conditions.
- **Preserved State**: Full scrollback history, cursor positions, DEC private modes, and active terminal styles are preserved verbatim in memory.

### Headless Virtual Grid Drain Loop

When a session is detached, Term starts an autonomous background drain loop (`session_start_drain_loop`):
- **Zero UI Overhead**: The drain loop consumes PTY output continuously without invoking Cocoa AppKit, SDL, or Metal GPU command encoding.
- **Headless Terminal Updates**: Bytes are parsed by the VT state machine, updating the virtual cell grid and scrollback ring in-memory.
- **Backpressure Prevention**: Because the background loop drains the PTY continuously, child processes producing heavy output never block or stall on an unread PTY pipe buffer.

### Window Usability Preservation

If you detach the **last remaining tab** in the window, Term does not close the window. Instead, it detects that `len(tabs) == 0` and automatically spawns a fresh default shell tab in place. This guarantees that your terminal window remains active, focused, and immediately available for new tasks.

---

## Session Switcher & Quick Palette (`Cmd+O`)

The Session Switcher (`Cmd+O`) shows open tabs and in-app background sessions.
Each row displays its title, working directory, and current/open/background/exited status.

### Invoking the Quick Palette

Press **`⌘O` (`Cmd+O`)** anywhere in Term to open or close the modal palette. The palette floats centered near the top of the window, elevated over the terminal viewport.

### Fuzzy Subsequence Matching

As you type into the search bar, Term filters open tabs and detached sessions in real-time using a scoring algorithm (`session_switcher_fuzzy_match`):
- **Subsequence Search**: Typing `nvim` matches `[Tab 3] nvim`, `edit-nvim`, or paths containing those characters.
- **Bonus Scoring**: Additional weighting is granted for:
  - Exact prefix matches (+25 points).
  - Matches occurring immediately after word boundary delimiters (`/`, `_`, `-`, ` `, `.`, `:`) (+15 points).
  - Consecutive character matches (+20 points).

### Palette Actions & Keyboard Navigation

| Keystroke | Action | Description |
|---|---|---|
| **`Up` (`↑`)** | Navigate Up | Moves the selection highlight to the preceding result. |
| **`Down` (`↓`)** | Navigate Down | Moves the selection highlight to the next result. |
| **`Enter` (`⏎`)** | Activate / Attach | If selecting an **active tab**, switches focus to it. If selecting a **detached session**, re-attaches it into the GUI tab bar. |
| **`⌥⌘B` (`Alt+Cmd+B`)** | Detach Session | Immediately detaches the highlighted active tab into the background registry. |
| **`⌘X` / `^X`** | Terminate Session | Opens confirmation before closing the highlighted tab or terminating a background session. |
| **`Backspace`** | Delete Character | Deletes the trailing character from the active search query. |
| **`Escape` (`esc`)** | Close Palette | Dismisses the quick palette and returns keyboard focus to the active terminal. |

---

## In-Terminal Search Overlay (`Cmd+F`)

Term features a high-performance in-terminal search engine that scans across both the active visible grid and historical scrollback buffers.

```
┌────────────────────────────────────────────────────────────────────────┐
│ [Search: error                    ]  [ 3 of 42 matches ]  [ Prev ] [ Next ]│
└────────────────────────────────────────────────────────────────────────┘
```

### Activating Live Search

Press **`⌘F` (`Cmd+F`)** to reveal the floating search bar. Keyboard input is immediately captured into the search query buffer without leaking characters to the running shell or application.

### Match Highlighting & Scrollback Traversal

- **Real-Time Live Matches**: As characters are entered, Term scans the terminal's visible grid and circular scrollback ring, highlighting up to **256 simultaneous matches** (`MAX_SEARCH_MATCHES :: 256`).
- **Visual Contrast**: Matching substrings are highlighted with high-contrast accent backgrounds. The currently focused match is rendered with distinct primary styling.
- **Viewport Tracking (`Scroll_To_Match`)**: Navigating matches automatically adjusts the viewport scrollback offset (`terminal_view_set_offset`), scrolling historical lines into view smoothly.

### Search Shortcuts & Dismissal

| Shortcut | Action | Behavior |
|---|---|---|
| **`Enter` (`⏎`)** or **`n`** | `Search_Next` | Cycles focus forward to the next match in the buffer. |
| **`Shift+Enter` (`⇧⏎`)** or **`N`** | `Search_Prev` | Cycles focus backward to the previous match. |
| **`Escape` (`esc`)** | `Search_Close` | Exits search mode, dismisses the overlay, clears highlights, and restores the viewport to the live prompt. |

> [!NOTE]
> Search mode is completely isolated from the PTY. Even if a background process continues emitting output while the search overlay is active, the search viewport remains locked until dismissed or resumed.

---

## Mouse Interactions & Selection Modes

Term provides precision mouse handling, full text selection semantics, OS clipboard synchronization, and URL detection.

### Selection Paradigms (Char, Word, Line, Block)

Term supports standard multi-click selection hierarchies:
1. **Character Selection (Click & Drag)**:
   - Click the left mouse button at an initial character and drag across cells.
   - Text is highlighted continuously along reading order across soft-wrapped lines.
2. **Word Selection (Double-Click)**:
   - Double-clicking (`clicks == 2`) identifies word boundaries (`interaction_select_word_bounds`), selecting alphanumeric tokens and programming identifiers.
3. **Line Selection (Triple-Click)**:
   - Triple-clicking (`clicks >= 3`) selects the entire logical row (`interaction_select_line_bounds`), spanning the full terminal width.

### Option + Drag Rectangular Block Selection

When working with tabular output, columnar data, or code matrices, Term supports column-oriented **Rectangular Block Selection**:
- **Trigger**: Hold the **`Option` (`⌥`)** key while clicking and dragging with the primary mouse button (or press `Ctrl+V` while in keyboard visual mode).
- **Behavior**: The selection defines a geometric 2D rectangle bounded by `(min_col, min_row)` and `(max_col, max_row)`.
- **Extraction**: When copied, each row within the rectangle is extracted up to its last non-blank cell, and rows are joined with newline delimiters (`\n`), preserving column alignment perfectly.

```
       col 10         col 25
         │              │
row 4 ── ┌──────────────┐
         │ Column 1     │
         │ Column 2     │
row 8 ── └──────────────┘
```

### Clipboard Operations (Copy & Paste)

- **Copy (`⌘C` / `Cmd+C`)**: Extracts the currently highlighted selection (Char, Line, or Block) and copies the UTF-8 text directly to the native macOS system pasteboard. The clipboard bridge transfers the complete selection, including multi-line text; platform or application policies may still limit what can be stored.
- **Paste (`⌘V` / `Cmd+V`)**: Reads UTF-8 text from the macOS system pasteboard and writes it directly to the active tab's PTY.
  - If the active program has enabled **Bracketed Paste Mode**, the text is safely wrapped in control markers (`\x1b[200~` ... `\x1b[201~`).

### Clickable Hyperlinks & OSC 8 Integration

Term features comprehensive hyperlink detection and clickability:
1. **OSC 8 Explicit Hyperlinks**:
   - Terminal applications can emit standard OSC 8 escape sequences: `\x1b]8;id=xyz;https://example.com\x1b\Text\x1b]8;;\x1b\`.
   - Term tracks hyperlink IDs in its internal `Hyperlink_Store`, styling hyperlinks with subtle visual cues.
2. **Implicit URL & Path Detection**:
   - Web URLs beginning with `http://`, `https://`, `file://`, or `mailto:`.
   - Filesystem paths beginning with `/`, `~/`, `./`, or `../` (including trailing line numbers such as `src/main.odin:124`).
3. **Activating Links (`⌘Click` / `Cmd+Click`)**:
   - Hold the **`Cmd` (`⌘`)** key and click with the left mouse button on any detected link or path.
   - Web URLs are dispatched immediately to your default macOS web browser via `sdl3.OpenURL`.
   - Local file paths are opened via macOS `/usr/bin/open`, launching the registered editor or file viewer.

### Alternate Screen Mode Mouse Routing

When running full-screen interactive TUI applications (such as `vim`, `nvim`, `tmux`, `htop`, or `less`) that use the alternate screen buffer and mouse tracking modes:
- **Application Priority**: Raw mouse clicks, motions, and wheel scrolls are encoded using SGR 1006 mouse protocol and delivered straight to the child program.
- **Shift Override**: To perform a local Term text selection inside a TUI application without triggering the application's internal mouse handler, hold the **`Shift` (`⇧`)** key while dragging.

---

## Modern Protocols & Shell Integration

Term implements modern terminal protocol standards, providing seamless compatibility with contemporary shells (Zsh, Fish, Bash) and developer tooling.

### Kitty Keyboard Protocol

Term includes full support for the **Kitty Keyboard Protocol** (`CSI ? u`), enabling rich keyboard events previously impossible in legacy terminal emulators:
- **Disambiguation**: Distinguishes between keys like `Tab` and `Ctrl+I`, `Enter` and `Ctrl+M`, or `Escape` and `Alt+[`.
- **Event Types**: Accurately reports key press (`1`), key repeat (`2`), and key release (`3`) events to supported applications.
- **Modifier Accuracy**: Reliably conveys `Shift`, `Alt`, `Ctrl`, `Super` (Cmd), `Hyper`, and `Caps Lock` state combinations.
- **State Push/Pop**: Implements the Kitty mode stack (`CSI > ... u` and `CSI < ... u`), allowing TUI applications to push temporary keyboard reporting configurations and pop them cleanly on exit.

### OSC 133 Semantic Prompt Integration

Term natively parses and tracks **OSC 133 semantic prompt annotations**, allowing the terminal emulator to understand shell lifecycle boundaries:

| Sequence | Name | Description |
|---|---|---|
| `\x1b]133;A\x07` | **Prompt Start** | Marks the beginning of the interactive shell prompt. |
| `\x1b]133;B\x07` | **Prompt End** | Marks the end of the prompt and the start of user command line input. |
| `\x1b]133;C\x07` | **Command Start** | Emitted when the user presses Enter and the command starts executing. |
| `\x1b]133;D;<code>\x07` | **Command End** | Emitted when the command completes, carrying the numeric process exit code. |

Benefits of OSC 133 in Term:
- **Clean Selection**: Prevents prompt icons and status lines from being accidentally mangled during multi-line code copy.
- **Autonomous MCP Execution**: The headless MCP server (`term-mcp`) uses OSC 133 markers to detect exact command completion boundaries with sub-millisecond precision without relying on heuristics or sleep timers.

### Bracketed Paste Mode

When enabled by the running shell or editor via `CSI ? 2004 h`, Term wraps pasted text in bracketed paste escape guards:
- Opening sequence: `\x1b[200~`
- Content: Raw pasted clipboard string
- Closing sequence: `\x1b[201~`

This prevents accidental execution of multi-line shell scripts, ensuring pasted commands are reviewed before submission.

### Synchronized Output (CSI ? 2026 h/l)

Term implements **DEC Mode 2026 (Synchronized Output)**:
- `\x1b[?2026h`: Begins synchronized update. Rendering presentation is held in the backbuffer.
- `\x1b[?2026l`: Ends synchronized update. Backbuffer is atomically committed to the Metal render pipeline.
- **Screen Tearing Elimination**: TUI applications redrawing large matrices or status lines present atomically in a single frame.
- **Safety Watchdog**: A bounded hardware timeout (`APP_SYNC_OUTPUT_TIMEOUT_NS`) prevents rogue or crashed processes from freezing terminal rendering indefinitely.

### Fish Shell Compatibility Sequences

Term provides explicit compatibility with advanced Fish shell rendering mechanisms:
- **SCO Cursor Position (`CSI s` and `CSI u`)**: SCO-style save (`\x1b[s`) and restore (`\x1b[u`) cursor positions, essential for Fish autosuggestions and right-side prompts (`RPROMPT`).
- **Cursor Next / Previous Line (`CSI E` and `CSI F`)**: Multi-row prompt navigation (`\x1b[E` move down $N$ rows and return to column 0; `\x1b[F` move up $N$ rows and return to column 0).
- **TrueColor Colon SGR Syntax**: Fully parses ISO/IEC 8613-6 colon-delimited colors (`\x1b[38:2::r:g:bm` and `\x1b[48:2::r:g:bm`).
- **Extended Underline Styles & Colors**: Supports curly (`\x1b[4:3m`), dotted (`\x1b[4:4m`), dashed (`\x1b[4:5m`), and colored underlines (`\x1b[58:2::r:g:bm`) for Fish syntax error highlighting.
- **XTGETTCAP & Device Attributes**: Accurately responds to terminal capability queries (`DCS + q ... ST`).

---

## Comprehensive Keyboard Shortcuts Reference

The following table provides the exhaustive mapping of all keyboard shortcuts defined in `src/ui/shortcuts.odin` and `src/app/main.odin`:

| Action Enum | macOS Key Combo | Keystroke String | Description |
|---|---|---|---|
| `New_Tab` | `⌘T` | `Cmd+T` | Spawns a new shell tab in the current window. |
| `Close_Tab` | `⌘D` | `Cmd+D` | Closes active tab (prompts if process running). |
| `Close_Others` | `⌥⌘D` | `Option+Cmd+D` | Closes all tabs except the active tab. |
| `Close_To_Right` | `⌥⇧⌘D` | `Option+Shift+Cmd+D` | Closes all tabs located to the right of active tab. |
| `Rename_Tab` | `⌘R` | `Cmd+R` | Begins inline tab title editing. |
| `Next_Tab` | `^⇥` | `Ctrl+Tab` | Cycles focus to the next tab. |
| `Prev_Tab` | `^⇧⇥` | `Ctrl+Shift+Tab` | Cycles focus to the previous tab. |
| `Detach_Tab` | `⌥⌘B` | `Alt+Cmd+B` | Detaches active tab into persistent background session. |
| `Attach_Session` | `⌘O` | `Cmd+O` | Opens the Quick Palette / Session Switcher. |
| `Search` | `⌘F` | `Cmd+F` | Opens the in-terminal search overlay. |
| `Search_Next` | `⏎` | `Enter` | Focuses next search match. |
| `Search_Prev` | `⇧⏎` | `Shift+Enter` | Focuses previous search match. |
| `Search_Close` | `esc` | `Escape` | Dismisses search overlay and restores viewport. |
| `Zoom_In` | `⌘+` / `⌘=` | `Cmd++` | Increases terminal font size by 1.0 pt. |
| `Zoom_Out` | `⌘-` | `Cmd+-` | Decreases terminal font size by 1.0 pt (min 6.0 pt). |
| `Window_Zoom` | `^⌘Z` | `Ctrl+Cmd+Z` | Toggles window maximization / full zoom. |
| `Reload_Config` | `⇧⌘R` | `Shift+Cmd+R` | Reloads configuration from disk dynamically. |
| `Overflow` | `⇧⌘\` | `Shift+Cmd+\` | Toggles the tab overflow dropdown menu. |
| `Confirm` | `⏎` | `Enter` | Confirms action in modal confirmation dialogs. |
| `Cancel` | `esc` | `Escape` | Cancels action in modal confirmation dialogs. |
| *Tab Direct* | `⌘1` .. `⌘8` | `Cmd+1` .. `Cmd+8` | Switches directly to tab index 1 through 8. |
| *Tab Last* | `⌘9` | `Cmd+9` | Switches directly to the last open tab. |
| *Copy* | `⌘C` | `Cmd+C` | Copies selected text to macOS system pasteboard. |
| *Paste* | `⌘V` | `Cmd+V` | Pastes clipboard text into active PTY. |
| *Open Link* | `⌘Click` | `Cmd+Left Click` | Opens clicked URL in browser or path in system editor. |
| *Block Select* | `⌥Drag` | `Option+Left Drag` | Performs rectangular 2D block text selection. |

## Split panes

The standard renderer supports multiple terminals within each tab. Each pane owns its shell and PTY. Click a pane to focus it; keyboard input, paste, drops, search, title, and the active cursor follow that focus. Hover a divider for a left/right or up/down resize cursor, then drag to resize its neighbors. The cursor keeps its direction throughout the drag and returns to normal elsewhere, while a pane is zoomed, or when modal chrome owns the pointer. A shell exit removes its pane and expands the remaining layout. Cmd+D closes the entire tab and checks every pane for running processes.

| Action | Shortcut |
| --- | --- |
| Split left/right | Cmd+\ |
| Split top/bottom | Alt+Cmd+\ |
| Previous / next pane | Cmd+[ / Cmd+] |
| Equalize panes | Alt+Cmd+= |
| Toggle focused pane zoom | Shift+Cmd+Return |
| Resize focused pane | Alt+Shift+Cmd+Arrow |
| Previous / next tab | Ctrl+Shift+Tab / Ctrl+Tab |
| Tab overflow | Shift+Cmd+\ |

These bindings require the exact modifiers and backslash key; pipe is not a split or overflow alias. Split rejects insufficient space, exhausted pane capacity, shell/worker startup failures, and the experimental single-terminal Pinnacle renderer with a diagnostic. Detach supports only a single embedded terminal; a split tab or a surviving separately allocated pane rejects detach without stopping its processes. Splitting clears pane zoom; changing pane focus while zoomed displays the newly focused pane. New split shells use the configured initial working directory.


### Background session interaction

Detach (`Option+Command+B`, or tab menu **Run in background**) transfers a single
terminal's PTY, parser, screen, scrollback, displayed title, rename override, and
working directory to the in-app session registry. Split tabs cannot detach; the
switcher explains the rejection. Detaching the last tab opens a replacement shell.
Processes continue and output is parsed while the application remains running.
Background sessions stop when the application exits; this is not restart persistence.

`Command+O`, the tab menu **Sessions**, or the background count badge opens the
session switcher. Search, arrow keys, wheel scrolling, and clicking a row select
or open sessions. The badge selects a background row. Enter attaches the selected
background session or focuses an open tab. Escape or an outside click dismisses.
The modal consumes terminal input, paste, and drops. Rows show title, directory,
and current/open/background/exited state. Exited background sessions retain output
for review after attachment. A full tab strip leaves an unsuccessful attachment
registered and running, with an inline explanation. `Command+X` requests termination
through confirmation; saved layout rows never offer termination.

The registry remains the authoritative lifecycle owner until an attached backend
starts successfully. Failure restores the background owner. Each PTY has one drain
worker; parser responses target that session's PTY, and background parsing releases
GUI clipboard callbacks. Switcher item buffers are presentation snapshots only.
