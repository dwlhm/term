#!/usr/bin/env python3
"""
Standardized High-Throughput Stress & Benchmark Payload Generator.
Produces deterministic payloads for:
  1. truecolor_dense.vt  - Dense 24-bit TrueColor RGB fg & bg with styles on every cell
  2. truecolor_gradient.vt- Smooth 24-bit RGB diagonal rainbow waves
  3. egc_unicode.vt       - ZWJ chains, combining diacritics, emoji, skin-tones, CJK wide glyphs
  4. ascii_scrolling.vt   - High-rate line scrolling with line numbering
  5. cursor_jump.vt       - Chaotic CSI cursor positioning, erasing, and overwriting
"""

import sys
import os

def gen_truecolor_dense(filename: str, total_kb: int = 10240): # 10MB default
    target_bytes = total_kb * 1024
    written = 0
    cols = 120
    row_idx = 0
    with open(filename, "wb") as f:
        while written < target_bytes:
            row_chunks = []
            for c in range(cols):
                r = (row_idx * 7 + c * 3) & 0xFF
                g = (row_idx * 11 + c * 5) & 0xFF
                b = (row_idx * 13 + c * 7) & 0xFF
                style = 1 if ((row_idx + c) % 5 == 0) else 0 # bold intermittently
                # CSI 38;2;R;G;B m and CSI 48;2;R;G;B m
                seq = f"\033[{style};38;2;{r};{g};{b};48;2;{255-r};{255-g};{255-b}mX"
                row_chunks.append(seq)
            row_chunks.append("\033[0m\n")
            line_bytes = "".join(row_chunks).encode("utf-8")
            f.write(line_bytes)
            written += len(line_bytes)
            row_idx += 1

def gen_truecolor_gradient(filename: str, frames: int = 200, rows: int = 40, cols: int = 120):
    with open(filename, "wb") as f:
        for fr in range(frames):
            frame_chunks = ["\033[H"] # Cursor home
            for r in range(rows):
                for c in range(cols):
                    red = int(127.5 * (1.0 + math_sin((r + fr) * 0.15)))
                    green = int(127.5 * (1.0 + math_sin((c + fr) * 0.15)))
                    blue = int(127.5 * (1.0 + math_sin((r + c + fr) * 0.15)))
                    frame_chunks.append(f"\033[38;2;{red};{green};{blue};48;2;{red//4};{green//4};{blue//4}m#")
                frame_chunks.append("\033[0m\n")
            f.write("".join(frame_chunks).encode("utf-8"))

def math_sin(x: float) -> float:
    import math
    return math.sin(x)

def gen_egc_unicode(filename: str, total_kb: int = 5120): # 5MB default
    target_bytes = total_kb * 1024
    written = 0
    # Complex EGC clusters, emoji skin tones, ZWJ sequences, CJK, Arabic
    samples = [
        "👨‍👩‍👧‍👦", "👩🏽‍💻", "🏳️‍🌈", "❤️‍🔥", "🧑🏿‍🚀",
        "e\u0301\u0302\u0323", # combining accent stack
        "Z̸a̷l̸g̸o̶", # Zalgo
        "こんにちは世界", "⚡🔥🚀🎮", "﷽", "你再"
    ]
    with open(filename, "wb") as f:
        idx = 0
        while written < target_bytes:
            line_parts = []
            for _ in range(15):
                s = samples[idx % len(samples)]
                idx += 1
                line_parts.append(f"\033[38;5;{(idx%214)+17}m{s}\033[0m ")
            line_parts.append("\n")
            b = "".join(line_parts).encode("utf-8")
            f.write(b)
            written += len(b)

def gen_ascii_scrolling(filename: str, lines: int = 100000):
    with open(filename, "wb") as f:
        for i in range(1, lines + 1):
            f.write(f"[{i:06d}] The quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\n".encode("utf-8"))

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <type> <output_file> [size_kb/lines]")
        sys.exit(1)

    kind = sys.argv[1]
    out_file = sys.argv[2]
    val = int(sys.argv[3]) if len(sys.argv) > 3 else None

    if kind == "truecolor_dense":
        gen_truecolor_dense(out_file, val or 10240)
    elif kind == "truecolor_gradient":
        gen_truecolor_gradient(out_file, val or 150)
    elif kind == "egc_unicode":
        gen_egc_unicode(out_file, val or 5120)
    elif kind == "ascii_scrolling":
        gen_ascii_scrolling(out_file, val or 100000)
    else:
        print(f"Unknown kind: {kind}")
        sys.exit(1)

    print(f"Generated {out_file} ({os.path.getsize(out_file)} bytes)")

if __name__ == "__main__":
    main()
