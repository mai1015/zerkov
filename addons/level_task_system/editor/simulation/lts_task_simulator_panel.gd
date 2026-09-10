@tool
class_name LtsTaskSimulatorPanel
extends VBoxContainer

## Compact bottom-drawer controls for an isolated production runtime instance.
## Inputs are copied into LtsTaskSimulator and never target a live game object.

signal state_changed(state: Dictionary)
signal activity_projection_changed(projection: Dictionary)

const Simulator := preload("res://addons/level_task_system/editor/simulation/lts_task_simulator.gd")
const DebugModel := preload("res://addons/level_task_system/editor/simulation/lts_graph_debug_model.gd")
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const StatusBadge := preload("res://addons/level_task_system/editor/components/lts_status_badge.gd")

var _simulator: RefCounted = Simulator.new()
var _debug_model: RefCounted = DebugModel.new()
var _graph: Dictionary = {}
var _built := false

var _status: StatusBadge
var _start_button: Button
var _step_button: Button
var _run_button: Button
var _reset_button: Button
var _fact_provider: LineEdit
var _fact_identifier: LineEdit
var _fact_value: LineEdit
var _event_provider: LineEdit
var _event_identifier: LineEdit
var _event_amount: SpinBox
var _trace: Tree


func _ready() -> void:
	_build()
	_refresh({})


func bind_graph(graph: Dictionary, scope_key: String = "editor.simulation") -> Dictionary:
	_graph = graph.duplicate(true)
	_debug_model.call("set_graph_document", _graph)
	_simulator.call("set_scope_key", scope_key)
	var result: Dictionary = _simulator.call("set_graph", _graph)
	_refresh(result)
	return result


func set_runtime_backend(backend: Variant) -> Dictionary:
	var result: Dictionary = _simulator.call("set_runtime_backend", backend)
	_refresh(result)
	return result


func get_simulator() -> RefCounted:
	return _simulator


func get_graph_identifier() -> String:
	return String(_graph.get("identifier", ""))


func get_debug_model() -> RefCounted:
	return _debug_model


func set_graph_canvas(canvas: Object) -> void:
	if canvas != null and canvas.has_method("set_debug_model"):
		canvas.call("set_debug_model", _debug_model)


func start_simulation() -> Dictionary:
	return _finish_operation(_simulator.call("start"), false)


func step_simulation() -> Dictionary:
	return _finish_operation(_simulator.call("step"), false)


func run_simulation(max_steps: int = 128) -> Dictionary:
	return _finish_operation(_simulator.call("run", max_steps), true)


func reset_simulation(preserve_inputs := false) -> Dictionary:
	var result: Dictionary = _simulator.call("reset", preserve_inputs)
	_debug_model.call("reset_activity")
	return _finish_operation(result, false)


func export_trace() -> Dictionary:
	return _simulator.call("export_trace_result")


func _build() -> void:
	if _built:
		return
	_built = true
	name = "TaskSimulatorPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var command_row := HBoxContainer.new()
	command_row.name = "SimulationCommands"
	add_child(command_row)
	_status = StatusBadge.new()
	_status.name = "SimulationStatus"
	_status.call("setup", "Simulation ready", ComponentState.DEFAULT)
	command_row.add_child(_status)
	command_row.add_spacer(false)
	_start_button = _button(command_row, "Start", "Compile and start an isolated runtime", _on_start)
	_step_button = _button(command_row, "Step", "Advance one deterministic tick", _on_step)
	_run_button = _button(command_row, "Run", "Advance until idle or the bounded step limit", _on_run)
	_reset_button = _button(command_row, "Reset", "Start a fresh isolated instance", _on_reset)

	var inputs := HBoxContainer.new()
	inputs.name = "SimulationInputs"
	add_child(inputs)
	_fact_provider = _line(inputs, "FactProvider", "provider.fact", "Fact provider")
	_fact_identifier = _line(inputs, "FactIdentifier", "fact.identifier", "Fact identifier")
	_fact_value = _line(inputs, "FactValue", "value", "Synthetic value")
	_button(inputs, "Set fact", "Set a synthetic typed fact for this simulator only", _on_set_fact)
	_event_provider = _line(inputs, "EventProvider", "provider.event", "Event provider")
	_event_identifier = _line(inputs, "EventIdentifier", "event.identifier", "Event identifier")
	_event_amount = SpinBox.new()
	_event_amount.name = "EventAmount"
	_event_amount.min_value = 1
	_event_amount.max_value = 1000000
	_event_amount.value = 1
	_event_amount.tooltip_text = "Deterministic event amount"
	inputs.add_child(_event_amount)
	_button(inputs, "Queue event", "Inject into the isolated simulator queue", _on_queue_event)

	_trace = Tree.new()
	_trace.name = "SimulationTrace"
	_trace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_trace.columns = 4
	_trace.set_column_title(0, "Tick")
	_trace.set_column_title(1, "Kind")
	_trace.set_column_title(2, "Node / edge")
	_trace.set_column_title(3, "Outcome")
	_trace.column_titles_visible = true
	_trace.hide_root = true
	add_child(_trace)


