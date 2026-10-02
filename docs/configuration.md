# Term Configuration Guide

Term is configured via an elegant, declarative configuration format powered directly by the official [Odin](https://odin-lang.org) AST parser (`core:odin/parser`).

This document provides a comprehensive guide to configuration file discovery, syntax specifications, error reporting, an exhaustive property reference table, and a production-grade example configuration file.

---

## Table of Contents

1. [Configuration File Resolution](#configuration-file-resolution)
   - [Candidate Locations](#candidate-locations)
   - [Fallback Behavior & Safety](#fallback-behavior--safety)
   - [Syntax Error Diagnostics](#syntax-error-diagnostics)
2. [Configuration Syntax & Data Types](#configuration-syntax--data-types)
   - [Statement Formats](#statement-formats)
   - [Supported Data Types](#supported-data-types)
   - [Color Formats](#color-formats)
   - [Dynamic Reloading on the Fly (`⇧⌘R`)](#dynamic-reloading-on-the-fly-r)
3. [Exhaustive Property Reference Table](#exhaustive-property-reference-table)
   - [Window Geometry & Layout](#window-geometry--layout)
   - [Typography & Font Rendering](#typography--font-rendering)
   - [Shell & Working Directory](#shell--working-directory)
   - [Window Translucency & AppKit Blur](#window-translucency--appkit-blur)
   - [Cursor Appearance & Animation](#cursor-appearance--animation)
   - [Colors & Color Scheme](#colors--color-scheme)
   - [Scrollback & Wheel Behavior](#scrollback--wheel-behavior)
   - [Tab Bar Ergonomics](#tab-bar-ergonomics)
   - [ANSI 16 Palette Configuration](#ansi-16-palette-configuration)
4. [Production Example Configuration (`config.odin`)](#production-example-configuration-configodin)

---

## Configuration File Resolution

Term locates and parses its configuration file during startup and whenever a dynamic reload is triggered.

### Candidate Locations

Configuration candidate locations are checked in strict sequential order:

```
┌──────────────────────────────────────────────────────────────┐
│ 1. $TERM_CONFIG Environment Variable                         │
│    (Checked if defined, non-empty, and the file exists)      │
└──────────────────────────────┬───────────────────────────────┘
                               │ Not found
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. ~/.config/term/config.odin                                │
│    (Standard user configuration path)                        │
└──────────────────────────────┬───────────────────────────────┘
                               │ Not found
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Built-in Production Defaults (config_default())           │
└──────────────────────────────────────────────────────────────┘
```

1. **`$TERM_CONFIG`**: If the `TERM_CONFIG` environment variable is exported and points to an existing file path, Term loads configuration exclusively from that path. This is particularly useful for containerized workflows, dotfile management scripts, or testing distinct configurations.
2. **`~/.config/term/config.odin`**: If `$TERM_CONFIG` is unset or points to a non-existent file, Term resolves the standard user configuration file located in the user's home directory (`~/.config/term/config.odin`).

### Fallback Behavior & Safety

- **Missing Configuration File**: If neither candidate file is found, Term silently initializes with its built-in high-performance defaults (`config_default()`). No warnings or unnecessary error dialogs are emitted.
- **Fail-Safe Operation**: If a configuration file exists but cannot be read due to file permissions or I/O errors, Term logs a warning to `stderr` and falls back safely to default settings, ensuring the terminal always launches reliably.

### Syntax Error Diagnostics

Term wraps user configuration files inside an in-memory Odin procedure block and parses the source using `core:odin/parser`. If a syntax error is introduced into your configuration file:
- Term captures the exact parser error, line number, and column offset.
- A diagnostic message is formatted and printed to `stderr`:
  ```text
  [term] Config syntax error at /Users/username/.config/term/config.odin:14:5: expected '=', found identifier
  ```
- Rather than aborting or crashing, Term cleanly releases any partial allocations, logs the error, and falls back to safe default parameters.

---

## Configuration Syntax & Data Types

Term configurations are valid Odin assignments and declarations. You do not need to install the Odin compiler to edit your configuration; the AST parser is embedded directly within the Term binary.

### Statement Formats

Statements can use either standard assignment or Odin variable declaration syntax:

```odin
// Assignment statement
font_family = "Maple Mono NF"

// Declaration statement (also valid)
font_size := 14.0
```

Single-line comments (`//`) and multi-line comments (`/* ... */`) are supported throughout the configuration file.

### Supported Data Types

Term's AST parser dynamically converts Odin expressions into typed terminal settings:

| Data Type | Example Syntax | Accepted Representations |
|---|---|---|
| **String** | `font_family = "JetBrains Mono"` | Double-quoted strings (`"..."`) or raw backtick strings (`` `...` ``). |
| **Integer** | `cols = 120` | Positive or non-negative integers (`80`, `24`, `5000`). |
| **Float** | `font_size = 13.5` | Standard floating-point numbers (`13.0`, `1.5`, `0.90`). |
| **Boolean** | `cursor_blink = true` | Case-insensitive literals: `true`, `false`, `yes`, `no`, `1`, `0`. |
| **Color** | `background = 0xFF1E1E2E` | Hex color string (`"#1E1E2E"`), integer hex literal (`0x1E1E2E`), or unsigned 32-bit integer. |
| **Array** | `ansi16 = [16]u32{ ... }` | Odin composite literal containing 16 color values. |

### Color Formats

Colors are represented as 32-bit ARGB values. Term accommodates multiple common color notations:

1. **Hexadecimal String with `#`**:
   - 6-digit RGB: `"#1E1E2E"` (Alpha is automatically initialized to `0xFF`).
   - 8-digit ARGB: `"#801E1E2E"` (Includes explicit alpha transparency).
2. **Hexadecimal Numeric Literals**:
   - `0x1E1E2E` (Values $\le \text{0x00FFFFFF}$ automatically have full alpha `0xFF000000` applied).
   - `0xFF1E1E2E` (Explicit 32-bit ARGB integer).

### Dynamic Reloading on the Fly (`⇧⌘R`)

You do not need to restart Term to apply configuration changes:
- Save your edits to `~/.config/term/config.odin`.
- Press **`Shift+Cmd+R` (`⇧⌘R`)** in any active Term window.
- Term re-parses the file from disk, updates window dimensions, rebuilds typography shaders/metrics, updates vibrancy blur, and triggers an immediate redraw across all tabs without terminating running shell processes.

---

## Exhaustive Property Reference Table

The table below lists every configuration setting recognized by `src/config/parse.odin` and `src/config/config.odin`.

### Window Geometry & Layout

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `cols` | `int` | `80` | Initial viewport column width (in character cells). <br>Aliases: `window_cols` |
| `rows` | `int` | `24` | Initial viewport row height (in character cells). <br>Aliases: `window_rows` |
| `padding_x` | `int` | `6` | Horizontal padding in pixels between window borders and cell content. |
| `padding_y` | `int` | `4` | Vertical padding in pixels between window title/tab bar and cell content. |
| `title` | `string` | `"Term"` | Default window and application title displayed in the macOS window frame. |

### Typography & Font Rendering

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `font_family` | `string` | `"Maple Mono NF"` | Primary font family name parsed by HarfBuzz and FreeType. |
| `font_size` | `float` | `13.0` | Primary font size in points ($pt$). Clamped to a minimum of $6.0\text{ pt}$. |

### Shell & Working Directory

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `shell` | `string` | `""` | Path to executable shell binary. If left empty (`""`), Term queries `$SHELL` or defaults to `/bin/zsh` on macOS. |
| `working_directory` | `string` | `"~"` | Initial working directory for newly spawned tabs. Supports tilde expansion (`~`). <br>Aliases: `working_dir`, `cwd`, `initial_dir` |
| `locale` | `string` | `""` | Explicit locale override (e.g. `"en_US.UTF-8"`). Defaults to host environment locale. |

### Window Translucency & AppKit Blur

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `window_opacity` | `float` | `1.0` | Window alpha transparency, clamped between `0.1` (translucent) and `1.0` (opaque). <br>Aliases: `opacity` |
| `window_blur` | `bool` | `false` | Enables native macOS vibrancy blur behind the window. <br>Aliases: `blur` |

> [!NOTE]
> **Native Cocoa Vibrancy (`NSVisualEffectView`)**:
> When `window_blur` is set to `true` (or `window_opacity < 1.0`), Term dynamically attaches a native Apple AppKit `NSVisualEffectView` subview behind the Metal content layer. When `window_opacity = 1.0` and `window_blur = false`, the window runs in the **zero-overhead opaque path**: no `NSVisualEffectView` is allocated, conserving system resources.

### Cursor Appearance & Animation

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `cursor_blink` | `bool` | `true` | Controls whether the terminal cursor blinks when the window is focused. |
| `cursor_blink_interval_ms` | `int` | `530` | Duration of each cursor blink phase in milliseconds. |
| `cursor_color` | `color` | `0xFFFFFFFF` | Direct color override for the text cursor. |

### Colors & Color Scheme

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `theme_name` | `string` | `"Catppuccin Mocha"` | Built-in color theme name. Setting to `"Catppuccin Mocha"` or `"Catppuccin"` sets standard pastel palette colors. <br>Aliases: `theme` |
| `foreground` | `color` | `0xFFCDD6F4` | Default text foreground color. <br>Aliases: `fg` |
| `background` | `color` | `0xFF1E1E2E` | Default terminal background color. <br>Aliases: `bg` |
| `selection_foreground` | `color` | `0xFF1E1E2E` | Text color for highlighted selections. <br>Aliases: `selection_fg` |
| `selection_background` | `color` | `0xFF585B70` | Background highlight color for text selections. <br>Aliases: `selection_bg` |

### Scrollback & Wheel Behavior

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `scrollback_max_lines` | `int` | `1000` | Maximum number of historical lines stored in the circular ring buffer. |
| `alt_screen_wheel_lines` | `int` | `3` | Number of synthetic arrow key events generated per mouse wheel tick inside alternate screen mode (e.g., `less`, `vim`). |
| `scroll_multiplier` | `float` | `1.0` | Velocity scaling factor applied to high-resolution mouse wheel scrolling. |

### Tab Bar Ergonomics

| Property | Type | Default | Description & Aliases |
|---|---|---|---|
| `tab_max_title_len` | `int` | `16` | Maximum number of characters displayed in tab titles before applying truncation with ellipsis (`…`). <br>Aliases: `tab_title_max_len` |

### ANSI 16 Palette Configuration

The 16 standard ANSI colors can be defined either as a single composite array or by configuring individual color slots:

#### 1. Composite Array (`ansi16`)

You can assign all 16 colors in order (black, red, green, yellow, blue, magenta, cyan, white, followed by the 8 high-intensity counterparts):

```odin
ansi16 = [16]u32{
    0xFF45475A, // Black (Surface 1)
    0xFFF38BA8, // Red
    0xFFA6E3A1, // Green
    0xFFF9E2AF, // Yellow
    0xFF89B4FA, // Blue
    0xFFF5C2E7, // Magenta (Pink)
    0xFF94E2D5, // Cyan (Teal)
    0xFFBAC2DE, // White (Subtext 1)
    0xFF585B70, // Bright Black (Surface 2)
    0xFFF38BA8, // Bright Red
    0xFFA6E3A1, // Bright Green
    0xFFF9E2AF, // Bright Yellow
    0xFF89B4FA, // Bright Blue
    0xFFF5C2E7, // Bright Magenta
    0xFF94E2D5, // Bright Cyan
    0xFFA6ADC8, // Bright White (Subtext 0)
}
```

#### 2. Individual Slot Overrides

Individual ANSI color indices (0 through 15) can be overridden using any of the following prefix naming conventions:
- `color0` through `color15`
- `ansi0` through `ansi15`
- `ansi16_0` through `ansi16_15`

For example:
```odin
color0 = "#45475A" // Base black
color1 = "#F38BA8" // Red error color
color2 = "#A6E3A1" // Green success color
```

---

## Production Example Configuration (`config.odin`)

Below is a complete, production-ready configuration file. To install it, copy the snippet into `~/.config/term/config.odin`:

```odin
// ~/.config/term/config.odin
// Production Configuration for Term on macOS

// =============================================================================
// Window Dimensions & Geometry
// =============================================================================
cols      = 120         // Default window column width
rows      = 36          // Default window row height
padding_x = 8           // Horizontal padding around cell grid (pixels)
padding_y = 6           // Vertical padding around cell grid (pixels)
title     = "Term"      // Initial window title

// =============================================================================
// Typography & Font Configuration
// =============================================================================
font_family = "Maple Mono NF" // Primary monospaced font family
font_size   = 13.5            // Font size in points (minimum 6.0 pt)

// =============================================================================
// Shell Environment & Working Directory
// =============================================================================
shell             = ""     // Empty string defaults to $SHELL or /bin/zsh
working_directory = "~"    // New tabs start in user home directory
locale            = ""     // Empty string inherits system environment locale

// =============================================================================
// Window Translucency & Native macOS Vibrancy Blur
// =============================================================================
window_opacity = 0.95      // Window alpha: 0.1 (translucent) to 1.0 (opaque)
window_blur    = true      // Enables native Cocoa NSVisualEffectView vibrancy

// =============================================================================
// Cursor Appearance & Animation
// =============================================================================
cursor_blink             = true        // Enable cursor blinking
cursor_blink_interval_ms = 500         // Blink cycle period in milliseconds
cursor_color             = 0xFFF5E0DC  // Cursor accent color (Rosewater)

// =============================================================================
// Color Theme & Core UI Palette (Catppuccin Mocha)
// =============================================================================
theme_name           = "Catppuccin Mocha"
foreground           = 0xFFCDD6F4 // Text primary
background           = 0xFF1E1E2E // Base background
selection_foreground = 0xFF1E1E2E // Selected text color
selection_background = 0xFF585B70 // Selection bounding highlight

// =============================================================================
// Scrollback Buffer & Mouse Wheel Behavior
// =============================================================================
scrollback_max_lines   = 10000 // Total scrollback lines preserved in memory
alt_screen_wheel_lines = 3     // Wheel scroll step size in TUI apps (vim, htop)
scroll_multiplier      = 1.0   // Scroll speed velocity multiplier

// =============================================================================
// Tab Bar Ergonomics
// =============================================================================
tab_max_title_len = 20         // Maximum title characters before truncation

// =============================================================================
// ANSI 16 Color Palette (Catppuccin Mocha)
// =============================================================================
ansi16 = [16]u32{
    0xFF45475A, // 0:  Black          (Surface 1)
    0xFFF38BA8, // 1:  Red            (Red)
    0xFFA6E3A1, // 2:  Green          (Green)
    0xFFF9E2AF, // 3:  Yellow         (Yellow)
    0xFF89B4FA, // 4:  Blue           (Blue)
    0xFFF5C2E7, // 5:  Magenta        (Pink)
    0xFF94E2D5, // 6:  Cyan           (Teal)
    0xFFBAC2DE, // 7:  White          (Subtext 1)
    0xFF585B70, // 8:  Bright Black   (Surface 2)
    0xFFF38BA8, // 9:  Bright Red     (Red)
    0xFFA6E3A1, // 10: Bright Green   (Green)
    0xFFF9E2AF, // 11: Bright Yellow  (Yellow)
    0xFF89B4FA, // 12: Bright Blue    (Blue)
    0xFFF5C2E7, // 13: Bright Magenta (Pink)
    0xFF94E2D5, // 14: Bright Cyan    (Teal)
    0xFFA6ADC8, // 15: Bright White   (Subtext 0)
}
```
