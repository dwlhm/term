--- _app_spawn_pane_backend ---
_app_spawn_pane_backend :: proc(a: ^App, init_rows: int = 0, init_cols: int = 0) -> ^Backend {
	if a == nil do return nil
	shell, shell_allocated := _resolve_shell()
	defer if shell_allocated { delete(shell) }
	shell_argv := _resolve_shell_argv(shell)
	rows := init_rows if init_rows > 0 else (a.renderer.rows > 0 ? int(a.renderer.rows) : APP_DEFAULT_ROWS)
	cols := init_cols if init_cols > 0 else (a.renderer.cols > 0 ? int(a.renderer.cols) : APP_DEFAULT_COLS)
	b := new(Backend)
	if !backend_init(b, rows, cols, shell, shell_argv, &a.config, a.renderer.theme) {
		free(b)
		return nil
	}
	backend_set_clipboard_callbacks(b, &a.frontend, _frontend_clipboard_write_cb, _frontend_clipboard_read_cb)
	backend_set_notify_data_ready(b, a, _app_on_backend_data_ready)
	_ = backend_start_thread(b)
	_app_wake_pty_monitor(a)
	return b
}


--- _app_layout_ui ---
_app_layout_ui :: proc(a: ^App) {
	if a == nil do return
	window_w := f32(a.window.width) if a.window.width > 0 else f32(a.window.pixel_w)
	window_h := f32(a.window.height) if a.window.height > 0 else f32(a.window.pixel_h)
	tab_count := len(a.session_mgr.tabs)
	_ = ui.tab_bar_layout(&a.tab_bar, window_w, tab_count, a.tab_rects[:tab_count])
	if a.tab_overflow.visible {


--- _app_route_pointer ---
_app_route_pointer :: proc(a: ^App, pointer: input.Input_Pointer_Event) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false


--- frontend_apply_vibrancy ---
frontend_apply_vibrancy :: proc(f: ^Frontend, opacity: f32, blur: bool) {
	if f == nil do return
	if f.window.handle != nil {
		win.window_configure_vibrancy(&f.window, opacity, blur)
	}
	when ODIN_OS == .Darwin {
		if rawptr(f.surface) != nil {
			metal_surf := (^metal_backend.Metal_Surface)(rawptr(f.surface))
			metal_backend.configure_surface_vibrancy(metal_surf, opacity, blur)
		}
	}
}
--- TARGET:
// frontend_apply_theme updates the renderer's theme.
frontend_apply_theme :: proc(f: ^Frontend, theme: termgrid.Theme) {
	if f == nil {
		return
	}
	f.renderer.theme = theme
}