func _button(parent: Control, label: String, tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _line(parent: Control, node_name: String, placeholder: String, tooltip: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.name = node_name
	edit.placeholder_text = placeholder
	edit.tooltip_text = tooltip
	edit.custom_minimum_size.x = 120
	parent.add_child(edit)
	return edit


func _finish_operation(result: Dictionary, running: bool) -> Dictionary:
	var state: Dictionary = _simulator.call("get_state")
	var execution := {"paused": not running, "run_mode": "running" if running else "paused"}
	var projection: Dictionary = _debug_model.call("update_activity", state, _simulator.call("get_trace"), execution)
	activity_projection_changed.emit(projection.duplicate(true))
	state_changed.emit(state.duplicate(true))
	_refresh(result)
	return result


func _refresh(result: Dictionary) -> void:
	if not _built:
		return
	var available := bool(_simulator.call("runtime_availability").get("available", false))
	var started := bool(_simulator.call("is_started"))
	var ok := result.is_empty() or bool(result.get("ok", false))
	var label := "Running · %d trace records" % int(_simulator.call("get_trace").size()) if started else "Ready to start"
	var state: StringName = ComponentState.ACTIVE if started else ComponentState.DEFAULT
	if not available:
		label = "Native runtime unavailable"
		state = ComponentState.DISABLED
	elif not ok:
		var error: Dictionary = result.get("error", result)
		label = "%s · %s" % [String(error.get("code", "LTS-SIM-000")), String(error.get("message", "Simulation failed"))]
		state = ComponentState.ERROR
	_status.call("setup", label, state)
	_start_button.disabled = not available or _graph.is_empty() or started
	_step_button.disabled = not available or not started
	_run_button.disabled = not available or not started
	_reset_button.disabled = not available or _graph.is_empty()
	_rebuild_trace()


func _rebuild_trace() -> void:
	_trace.clear()
	var root := _trace.create_item()
	var records: Array = _simulator.call("get_trace")
	var first := maxi(0, records.size() - 64)
	for index in range(first, records.size()):
		if not records[index] is Dictionary:
			continue
		var record: Dictionary = records[index]
		var item := _trace.create_item(root)
		item.set_text(0, str(record.get("tick", record.get("revision", "—"))))
		item.set_text(1, String(record.get("kind", record.get("operation", "trace"))))
		item.set_text(2, String(record.get("node_identifier", record.get("edge_identifier", "—"))))
		item.set_text(3, String(record.get("outcome_identifier", record.get("status", ""))))


func _on_start() -> void:
	start_simulation()


func _on_step() -> void:
	step_simulation()


func _on_run() -> void:
	run_simulation()


func _on_reset() -> void:
	reset_simulation(true)


func _on_set_fact() -> void:
	var result: Dictionary = _simulator.call("set_fact", _fact_provider.text, _fact_identifier.text, _fact_value.text)
	_refresh(result)


func _on_queue_event() -> void:
	var result: Dictionary = _simulator.call("inject_event", _event_provider.text, _event_identifier.text, null, int(_event_amount.value))
	_refresh(result)
