package pinnacle_app_adapter

import pure_ui "../"
import term "../../terminal"
import "core:fmt"

Terminal_UI_Adapter :: struct {
	ui: pure_ui.UI_Service,
	
	cols: i32,
	rows: i32,
	cell_width: f32,
	cell_height: f32,
	
	grid_entities: []pure_ui.Entity_ID,
	bg_entities:   []pure_ui.Entity_ID,
}

init_terminal_adapter :: proc(adapter: ^Terminal_UI_Adapter, ui: pure_ui.UI_Service, rows, cols: i32, cw, ch: f32) {
	adapter.ui = ui
	adapter.rows = rows
	adapter.cols = cols
	adapter.cell_width = cw
	adapter.cell_height = ch
	
	adapter.grid_entities = make([]pure_ui.Entity_ID, int(rows) * int(cols))
	adapter.bg_entities = make([]pure_ui.Entity_ID, int(rows) * int(cols))
	
	_spawn_base_grid(adapter)
}

resize_terminal_adapter :: proc(adapter: ^Terminal_UI_Adapter, rows, cols: i32) {
	if rows == adapter.rows && cols == adapter.cols do return
	
	adapter.rows = rows
	adapter.cols = cols
	
	delete(adapter.grid_entities)
	delete(adapter.bg_entities)
	
	adapter.grid_entities = make([]pure_ui.Entity_ID, int(rows) * int(cols))
	adapter.bg_entities = make([]pure_ui.Entity_ID, int(rows) * int(cols))
	
	_spawn_base_grid(adapter)
}

destroy_terminal_adapter :: proc(adapter: ^Terminal_UI_Adapter) {
	delete(adapter.grid_entities)
	delete(adapter.bg_entities)
}

_spawn_base_grid :: proc(a: ^Terminal_UI_Adapter) {
	material_text: u32 = 0
	material_bg: u32 = 1 

	for r in 0..<a.rows {
		for c in 0..<a.cols {
			idx := int(r) * int(a.cols) + int(c)
			pos_x := f32(c) * a.cell_width
			pos_y := f32(r) * a.cell_height
			
			a.bg_entities[idx] = a.ui.spawn_panel(
				&a.ui, 
				{pos_x, pos_y, 0.0}, 
				{a.cell_width, a.cell_height}, 
				material_bg,
			)
			
			a.grid_entities[idx] = a.ui.spawn_text(
				&a.ui, 
				" ", 
				{pos_x, pos_y}, 
				a.cell_width, // width
				material_text,
			)			
			screen_w := f32(a.cols) * a.cell_width
			screen_h := f32(a.rows) * a.cell_height
			
			// Store screen_w and screen_h in rotation for NDC projection in shader
			a.ui.world.transforms[a.bg_entities[idx]].rotation = {screen_w, screen_h, 0.0, 0.0}
			a.ui.world.transforms[a.grid_entities[idx]].rotation = {screen_w, screen_h, 0.0, 0.0}
			
			// Default Catppuccin Mocha colors
			a.ui.world.glyphs[a.bg_entities[idx]].color_packed = 0xFF1E1E2E // Base background
			a.ui.world.glyphs[a.grid_entities[idx]].color_packed = 0xFFCDD6F4 // Text foreground

		}
	}
}

update_from_damage :: proc(a: ^Terminal_UI_Adapter, t: ^term.Terminal, damage: ^term.Damage) {
	if len(damage.dirty_rows) == 0 && len(damage.journal_ops) == 0 {
		return
	}

	for row_idx in 0..<len(damage.dirty_rows) {
		if row_idx >= int(a.rows) do continue
		
		dr := damage.dirty_rows[row_idx]
		if dr.full || dr.span_count > 0 {
			for col in 0..<a.cols {
				grid_idx := int(row_idx) * int(a.cols) + int(col)
				if grid_idx >= len(a.grid_entities) do continue
				
				text_entity := a.grid_entities[grid_idx]
				bg_entity := a.bg_entities[grid_idx]
				
				cell := term.grid_get_cell(&t.grid, int(row_idx), int(col))
				style := term.style_table_get(&t.grid.style_table, cell.style)
				
				// Terminal styles are ARGB (0xAARRGGBB) or RGB with FF alpha
				bg_col := style.bg
				if (bg_col & 0xFF000000) == 0 {
					bg_col |= 0xFF000000
				}
				fg_col := style.fg
				if (fg_col & 0xFF000000) == 0 {
					fg_col |= 0xFF000000
				}
				
				a.ui.world.glyphs[bg_entity].color_packed = bg_col
				a.ui.world.dirty_glyphs[bg_entity] = true
				
				// Default text entity
				a.ui.world.glyphs[text_entity].color_packed = fg_col
				a.ui.world.dirty_glyphs[text_entity] = true
			}
		}
	}

	a.ui.tick_frame(&a.ui)
}
