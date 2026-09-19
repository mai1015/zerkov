class_name LocalLootContainerPresenter
extends Node2D
## Visual-only optional loot container. It deliberately owns no physics body,
## interaction authority, inventory or collision state. The placeholder is
## procedural so a missing/import-pending cosmetic asset can never block a raid.

var _visual: StringName = &""

func configure(visual: StringName, label: String, generation: int) -> bool:
	if generation < 1 or visual not in [
			RaidPopulationCatalog.VISUAL_WOOD,
			RaidPopulationCatalog.VISUAL_MILITARY,
		] or label.is_empty() or get_child_count() != 0:
		return false
	_visual = visual
	name = "OptionalLoot_" + label.to_snake_case()
	var caption := Label.new()
	caption.name = "ContainerLabel"
	caption.text = label
	caption.position = Vector2(-42, 11)
	caption.size = Vector2(84, 18)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 11)
	caption.add_theme_color_override("font_color", Color("efbf74"))
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(caption)
	set_meta("population_generation", generation)
	queue_redraw()
	return true

func _draw() -> void:
	if _visual.is_empty():
		return
	var fill := Color("6a4c32") if _visual == RaidPopulationCatalog.VISUAL_WOOD \
		else Color("455347")
	var edge := Color("bc8b56") if _visual == RaidPopulationCatalog.VISUAL_WOOD \
		else Color("82967d")
	var box := Rect2(Vector2(-14, -10), Vector2(28, 20))
	draw_rect(box, Color(fill, 0.96))
	draw_rect(box, edge, false, 2.0)
	draw_line(box.position + Vector2(3, 3), box.end - Vector2(3, 3), Color(edge, 0.8), 1.0)
	draw_line(Vector2(box.end.x - 3, box.position.y + 3),
		Vector2(box.position.x + 3, box.end.y - 3), Color(edge, 0.8), 1.0)
	draw_line(Vector2(box.position.x, 0), Vector2(box.end.x, 0), Color(edge, 0.7), 1.0)
