package main

import "core:fmt"
import "core:os"
import "vendor:sdl3"
import "vendor:wgpu"
import wgpu_sdl3_glue "vendor:wgpu/sdl3glue"

import termgrid "../terminal"
import render "../render"
import gpu "../render/gpu"
import wgpu_backend "../render/gpu/wgpu"
import win "../platform/window"

APP_DEFAULT_ROWS :: 24
APP_DEFAULT_COLS :: 80
APP_CELL_W :: 8
APP_CELL_H :: 16
APP_FONT_SIZE :: f32(13)
APP_TITLE :: "Hello World Term"

FONT_PATHS :: []string{
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Supplemental/Courier New.ttf",
}

FALLBACK_FONT_PATHS :: []string{
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
}

find_font :: proc() -> (string, bool) {
	for path in FONT_PATHS {
		if os.is_file(path) {
			return path, true
		}
	}
	return "", false
}

main :: proc() {
    _ = sdl3.SetAppMetadata("hello_world", "1.0.0", "com.hello.world")
    if !sdl3.Init({.VIDEO}) {
        fmt.eprintf("SDL Init failed: %s\n", sdl3.GetError())
        return
    }
    defer sdl3.Quit()
    
    window: win.Window
    window_w := i32(APP_DEFAULT_COLS) * i32(APP_CELL_W)
    window_h := i32(APP_DEFAULT_ROWS) * i32(APP_CELL_H)
    if !win.window_init(&window, APP_TITLE, window_w, window_h) {
        fmt.eprintf("Window init failed\n")
        return
    }
    defer win.window_destroy(&window)
    
    backend := wgpu_backend.wgpu_backend_vtable()
    instance := backend.create_instance()
    if instance == nil {
        fmt.eprintf("Create instance failed\n")
        return
    }
    defer backend.destroy_instance(instance)
    
    surface := gpu.Gpu_Surface(wgpu_sdl3_glue.GetSurface(wgpu.Instance(instance), window.handle))
    if rawptr(surface) == nil {
        fmt.eprintf("GetSurface failed\n")
        return
    }
    defer wgpu.SurfaceRelease(wgpu.Surface(rawptr(surface)))
    
    device, queue := backend.request_device(instance, rawptr(surface))
    if rawptr(device) == nil || rawptr(queue) == nil {
        fmt.eprintf("Request device failed\n")
        return
    }
    defer backend.destroy_device(device)
    
    font_path, font_ok := find_font()
    if !font_ok {
        fmt.eprintf("No usable font found\n")
        return
    }
    
    scale := f32(1.0)
    if window.width > 0 {
        scale = f32(window.pixel_w) / f32(window.width)
    }
    phys_font_size := APP_FONT_SIZE * scale
    format := backend.get_preferred_format(rawptr(surface), device)
    screen_w := f32(window.pixel_w) if window.pixel_w > 0 else f32(window_w)
    screen_h := f32(window.pixel_h) if window.pixel_h > 0 else f32(window_h)
    
    renderer: render.Renderer
    if !render.renderer_init(
        &renderer,
        font_path,
        phys_font_size,
        backend,
        device,
        queue,
        i32(APP_DEFAULT_ROWS),
        i32(APP_DEFAULT_COLS),
        0, 0,
        screen_w, screen_h,
        format,
        fallback_paths = FALLBACK_FONT_PATHS,
    ) {
        fmt.eprintf("Renderer init failed\n")
        return
    }
    defer render.renderer_destroy(&renderer)
    
    render.renderer_attach_surface(&renderer, surface, u32(screen_w), u32(screen_h))
    
    terminal: termgrid.Terminal
    termgrid.terminal_init(&terminal, APP_DEFAULT_ROWS, APP_DEFAULT_COLS)
    defer termgrid.terminal_destroy(&terminal)
    
    // Write text to terminal
    text := "Hello, world! 🌎"
    for r in text {
        termgrid.terminal_put_char(&terminal, r)
    }
    
    lut: render.Style_LUT
    render.style_lut_rebuild(&lut, &terminal.grid.style_table)
    
    // Main loop
    running := true
    for running {
        event: sdl3.Event
        for sdl3.PollEvent(&event) {
            #partial switch event.type {
            case .QUIT:
                running = false
            case .KEY_DOWN:
                if event.key.key == sdl3.K_ESCAPE || event.key.key == sdl3.K_Q {
                    running = false
                }
            }
        }
        
        render.renderer_frame_auto(&renderer, &terminal, &lut)
        sdl3.Delay(16)
    }
}
