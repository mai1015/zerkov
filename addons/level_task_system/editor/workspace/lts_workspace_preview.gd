@tool
extends Control

## Standalone preview harness for visual QA of the main-screen shell.
## It uses plain projected dictionaries, so opening this scene does not need a
## saved catalog or a native definition Resource.

const Workspace := preload("res://addons/level_task_system/editor/workspace/lts_workspace.gd")
const Model := preload("res://addons/level_task_system/editor/document/lts_document_model.gd")

var _workspace: Control


func _ready() -> void:
	if _workspace != null:
		return
	_workspace = Workspace.new()
	_workspace.name = "WorkspacePreview"
	_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_workspace.set_native_extension_available(true)
	_workspace.set_document_model(Model.new(_preview_state))
	add_child(_workspace)
	var view := "task_graph"
	var drawer := ""
	for argument in OS.get_cmdline_user_args():
		if argument == "--view=conversation":
			view = "conversation"
		elif argument.begins_with("--drawer="):
			drawer = argument.trim_prefix("--drawer=")
	var identifier := "preview.conversation.guide" if view == "conversation" else "preview.task.main"
	call_deferred("_open_preview", view, identifier, drawer)


func _open_preview(view: String, identifier: String, drawer: String) -> void:
	_workspace.call("open_document", view, identifier)
	match drawer:
		"simulation":
			_workspace.call("open_simulation_shell")
		"trace":
			_workspace.call("open_live_debugger")
		"conversation":
			_workspace.call("open_conversation_preview")


var _preview_state: Dictionary:
	get:
		return {
			"documents": {
				"task_graphs": {
					"preview.task.main": {
						"kind": "task_graph",
						"identifier": "preview.task.main",
						"schema_version": 1,
						"entry_node_identifier": "entry",
						"terminal_outcomes": ["success", "failure"],
						"nodes": [
							{"identifier": "entry", "kind": 0, "ports": [{"identifier": "next", "direction": 1, "value_type": 0}]},
							{"identifier": "objective", "kind": 1, "objective_target": 3, "ports": [{"identifier": "input", "direction": 0, "value_type": 0}, {"identifier": "complete", "direction": 1, "value_type": 0}]},
							{"identifier": "condition", "kind": 2, "ports": [{"identifier": "input", "direction": 0, "value_type": 0}, {"identifier": "true", "direction": 1, "value_type": 0}, {"identifier": "false", "direction": 1, "value_type": 0}]},
							{"identifier": "done", "kind": 9, "ports": [{"identifier": "input", "direction": 0, "value_type": 0}]},
							{"identifier": "failed", "kind": 10, "ports": [{"identifier": "input", "direction": 0, "value_type": 0}]},
						],
						"edges": [
							{"identifier": "edge.entry.objective", "from_node_identifier": "entry", "from_port_identifier": "next", "to_node_identifier": "objective", "to_port_identifier": "input"},
							{"identifier": "edge.objective.condition", "from_node_identifier": "objective", "from_port_identifier": "complete", "to_node_identifier": "condition", "to_port_identifier": "input"},
							{"identifier": "edge.condition.done", "from_node_identifier": "condition", "from_port_identifier": "true", "to_node_identifier": "done", "to_port_identifier": "input"},
							{"identifier": "edge.condition.failed", "from_node_identifier": "condition", "from_port_identifier": "false", "to_node_identifier": "failed", "to_port_identifier": "input"},
						],
					},
				},
				"conversations": {
					"preview.conversation.guide": {
						"kind": "conversation",
						"identifier": "preview.conversation.guide",
						"schema_version": 1,
						"entry_label": "start",
						"terminal_outcomes": ["complete"],
						"steps": [
							{"identifier": "start", "kind": 0, "speaker_identifier": "preview.speaker.guide", "line_key": "dialogue.guide.start", "next_step_identifier": "complete", "choices": []},
							{"identifier": "complete", "kind": 5, "outcome_identifier": "complete", "choices": []},
						],
					},
				},
			},
		}
