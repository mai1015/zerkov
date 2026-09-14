class_name ZAIDebugOverlay
extends Node2D
## Task 6.8. Read-only diagnostic drawing; mount under world presentation, not
## under authority. All positions are own observer or historically disclosed
## facts. This node performs no queries and never calls decision/gameplay code.

@export var diagnostics_enabled: bool = false:
	set(value):
		diagnostics_enabled = value
		visible = value
		queue_redraw()
var _frame: Dictionary = {}


func _ready() -> void:
	visible = diagnostics_enabled


func publish(frame: Dictionary) -> bool:
	if frame.get("diagnostic_only") != true or not frame.get("agents") is Array \
		or frame.agents.size() > RaidAIRuntime.MAX_AGENTS or not frame.get("budget") is Dictionary:
		return false
	# Input is a bounded runtime debug_snapshot, never arbitrary scene objects.
	for row: Variant in frame.agents:
		if not row is Dictionary or not ZAIValues.position(row.get("observer_position_raw")) \
			or not ZAIValues.position(row.get("observer_facing_raw")) \
			or not row.get("path") is Array or row.path.size() > ZAIAgent.MAX_POINTS \
			or typeof(row.get("state")) != TYPE_STRING or typeof(row.get("entity_id")) != TYPE_STRING:
			return false
		if row.get("has_last_known") == true and not ZAIValues.position(row.get("last_known_raw")):
			return false
		for point: Variant in row.path:
			if not ZAIValues.position(point):
				return false
	_frame = frame.duplicate(true)
	queue_redraw()
	return true


func summary() -> String:
	var budget: Dictionary = _frame.get("budget", {})
	var text := "AI DIAGNOSTIC | tick %d | decisions %d | deferred %d | budget %d" % [
		_frame.get("tick", 0), budget.get("decisions", 0), budget.get("deferred", 0),
		budget.get("decision_budget", 0)]
	var vision: Dictionary = _frame.get("vision_budget", {})
	if not vision.is_empty():
		text += " | vision work %d/%d | deferred %d" % [vision.get("consumed", 0), vision.get("budget", 0), vision.get("deferred", 0)]
	return text


func _draw() -> void:
	if not diagnostics_enabled or _frame.is_empty():
		return
	var font := ThemeDB.fallback_font
	for row: Dictionary in _frame.agents:
		var origin := _pixel(row.observer_position_raw)
		var facing: Vector2 = Vector2(row.observer_facing_raw).normalized()
		var half_angle: float = deg_to_rad(80.0 if row.get("archetype") == "mutant" else 60.0)
		var radius: float = 12.0 * 32.0 if row.get("archetype") == "mutant" else 18.0 * 32.0
		var angle := facing.angle()
		var tint := Color(0.35, 0.75, 1.0, 0.32)
		draw_arc(origin, radius, angle - half_angle, angle + half_angle, 24, tint, 1.0)
		draw_line(origin, origin + Vector2.from_angle(angle - half_angle) * radius, tint)
		draw_line(origin, origin + Vector2.from_angle(angle + half_angle) * radius, tint)
		draw_circle(origin, 4.0, Color(0.4, 0.8, 1.0))
		var previous := origin
		for point: Vector2i in row.path:
			var next := _pixel(point)
			draw_line(previous, next, Color(0.4, 1.0, 0.55), 1.0)
			previous = next
		if row.get("has_last_known") == true:
			var remembered := _pixel(row.last_known_raw)
			draw_arc(remembered, 5.0, 0.0, TAU, 16, Color(1.0, 0.7, 0.2), 1.0)
			draw_line(origin, remembered, Color(1.0, 0.7, 0.2, 0.55), 1.0)
			draw_string(font, remembered + Vector2(7, 0), "LAST KNOWN", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1.0, 0.8, 0.4))
		var vision: Dictionary = row.get("vision", {})
		var state_label: String = row.state.to_upper() + " / " + String(vision.get("state", "unknown")).to_upper()
		draw_string(font, origin + Vector2(7, -8), state_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)


static func _pixel(point: Vector2i) -> Vector2:
	return Vector2(point) * float(ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT) / float(ZAIValues.UNIT)
