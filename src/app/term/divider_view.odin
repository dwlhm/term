package term

import chrome_dl "../../core/chrome/draw_list"
import chrome_splits "../../core/chrome/splits"

// divider_view_emit_tree recursively emits partition lines and centered drag handle
// grip buttons for active split trees into dl.
divider_view_emit_tree :: proc(
	dl: ^chrome_dl.Ui_Draw_List,
	node: ^chrome_splits.Split_Node,
	hovered_node: ^chrome_splits.Split_Node,
	dragged_node: ^chrome_splits.Split_Node,
	scale: f32 = 1.0,
) {
	if dl == nil || node == nil || node.kind == .Leaf do return

	is_dragged := (node == dragged_node)
	is_hovered := (node == hovered_node)

	col_div: [4]f32
	col_handle: [4]f32

	if is_dragged {
		col_div = {0.35, 0.65, 0.95, 0.70}
		col_handle = {0.35, 0.65, 0.95, 1.00}
	} else if is_hovered {
		col_div = {0.35, 0.60, 0.90, 0.45}
		col_handle = {0.35, 0.65, 0.95, 0.90}
	} else {
		col_div = {0.18, 0.20, 0.24, 0.60}
		col_handle = {0.26, 0.29, 0.36, 0.75}
	}

	if node.kind == .Horizontal {
		min_x := node.rect[0] + node.rect[2] * chrome_splits.split_effective_ratio(node)
		max_x := min_x
		if node.left != nil && node.right != nil {
			min_x = node.left.rect[0] + node.left.rect[2]
			max_x = node.right.rect[0]
		}
		div_w := max(max_x - min_x, 1.0)
		div_rect := [4]f32{min_x, node.rect[1], div_w, node.rect[3]}
		chrome_dl.ui_draw_rect(dl, div_rect, col_div)

		// Centered drag button grip handle (vertical capsule on vertical divider line)
		cx := min_x + div_w * 0.5
		cy := node.rect[1] + node.rect[3] * 0.5
		handle_w := max(div_w + 2.0 * scale, 6.0 * scale)
		handle_h := 36.0 * scale
		handle_rect := [4]f32{cx - handle_w * 0.5, cy - handle_h * 0.5, handle_w, handle_h}
		chrome_dl.ui_draw_rounded_rect(dl, handle_rect, col_handle, handle_w * 0.5)

	} else if node.kind == .Vertical {
		min_y := node.rect[1] + node.rect[3] * chrome_splits.split_effective_ratio(node)
		max_y := min_y
		if node.left != nil && node.right != nil {
			min_y = node.left.rect[1] + node.left.rect[3]
			max_y = node.right.rect[1]
		}
		div_h := max(max_y - min_y, 1.0)
		div_rect := [4]f32{node.rect[0], min_y, node.rect[2], div_h}
		chrome_dl.ui_draw_rect(dl, div_rect, col_div)

		// Centered drag button grip handle (horizontal capsule on horizontal divider line)
		cx := node.rect[0] + node.rect[2] * 0.5
		cy := min_y + div_h * 0.5
		handle_w := 36.0 * scale
		handle_h := max(div_h + 2.0 * scale, 6.0 * scale)
		handle_rect := [4]f32{cx - handle_w * 0.5, cy - handle_h * 0.5, handle_w, handle_h}
		chrome_dl.ui_draw_rounded_rect(dl, handle_rect, col_handle, handle_h * 0.5)
	}

	if node.left != nil {
		divider_view_emit_tree(dl, node.left, hovered_node, dragged_node, scale)
	}
	if node.right != nil {
		divider_view_emit_tree(dl, node.right, hovered_node, dragged_node, scale)
	}
}
