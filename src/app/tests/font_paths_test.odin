package app_test

import "core:os"
import "core:path/filepath"
import "core:testing"
import app "../"
import render "../../render"

@(test)
test_frontend_font_paths_order :: proc(t: ^testing.T) {
	candidates := []string{"assets/fonts/primary.ttf", "assets/fonts/secondary.ttf", "~/Library/Fonts/user.ttf", "/system/font.ttf"}
	paths := app.frontend_font_paths("/relocated app/Term.app/Contents/MacOS/term", candidates)
	defer app.frontend_font_paths_destroy(paths)
	expected := []string{
		"/relocated app/Term.app/Contents/Resources/fonts/primary.ttf",
		"/relocated app/Term.app/Contents/Resources/fonts/secondary.ttf",
		"/relocated app/Term.app/Contents/assets/fonts/primary.ttf",
		"/relocated app/Term.app/Contents/assets/fonts/secondary.ttf",
	}
	testing.expect_value(t, len(paths), len(expected) + len(candidates))
	for path, i in expected do testing.expect_value(t, paths[i], path)
	for path, i in candidates do testing.expect_value(t, paths[len(expected)+i], path)

	legacy := app.frontend_font_paths("", candidates)
	defer app.frontend_font_paths_destroy(legacy)
	testing.expect_value(t, len(legacy), len(candidates))
	for path, i in candidates do testing.expect_value(t, legacy[i], path)
}

@(test)
test_frontend_shipped_fonts_rasterize_after_relocation :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "term font resources *", context.allocator)
	if !testing.expect(t, root_err == nil) do return
	defer delete(root)
	defer os.remove_all(root)

	primary_data :: #load("../../../assets/fonts/MapleMono-NF-Regular.ttf")
	symbols_data :: #load("../../../assets/fonts/SymbolsNerdFontMono-Regular.ttf")
	for layout in ([]string{"Term.app/Contents/MacOS/term", "bin/term"}) {
		executable_path, _ := filepath.join({root, layout})
		defer delete(executable_path)
		primary_paths := app.frontend_font_paths(executable_path, app.FONT_PATHS)
		defer app.frontend_font_paths_destroy(primary_paths)
		fallback_paths := app.frontend_font_paths(executable_path, app.FALLBACK_FONT_PATHS)
		defer app.frontend_font_paths_destroy(fallback_paths)
		// Use the shipped NF primary in each executable-relative layout.
		primary_index := 0 if layout == "Term.app/Contents/MacOS/term" else 2
		fallback_index := 0 if layout == "Term.app/Contents/MacOS/term" else 1
		primary_path := primary_paths[primary_index]
		symbols_path := fallback_paths[fallback_index]
		if !testing.expect(t, os.mkdir_all(filepath.dir(primary_path)) == nil) do return
		if !testing.expect(t, os.write_entire_file(primary_path, transmute([]u8)primary_data) == nil) do return
		if !testing.expect(t, os.write_entire_file(symbols_path, transmute([]u8)symbols_data) == nil) do return

		primary: render.Font_Rasterizer
		loaded := false
		for path in primary_paths {
			if render.font_rasterizer_init(&primary, path, 18) {
				testing.expect_value(t, path, primary_path)
				loaded = true
				break
			}
		}
		if !testing.expect(t, loaded, "relocated resources must load without a matching cwd") do return
		defer render.font_rasterizer_destroy(&primary)
		chain: render.Fallback_Chain
		testing.expect(t, render.fallback_chain_init(&chain, nil, fallback_paths, 18, context.allocator))
		defer render.fallback_chain_destroy(&chain)
		for cp in ([]u32{0xF179, 0xF07B, 0xF017, 0xF126, 0x25A3, 0x2B1D}) {
			index, covered := render.fallback_resolve(&chain, cp, nil)
			if !testing.expect(t, covered, "prompt icons must be covered by shipped fonts") do continue
			testing.expect(t, index > 0, "missing primary must use the Nerd Font fallback")
			bitmap := render.font_rasterize_glyph_fitted(&chain.fonts[index], cp)
			defer delete(bitmap.pixels)
			nonempty := false
			for pixel in bitmap.pixels do nonempty = nonempty || pixel != 0
			testing.expect(t, nonempty, "covered icons must produce visible glyph pixels")
		}
	}
}

@(test)
test_frontend_missing_resources_preserve_legacy_font :: proc(t: ^testing.T) {
	legacy_path, ok := app.find_font()
	if !testing.expect(t, ok) do return
	defer delete(legacy_path)
	paths := app.frontend_font_paths("/nonexistent term test root/bin/term", []string{"assets/fonts/nonexistent-font.ttf", legacy_path})
	defer app.frontend_font_paths_destroy(paths)
	font: render.Font_Rasterizer
	loaded := false
	for path in paths {
		if render.font_rasterizer_init(&font, path, 18) {
			testing.expect_value(t, path, legacy_path)
			loaded = true
			break
		}
	}
	testing.expect(t, loaded, "missing executable-relative resources must retain legacy search")
	defer render.font_rasterizer_destroy(&font)
}

@(test)
test_find_font_with_relocated_executable :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "term find font *", context.allocator)
	if !testing.expect(t, root_err == nil) do return
	defer delete(root)
	defer os.remove_all(root)

	executable_path, _ := filepath.join({root, "Term.app/Contents/MacOS/term"}, context.allocator)
	defer delete(executable_path)

	font_dir, _ := filepath.join({root, "Term.app/Contents/Resources/fonts"}, context.allocator)
	defer delete(font_dir)
	if !testing.expect(t, os.mkdir_all(font_dir) == nil) do return

	font_file, _ := filepath.join({font_dir, "MapleMono-NF-Regular.ttf"}, context.allocator)
	defer delete(font_file)

	primary_data :: #load("../../../assets/fonts/MapleMono-NF-Regular.ttf")
	if !testing.expect(t, os.write_entire_file(font_file, transmute([]u8)primary_data) == nil) do return

	symbols_file, _ := filepath.join({font_dir, "SymbolsNerdFontMono-Regular.ttf"}, context.allocator)
	defer delete(symbols_file)
	symbols_data :: #load("../../../assets/fonts/SymbolsNerdFontMono-Regular.ttf")
	if !testing.expect(t, os.write_entire_file(symbols_file, transmute([]u8)symbols_data) == nil) do return

	found_path, ok := app.find_font(executable_path)
	if !testing.expect(t, ok, "find_font should succeed with relocated executable") do return
	defer delete(found_path)

	testing.expect_value(t, found_path, font_file)

	fallback_paths := app.frontend_font_paths(executable_path, app.FALLBACK_FONT_PATHS, context.temp_allocator)
	defer app.frontend_font_paths_destroy(fallback_paths, context.temp_allocator)
	testing.expect(t, len(fallback_paths) > 0)
	testing.expect_value(t, fallback_paths[0], symbols_file)
}
