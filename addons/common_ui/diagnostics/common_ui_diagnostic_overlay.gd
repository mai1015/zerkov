@tool
class_name CommonUIDiagnosticOverlay
extends PanelContainer

## A minimal live view of the runtime's routing and input state.
##
## Reads the runtime's immutable snapshots -- active contexts, active actions,
## captured triggers, the last routing decision, and the current device/modality
## -- and rebuilds on the matching change signals. It owns no routing state and
## never mutates the runtime, so it is safe to leave on in a debug build. Add it
## to any layer above the UI, or press its toggle action to show and hide it.

## Which UI user's state to display.
@export var ui_user: int = 0
## Show or hide the whole panel.
@export var overlay_visible: bool = true:
	set(value):
		overlay_visible = value
		visible = value
		# The refresh timer is pure overhead while the panel is hidden: gate it
		# on visibility rather than letting it rebuild the whole label string
		# ~6.6 times a second regardless.
		if _timer != null:
			_timer.paused = not value

## Refresh cadence for state that changes without a signal (hold/repeat timing).
@export var refresh_interval: float = 0.15

var _label: RichTextLabel
var _timer: Timer
var _runtime: CommonUIRuntime = null

const _PHASE_NAMES := {
	0: "pressed", 1: "released", 2: "hold", 3: "repeat", 4: "cancel",
}
const _MODALITY_NAMES := {
	0: "unknown", 1: "keyboard/mouse", 2: "gamepad", 3: "touch",
}
# Mirror of CommonUIRuntime.IneligibleReason.
const _REASON_NAMES := {
	0: "eligible", 1: "released", 2: "owner invalid", 3: "context inactive",
	4: "context suspended", 5: "layer inactive", 6: "screen inactive",
	7: "screen not top", 8: "routing stopped",
}


func _get_runtime() -> CommonUIRuntime:
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _ready() -> void:
	_build()
	visible = overlay_visible
	if Engine.is_editor_hint():
		return
	# A debug tool must keep working (and stay toggleable) regardless of
	# SceneTree.paused, same as the rest of the addon's pause-immune pieces.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_runtime = _get_runtime()
	if _runtime == null:
		_label.text = "CommonUI runtime not available."
		return
	for signal_name in ["active_actions_changed", "context_changed", "action_routed",
			"trigger_canceled"]:
		_runtime.connect(signal_name, Callable(self, "_on_state_changed"))
	_runtime.input_modality_changed.connect(func(_m: int, _d: int) -> void: _refresh())

	_timer = Timer.new()
	_timer.wait_time = maxf(0.02, refresh_interval)
	_timer.autostart = true
	_timer.paused = not overlay_visible
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_refresh()


func _build() -> void:
	if _label != null:
		return
	custom_minimum_size = Vector2(360, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.custom_minimum_size = Vector2(340, 0)
	add_child(_label)


func _on_state_changed(_arg0: Variant = null, _arg1: Variant = null, _arg2: Variant = null) -> void:
	_refresh()


func _refresh() -> void:
	if _runtime == null or _label == null:
		return

	var out := PackedStringArray()
	out.append("[b]CommonUI diagnostics[/b]  (user %d)" % ui_user)

	var device_name := _runtime.get_active_device_name()
	var device_suffix := "  \"%s\"" % device_name if not device_name.is_empty() else ""
	out.append("device: %s (#%d)%s" % [
		_MODALITY_NAMES.get(_runtime.get_input_modality(), "?"),
		_runtime.get_active_device(), device_suffix])

	out.append("")
	out.append("[b]contexts[/b]")
	var contexts: Array = _runtime.get_active_contexts(ui_user)
	if contexts.is_empty():
		out.append("  (none)")
	for entry in contexts:
		var flag := "  [color=gray](suspended)[/color]" if entry["suspended"] else ""
		out.append("  %s  p%d%s" % [entry["context"], entry["priority"], flag])

	out.append("")
	out.append("[b]active actions[/b]")
	var actions: Array = _runtime.get_active_actions(ui_user)
	if actions.is_empty():
		out.append("  (none)")
	for entry in actions:
		out.append("  %s  [color=gray]%s/%s p%d[/color]" % [
			entry["action"], _name_or_dash(entry["context"]),
			_name_or_dash(entry["layer"]), entry["priority"]])

	var triggers: Array = _runtime.get_captured_triggers(ui_user)
	if not triggers.is_empty():
		out.append("")
		out.append("[b]captured triggers[/b]")
		for entry in triggers:
			var hold := " hold" if entry["hold_started"] else ""
			out.append("  %s  dev#%d x%d%s" % [
				entry["action"], entry["device"], entry["repeat_index"], hold])

	out.append("")
	out.append("[b]last route[/b]")
	out.append_array(_format_route(_runtime.get_last_route_report()))

	_label.text = "\n".join(out)


func _format_route(report: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var action: StringName = report.get("action", &"")
	if String(action).is_empty():
		lines.append("  (none yet)")
		return lines
	var verb := "consumed" if report.get("consumed", false) else "passed through"
	lines.append("  %s -> [color=%s]%s[/color]" % [
		action, "lime" if report.get("consumed", false) else "gray", verb])
	for entry in report.get("entries", []):
		var mark := "*" if entry["invoked"] else " "
		lines.append("   %s handle %d: %s" % [
			mark, entry["handle_id"], _REASON_NAMES.get(entry["reason"], "?")])
	return lines


func _name_or_dash(name: StringName) -> String:
	return String(name) if not String(name).is_empty() else "-"


func toggle() -> void:
	overlay_visible = not overlay_visible
