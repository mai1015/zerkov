@tool
class_name LtsWorkspace
extends Control

## Main-screen authoring shell for Level Task System.
##
## The workspace is intentionally a projection: the document model owns
## semantic state, while GraphEdit, Tree, the Inspector and the drawer only
## render the current snapshot.  The implementation is useful with an empty
## project, a partially loaded catalog, or a missing native extension.  The
## graph and conversation surfaces are reusable editors over that same model;
## the workspace only coordinates navigation, validation, persistence, and
## contextual inspection.

const WorkspaceState := preload("res://addons/level_task_system/editor/workspace/lts_workspace_state.gd")
const DocumentModel := preload("res://addons/level_task_system/editor/document/lts_document_model.gd")
const DocumentCommand := preload("res://addons/level_task_system/editor/document/lts_document_command.gd")
const DocumentProjection := preload("res://addons/level_task_system/editor/document/lts_document_projection.gd")
const ComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const CommandButton := preload("res://addons/level_task_system/editor/components/lts_command_button.gd")
const IconButton := preload("res://addons/level_task_system/editor/components/lts_icon_button.gd")
const SearchField := preload("res://addons/level_task_system/editor/components/lts_search_field.gd")
const BreadcrumbItem := preload("res://addons/level_task_system/editor/components/lts_breadcrumb_item.gd")
const GraphNodeCard := preload("res://addons/level_task_system/editor/components/lts_graph_node_card.gd")
const InspectorField := preload("res://addons/level_task_system/editor/components/lts_inspector_field.gd")
const StatusBadge := preload("res://addons/level_task_system/editor/components/lts_status_badge.gd")
const EmptyState := preload("res://addons/level_task_system/editor/components/lts_empty_state.gd")
const DegradedState := preload("res://addons/level_task_system/editor/components/lts_degraded_state.gd")
const DocumentValidator := preload("res://addons/level_task_system/editor/validation/lts_document_validator.gd")
const FindingsStore := preload("res://addons/level_task_system/editor/validation/lts_findings_store.gd")
const FindingsPanel := preload("res://addons/level_task_system/editor/validation/lts_findings_panel.gd")
const GraphCanvas := preload("res://addons/level_task_system/editor/graph/lts_graph_canvas.gd")
const ConversationEditor := preload("res://addons/level_task_system/editor/conversation/lts_conversation_editor.gd")
const TaskSimulatorPanel := preload("res://addons/level_task_system/editor/simulation/lts_task_simulator_panel.gd")
const ConversationPreview := preload("res://addons/level_task_system/editor/simulation/lts_conversation_preview.gd")
const LiveRuntimeDebugger := preload("res://addons/level_task_system/editor/debug/lts_live_runtime_debugger.gd")

signal resource_opened(kind: String, identifier: String, source_path: String)
signal resource_created(kind: String, identifier: String, source_path: String)
signal command_invoked(command_name: String)
signal finding_activated(finding: Dictionary)
signal native_refresh_requested

const RESOURCE_SCAN_LIMIT := 512
const RECENT_RESOURCE_LIMIT := 8
const RECENT_SETTINGS_KEY := "level_task_system/editor/recent_resources"

var native_extension_available := true
var undo_redo: Object = null
var _document_model: Object = null
var _model_supplied := false
var _current_resource: Resource = null
var _current_kind := ""
var _current_identifier := ""
var _current_path := ""
var _subgraph_identifier := ""
var _recent_resources: Array = []
var _findings: Array = []
var _dirty := false
var _last_validation_label := "Not validated"
var _replaying_undo := false
var _building := false
var _built := false
var _drawer_collapsed := false
var _navigator_collapsed := false
var _inspector_collapsed := false
var _auto_navigator_collapsed := false
var _auto_inspector_collapsed := false
var _auto_drawer_collapsed := false

# Command bar
var _breadcrumb_bar: HBoxContainer
var _dirty_badge: StatusBadge
var _severity_badge: StatusBadge
var _save_button: CommandButton
var _validate_button: CommandButton
var _simulate_button: CommandButton
var _new_button: MenuButton
var _overflow_button: MenuButton
var _search_field: SearchField
var _navigator_toggle: IconButton
var _inspector_toggle: IconButton
var _drawer_toggle: CommandButton

# Main frame
var _navigator_panel: PanelContainer
var _navigator_tree: Tree
var _navigator_empty: EmptyState
var _center_panel: PanelContainer
var _center_header: HBoxContainer
var _center_title: Label
var _center_subtitle: Label
var _center_content: Control
var _center_empty: EmptyState
var _center_degraded: DegradedState
var _graph_canvas: GraphEdit
var _graph_toolbar: HBoxContainer
var _conversation_editor: Control
# Retained only for the legacy projection helper below; the main screen now
# mounts LtsConversationEditor instead of these placeholder controls.
var _conversation_timeline: ScrollContainer = null
var _conversation_text: TextEdit = null
var _level_view: ScrollContainer
var _inspector_panel: PanelContainer
var _inspector_content: VBoxContainer
var _drawer_panel: PanelContainer
var _drawer_tabs: TabBar
var _drawer_content: Control
var _findings_panel: FindingsPanel
var _findings_store: FindingsStore
var _drawer_message: Label
var _task_simulator_panel: Control
var _conversation_preview: Control
var _conversation_preview_identifier := ""
var _live_runtime_debugger: Control

var _graph_node_controls: Dictionary = {}
var _graph_port_indices: Dictionary = {}
var _creation_dialog: ConfirmationDialog
var _creation_kind := ""
var _creation_identifier_edit: LineEdit
var _creation_path_edit: LineEdit
var _creation_error_label: Label


static func supported_resource_kind(resource: Variant) -> String:
	return WorkspaceState.supported_resource_kind(resource)


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	if _built:
		return
	_built = true
	ComponentTheme.inherit_editor_theme(self)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_recent_resources = _load_recent_resources()
	if _document_model == null:
		if _model_supplied:
			_document_model = DocumentModel.new(null, native_extension_available)
		else:
			_document_model = _scan_project_model()
	_build_shell()
	_refresh_all()
	call_deferred("_update_narrow_layout")


## Configure the extension state before the plugin adds this control to the
## editor main screen.  A missing extension never leaves half-enabled actions.
func set_native_extension_available(available: bool) -> void:
	native_extension_available = available
	if not _built:
		return
	if not available:
		_document_model = DocumentModel.new(null, false)
	else:
		if not _model_supplied:
			_document_model = _scan_project_model()
		elif _document_model == null or (_document_model.has_method("is_degraded") and _document_model.call("is_degraded")):
			_document_model = DocumentModel.new(null, true)
	_refresh_all()


func is_native_extension_available() -> bool:
	return native_extension_available


func set_document_model(model: Object) -> void:
	if model == null:
		return
	_document_model = model
	_model_supplied = true
	if _built:
		_refresh_all()


func get_document_model() -> Object:
	return _document_model


func get_current_context() -> Dictionary:
	return {
		"kind": _current_kind,
		"identifier": _current_identifier,
		"source_path": _current_path,
		"subgraph_identifier": _subgraph_identifier,
		"dirty": _dirty,
	}


func get_findings() -> Array:
	return _findings.duplicate(true)


func get_findings_store() -> Variant:
	return _findings_store


func get_task_simulator_panel() -> Control:
	return _task_simulator_panel


func get_conversation_preview() -> Control:
	return _conversation_preview


func get_live_runtime_debugger() -> Control:
	return _live_runtime_debugger


func ingest_live_runtime_feed(feed: Variant) -> Dictionary:
	if _live_runtime_debugger == null or not _live_runtime_debugger.has_method("ingest"):
		return {"ok": false, "error": {"code": "LTS-LIVE-000", "message": "Live debugger is unavailable.", "path": "workspace.live_runtime"}}
	return _live_runtime_debugger.call("ingest", feed)


## Public seam for the validation workstream.  The panel owns filtering and
## severity presentation; the workspace owns navigation to the target.
func set_findings(findings: Array) -> void:
	_findings = findings.duplicate(true)
	if _findings_store != null:
		_findings_store.replace_all(_findings)
	if _findings_panel != null:
		_findings_panel.set_findings(_findings)
	_refresh_command_bar()
	_refresh_drawer()


func get_recent_resources() -> Array:
	return _recent_resources.duplicate(true)


func get_navigation_projection() -> Dictionary:
	if _document_model == null or not _document_model.has_method("navigation_projection"):
		return {"groups": [], "entries": [], "empty": true}
	return _document_model.call("navigation_projection", _search_field.text if _search_field != null else "")


## Open a resource from the FileSystem dock or a navigator entry.  The
## projection is merged into the existing model so opening one file never
## discards the author's other navigable resources.
func open_resource(resource: Variant, source_path: String = "") -> bool:
	if resource == null and not source_path.is_empty():
		resource = ResourceLoader.load(source_path)
	var kind := WorkspaceState.supported_resource_kind(resource)
	if kind.is_empty():
		return false
	var projected := DocumentProjection.project_resource(resource, source_path)
	var identifier := String(projected.get("identifier", ""))
	if identifier.is_empty():
		_current_resource = resource if resource is Resource else null
		_current_kind = kind
		_current_identifier = ""
		_current_path = source_path
		_findings = WorkspaceState.findings_for_document(kind, identifier, projected, native_extension_available)
		_refresh_all()
		return false
	_merge_projected_document(projected, kind, identifier)
	_current_resource = resource if resource is Resource else null
	_current_kind = kind
	_current_identifier = identifier
	_current_path = source_path if not source_path.is_empty() else String(projected.get("source_path", ""))
	_subgraph_identifier = ""
	_dirty = false
	_add_recent_resource({
		"kind": kind,
		"identifier": identifier,
		"source_path": _current_path,
		"label": WorkspaceState.resource_display_name(projected, identifier),
	})
	_apply_navigation_context()
	_refresh_all()
	resource_opened.emit(kind, identifier, _current_path)
	return true


func open_document(kind: String, identifier: String, source_path: String = "") -> bool:
	if _document_model == null:
		return false
	var normalized := WorkspaceState.normalize_kind(kind)
	if not _document_model.call("has_document", normalized, identifier):
		return false
	_current_resource = null
	_current_kind = normalized
	_current_identifier = identifier
	var document: Dictionary = _document_model.call("get_document", normalized, identifier)
	_current_path = source_path if not source_path.is_empty() else String(document.get("source_path", ""))
	_subgraph_identifier = ""
	_dirty = false
	_add_recent_resource({
		"kind": normalized,
		"identifier": identifier,
		"source_path": _current_path,
		"label": WorkspaceState.resource_display_name(document, identifier),
	})
	_apply_navigation_context()
	_refresh_all()
	resource_opened.emit(normalized, identifier, _current_path)
	return true


func open_project_overview() -> void:
	_current_resource = null
	_current_kind = WorkspaceState.KIND_PROJECT
	_current_identifier = ""
	_current_path = ""
	_subgraph_identifier = ""
	_apply_navigation_context()
	_refresh_all()


func open_simulation_shell() -> void:
	# Keep an open graph selected so the simulator can compile exactly the
	# authored definition the user was inspecting.
	if _current_kind != WorkspaceState.KIND_TASK_GRAPH:
		_current_kind = WorkspaceState.KIND_SIMULATION
		_current_identifier = ""
		_current_resource = null
	if _drawer_tabs != null:
		_drawer_tabs.current_tab = 1
	_set_drawer_collapsed(false, false)
	_refresh_all()


func open_diagnostics() -> void:
	if _drawer_tabs != null:
		_drawer_tabs.current_tab = 0
	_set_drawer_collapsed(false, false)
	_refresh_drawer()


func open_live_debugger() -> void:
	if _drawer_tabs != null:
		_drawer_tabs.current_tab = 2
	_set_drawer_collapsed(false, false)
	_refresh_drawer()


func open_conversation_preview() -> void:
	if _drawer_tabs != null:
		_drawer_tabs.current_tab = 3
	_set_drawer_collapsed(false, false)
	_refresh_drawer()


func refresh_resources() -> void:
	if _model_supplied:
		_refresh_all()
		return
	_document_model = _scan_project_model()
	_refresh_all()


func validate() -> Array:
	_validate_current()
	return get_findings()


func save() -> bool:
	return _save_current()


func create_resource(kind: String, identifier: String, source_path: String = "") -> bool:
	if not native_extension_available:
		_show_degraded_status()
		return false
	var spec := WorkspaceState.creation_spec(kind, identifier, "res://")
	var normalized := String(spec.get("kind", ""))
	var final_identifier := String(spec.get("identifier", ""))
	if normalized.is_empty() or final_identifier.is_empty():
		return false
	var final_path := source_path if not source_path.is_empty() else String(spec.get("path", ""))
	if not _valid_resource_path(final_path):
		_set_command_status("Error LTS-CREATE-001: choose a res:// .tres or .res path.", ComponentState.ERROR)
		return false
	if ResourceLoader.exists(final_path):
		_set_command_status("Error LTS-CREATE-002: resource already exists at %s." % final_path, ComponentState.ERROR)
		return false
	var class_names := WorkspaceState.class_names_for_kind(normalized)
	var resource: Object = null
	for candidate_class_name in class_names:
		if ClassDB.class_exists(StringName(candidate_class_name)):
			resource = ClassDB.instantiate(StringName(candidate_class_name))
			if resource != null:
				break
	if resource == null or not resource is Resource:
		_set_command_status("Error LTS-NATIVE-002: %s class is unavailable." % WorkspaceState.kind_label(normalized), ComponentState.ERROR)
		return false
	if resource.has_method("set_identifier"):
		resource.call("set_identifier", StringName(final_identifier))
	var save_error := ResourceSaver.save(resource, final_path)
	if save_error != OK:
		_set_command_status("Error LTS-CREATE-003: could not save %s (code %d)." % [final_path, save_error], ComponentState.ERROR)
		return false
	resource_created.emit(normalized, final_identifier, final_path)
	_current_resource = resource
	open_resource(resource, final_path)
	_set_command_status("Created %s at %s." % [WorkspaceState.kind_label(normalized), final_path], ComponentState.ACTIVE)
	return true


func _build_shell() -> void:
	if _building:
		return
	_building = true
	var root_column := VBoxContainer.new()
	root_column.name = "MainScreenFrame"
	root_column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root_column)
	root_column.add_child(_build_command_bar())
	var command_separator := HSeparator.new()
	command_separator.name = "CommandBarSeparator"
	root_column.add_child(command_separator)
	var body := HSplitContainer.new()
	body.name = "WorkspaceBody"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_column.add_child(body)
	_navigator_panel = _build_navigator()
	body.add_child(_navigator_panel)
	_center_panel = _build_center_panel()
	_center_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_center_panel)
	_inspector_panel = _build_inspector_panel()
	body.add_child(_inspector_panel)
	_drawer_panel = _build_drawer_panel()
	root_column.add_child(_drawer_panel)
	_build_creation_dialog()
	resized.connect(_on_workspace_resized)
	_building = false


func _build_command_bar() -> Control:
	var bar := PanelContainer.new()
	bar.name = "CommandBar"
	bar.theme_type_variation = &"LevelTaskDrawer"
	var row := HBoxContainer.new()
	row.name = "CommandRow"
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(row)
	_breadcrumb_bar = HBoxContainer.new()
	_breadcrumb_bar.name = "Breadcrumbs"
	_breadcrumb_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_breadcrumb_bar)
	_dirty_badge = StatusBadge.new()
	_dirty_badge.name = "DirtyState"
	_dirty_badge.call("setup", "Saved", ComponentState.DEFAULT)
	row.add_child(_dirty_badge)
	_severity_badge = StatusBadge.new()
	_severity_badge.name = "SeverityCount"
	_severity_badge.call("setup", "No findings", ComponentState.DEFAULT)
	row.add_child(_severity_badge)
	_save_button = _command("Save", [&"Save"], "Save the current resource (Ctrl+S)", "save")
	row.add_child(_save_button)
	_validate_button = _command("Validate", [&"Validation", &"Check"], "Validate the current resource", "validate")
	row.add_child(_validate_button)
	_simulate_button = _command("Simulate", [&"Play"], "Open the isolated simulator shell (task 8.1)", "simulate")
	row.add_child(_simulate_button)
	_new_button = MenuButton.new()
	_new_button.name = "NewResource"
	_new_button.text = "New"
	_new_button.tooltip_text = "Create a Level Task System resource"
	_new_button.focus_mode = Control.FOCUS_ALL
	var new_popup := _new_button.get_popup()
	for index in range(WorkspaceState.creation_kinds().size()):
		var kind := WorkspaceState.creation_kinds()[index]
		new_popup.add_item("Create %s" % WorkspaceState.kind_label(kind), index)
	new_popup.id_pressed.connect(_on_creation_kind_selected)
	row.add_child(_new_button)
	_overflow_button = MenuButton.new()
	_overflow_button.name = "CommandOverflow"
	_overflow_button.text = "More"
	_overflow_button.tooltip_text = "More workspace actions"
	_overflow_button.focus_mode = Control.FOCUS_ALL
	var overflow_popup := _overflow_button.get_popup()
	overflow_popup.add_item("Simulate", 1)
	overflow_popup.add_item("Refresh resources", 2)
	overflow_popup.add_item("Open diagnostics", 3)
	overflow_popup.add_item("Create task graph", 4)
	overflow_popup.id_pressed.connect(_on_overflow_action)
	row.add_child(_overflow_button)
	_search_field = SearchField.new()
	_search_field.name = "ResourceSearch"
	_search_field.call("setup", "Search resources (Ctrl+P)")
	_search_field.custom_minimum_size = Vector2(maxf(200.0, _theme_unit() * 18.0), 0)
	_search_field.size_flags_horizontal = Control.SIZE_SHRINK_END
	_search_field.query_changed.connect(_on_search_changed)
	row.add_child(_search_field)
	_navigator_toggle = _icon("Navigator", [&"Panels", &"Panel"], "Toggle navigator", "toggle_navigator")
	row.add_child(_navigator_toggle)
	_inspector_toggle = _icon("Inspector", [&"Inspector", &"Edit"], "Toggle contextual Inspector", "toggle_inspector")
	row.add_child(_inspector_toggle)
	_drawer_toggle = _command("Findings", [&"Warning", &"Error"], "Show or hide the findings drawer", "toggle_drawer")
	row.add_child(_drawer_toggle)
	return bar


func _build_navigator() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "Navigator"
	panel.theme_type_variation = &"LevelTaskDrawer"
	panel.custom_minimum_size = Vector2(maxf(220.0, _theme_unit() * 18.0), 0)
	var column := VBoxContainer.new()
	column.name = "NavigatorColumn"
	panel.add_child(column)
	var heading_row := HBoxContainer.new()
	column.add_child(heading_row)
	var heading := Label.new()
	heading.name = "NavigatorHeading"
	heading.text = "Navigator"
	heading.tooltip_text = "Project resources and workspace views"
	heading_row.add_child(heading)
	heading_row.add_spacer(false)
	var refresh_button := IconButton.new()
	refresh_button.name = "RefreshResources"
	refresh_button.call("setup", "Refresh resources", [&"Reload", &"Refresh"])
	refresh_button.action_requested.connect(refresh_resources)
	heading_row.add_child(refresh_button)
	var scope_label := Label.new()
	scope_label.name = "NavigatorScope"
	scope_label.text = "Project resources"
	scope_label.tooltip_text = scope_label.text
	column.add_child(scope_label)
	_navigator_tree = Tree.new()
	_navigator_tree.name = "ResourceTree"
	_navigator_tree.hide_root = true
	_navigator_tree.columns = 2
	_navigator_tree.focus_mode = Control.FOCUS_ALL
	_navigator_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_navigator_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_navigator_tree.item_activated.connect(_on_navigator_item_activated)
	_navigator_tree.item_selected.connect(_on_navigator_item_selected)
	column.add_child(_navigator_tree)
	_navigator_empty = EmptyState.new()
	_navigator_empty.name = "NavigatorEmpty"
	_navigator_empty.call("setup", "No resources match", "Clear the search filter or create the first Level Task System resource.", "Create resource")
	_navigator_empty.action_requested.connect(_on_navigator_empty_action)
	_navigator_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_navigator_empty)
	return panel


func _build_center_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "CenterWorkspace"
	panel.theme_type_variation = &"LevelTaskDrawer"
	var column := VBoxContainer.new()
	column.name = "CenterColumn"
	panel.add_child(column)
	_center_header = HBoxContainer.new()
	_center_header.name = "CenterHeader"
	column.add_child(_center_header)
	_center_title = Label.new()
	_center_title.name = "CenterTitle"
	_center_title.text = "Level Task workspace"
	_center_title.tooltip_text = _center_title.text
	_center_header.add_child(_center_title)
	_center_header.add_spacer(false)
	_center_subtitle = Label.new()
	_center_subtitle.name = "CenterSubtitle"
	_center_subtitle.text = "Select a resource to begin"
	_center_subtitle.tooltip_text = _center_subtitle.text
	_center_header.add_child(_center_subtitle)
	_graph_toolbar = HBoxContainer.new()
	_graph_toolbar.name = "GraphToolbar"
	_center_header.add_child(_graph_toolbar)
	var grid_button := _icon("Grid", [&"grid_toggle", &"Grid"], "Toggle graph grid", "toggle_grid")
	_graph_toolbar.add_child(grid_button)
	var snap_button := _icon("Snap", [&"snapping_toggle", &"Snap"], "Toggle graph snapping", "toggle_snap")
	_graph_toolbar.add_child(snap_button)
	var minimap_button := _icon("Minimap", [&"minimap_toggle", &"Map"], "Toggle graph minimap", "toggle_minimap")
	_graph_toolbar.add_child(minimap_button)
	var arrange_button := _command("Arrange", [&"layout", &"Sort"], "Deterministically arrange visible nodes", "arrange")
	_graph_toolbar.add_child(arrange_button)
	_center_content = Control.new()
	_center_content.name = "ContentHost"
	_center_content.clip_contents = true
	_center_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_center_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_center_content)
	_graph_canvas = _build_graph_canvas()
	_center_content.add_child(_graph_canvas)
	_graph_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_conversation_editor = _build_conversation_editor()
	_center_content.add_child(_conversation_editor)
	_conversation_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_level_view = _build_level_view()
	_center_content.add_child(_level_view)
	_level_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center_empty = EmptyState.new()
	_center_empty.name = "CenterEmpty"
	_center_empty.call("setup", "No resource selected", "Choose a level, task graph, or conversation from the navigator.", "Create task graph")
	_center_empty.action_requested.connect(_on_center_empty_action)
	_center_content.add_child(_center_empty)
	_center_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center_degraded = DegradedState.new()
	_center_degraded.name = "NativeExtensionDiagnostic"
	_center_degraded.call("setup", "Native extension unavailable", "Build and load the Level Task System GDExtension before editing definitions.", _native_details())
	_center_degraded.refresh_requested.connect(_on_native_refresh)
	_center_degraded.copy_requested.connect(_copy_native_details)
	_center_content.add_child(_center_degraded)
	_center_degraded.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return panel


func _build_graph_canvas() -> GraphEdit:
	var graph = GraphCanvas.new()
	graph.name = "TaskGraphCanvas"
	graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.default_snapping_distance = maxi(1, int(_theme_unit() * 2.0))
	graph.default_minimap_size = Vector2(_theme_unit() * 18.0, _theme_unit() * 12.0)
	graph.selection_projection_changed.connect(_on_graph_selection_projection_changed)
	graph.command_applied.connect(_on_graph_editor_command_applied)
	graph.command_rejected.connect(_on_graph_editor_command_rejected)
	graph.subgraph_navigation_requested.connect(_on_graph_subgraph_navigation_requested)
	graph.connection_feedback_changed.connect(_on_graph_connection_feedback_changed)
	return graph


func _build_conversation_editor() -> Control:
	var editor = ConversationEditor.new()
	editor.name = "ConversationEditor"
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.selection_changed.connect(_on_conversation_selection_changed)
	editor.command_applied.connect(_on_conversation_command_applied)
	editor.validation_changed.connect(_on_conversation_validation_changed)
	editor.save_requested.connect(_on_conversation_save_requested)
	return editor


func _build_level_view() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "LevelView"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var column := VBoxContainer.new()
	column.name = "LevelColumn"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	return scroll


func _build_inspector_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "ContextualInspector"
	panel.theme_type_variation = &"LevelTaskDrawer"
	panel.custom_minimum_size = Vector2(maxf(260.0, _theme_unit() * 22.0), 0)
	var scroll := ScrollContainer.new()
	scroll.name = "InspectorScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	_inspector_content = VBoxContainer.new()
	_inspector_content.name = "InspectorContent"
	_inspector_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_inspector_content)
	return panel


func _build_drawer_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "DiagnosticsDrawer"
	panel.theme_type_variation = &"LevelTaskDrawer"
	panel.custom_minimum_size = Vector2(0, maxf(144.0, _theme_unit() * 18.0))
	var column := VBoxContainer.new()
	column.name = "DrawerColumn"
	panel.add_child(column)
	var header := HBoxContainer.new()
	header.name = "DrawerHeader"
	column.add_child(header)
	var title := Label.new()
	title.name = "DrawerTitle"
	title.text = "Workspace drawer"
	title.tooltip_text = "Findings, simulation shell, trace, and conversation preview"
	header.add_child(title)
	header.add_spacer(false)
	_drawer_message = Label.new()
	_drawer_message.name = "DrawerSummary"
	_drawer_message.text = "No findings"
	_drawer_message.tooltip_text = _drawer_message.text
	header.add_child(_drawer_message)
	_drawer_tabs = TabBar.new()
	_drawer_tabs.name = "DrawerTabs"
	_drawer_tabs.focus_mode = Control.FOCUS_ALL
	_drawer_tabs.add_tab("Findings")
	_drawer_tabs.add_tab("Simulation")
	_drawer_tabs.add_tab("Trace")
	_drawer_tabs.add_tab("Conversation preview")
	_drawer_tabs.tab_changed.connect(_on_drawer_tab_changed)
	column.add_child(_drawer_tabs)
	_drawer_content = Control.new()
	_drawer_content.name = "DrawerContent"
	_drawer_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawer_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_drawer_content)
	_findings_store = FindingsStore.new()
	_findings_panel = FindingsPanel.new()
	_findings_panel.name = "FindingsPanel"
	_findings_panel.set_store(_findings_store)
	_findings_panel.finding_activated.connect(_on_finding_target_activated)
	_findings_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_findings_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_drawer_content.add_child(_findings_panel)
	_findings_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_task_simulator_panel = TaskSimulatorPanel.new()
	_task_simulator_panel.name = "TaskSimulatorPanel"
	_drawer_content.add_child(_task_simulator_panel)
	_task_simulator_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_task_simulator_panel.visible = false
	_live_runtime_debugger = LiveRuntimeDebugger.new()
	_live_runtime_debugger.name = "LiveRuntimeDebugger"
	_drawer_content.add_child(_live_runtime_debugger)
	_live_runtime_debugger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_live_runtime_debugger.visible = false
	_conversation_preview = ConversationPreview.new()
	_conversation_preview.name = "ConversationPreview"
	_drawer_content.add_child(_conversation_preview)
	_conversation_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_conversation_preview.visible = false
	return panel


func _build_creation_dialog() -> void:
	_creation_dialog = ConfirmationDialog.new()
	_creation_dialog.name = "CreateResourceDialog"
	_creation_dialog.title = "Create Level Task System resource"
	_creation_dialog.ok_button_text = "Create"
	_creation_dialog.cancel_button_text = "Cancel"
	_creation_dialog.confirmed.connect(_on_creation_confirmed)
	add_child(_creation_dialog)
	var column := VBoxContainer.new()
	column.name = "CreationColumn"
	_creation_dialog.add_child(column)
	var kind_label := Label.new()
	kind_label.name = "CreationKind"
	column.add_child(kind_label)
	_creation_identifier_edit = LineEdit.new()
	_creation_identifier_edit.name = "Identifier"
	_creation_identifier_edit.placeholder_text = "domain.resource"
	_creation_identifier_edit.tooltip_text = "Stable identifier; it becomes part of runtime identity."
	_creation_identifier_edit.focus_mode = Control.FOCUS_ALL
	column.add_child(_creation_identifier_edit)
	_creation_path_edit = LineEdit.new()
	_creation_path_edit.name = "Path"
	_creation_path_edit.placeholder_text = "res://domain_resource.tres"
	_creation_path_edit.tooltip_text = "Saved resource path under res://"
	_creation_path_edit.focus_mode = Control.FOCUS_ALL
	column.add_child(_creation_path_edit)
	_creation_error_label = Label.new()
	_creation_error_label.name = "CreationError"
	_creation_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_creation_error_label)


func _command(label: String, icons: Array, tooltip: String, action: String) -> CommandButton:
	var button := CommandButton.new()
	button.name = label.replace(" ", "")
	button.call("setup", label, icons, tooltip)
	button.set_meta("lts_action", action)
	button.command_requested.connect(_on_command_button_requested.bind(action))
	return button


func _icon(label: String, icons: Array, tooltip: String, action: String) -> IconButton:
	var button := IconButton.new()
	button.name = label
	button.call("setup", label, icons)
	button.tooltip_text = tooltip
	button.set_meta("lts_action", action)
	button.action_requested.connect(_on_icon_button_requested.bind(action))
	return button


func _refresh_all() -> void:
	if not _built or _document_model == null:
		return
	_refresh_navigator()
	_refresh_breadcrumbs()
	_refresh_command_bar()
	_refresh_center()
	_refresh_inspector()
	_refresh_drawer()
	_update_narrow_layout()


func _refresh_navigator() -> void:
	if _navigator_tree == null:
		return
	_navigator_tree.clear()
	var root := _navigator_tree.create_item()
	var entries: Array = []
	var query := _search_field.text if _search_field != null else ""
	if _document_model != null and _document_model.has_method("navigation_projection"):
		var projection: Dictionary = _document_model.call("navigation_projection", query)
		entries = WorkspaceState.flatten_navigation(projection)
	_add_tree_item(root, "Project", WorkspaceState.KIND_PROJECT, "", "Project overview", "")
	_add_tree_item(root, "Simulation", WorkspaceState.KIND_SIMULATION, "", "Open simulation shell", "")
	_add_tree_item(root, "Diagnostics", WorkspaceState.KIND_DIAGNOSTICS, "", "Open validation findings", "")
	var recent_group := _navigator_tree.create_item(root)
	recent_group.set_text(0, "Recent")
	recent_group.set_tooltip_text(0, "Recently opened Level Task System resources")
	recent_group.set_selectable(0, false)
	var visible_recents := WorkspaceState.filter_entries(_recent_resources, query)
	for recent in visible_recents:
		if not recent is Dictionary:
			continue
		var item := _navigator_tree.create_item(recent_group)
		item.set_text(0, String(recent.get("label", recent.get("identifier", "Resource"))))
		item.set_text(1, String(recent.get("source_path", "")))
		item.set_tooltip_text(0, String(recent.get("source_path", recent.get("identifier", ""))))
		item.set_metadata(0, {
			"kind": String(recent.get("kind", "")),
			"identifier": String(recent.get("identifier", "")),
			"source_path": String(recent.get("source_path", "")),
		})
		item.set_icon(0, _resource_icon(String(recent.get("kind", ""))))
	for group in WorkspaceState.COLLECTION_ORDER:
		var group_item := _navigator_tree.create_item(root)
		group_item.set_text(0, WorkspaceState.collection_label(group))
		group_item.set_tooltip_text(0, "Browse %s" % WorkspaceState.collection_label(group))
		group_item.set_selectable(0, false)
		for entry in entries:
			if not entry is Dictionary or String(entry.get("collection", "")) != group:
				continue
			var item := _navigator_tree.create_item(group_item)
			var identifier := String(entry.get("identifier", ""))
			var label := String(entry.get("label", identifier))
			item.set_text(0, label if not label.is_empty() else identifier)
			item.set_text(1, identifier)
			item.set_tooltip_text(0, String(entry.get("source_path", identifier)))
			item.set_metadata(0, {
				"kind": String(entry.get("kind", WorkspaceState.KIND_FROM_COLLECTION.get(group, ""))),
				"identifier": identifier,
				"source_path": String(entry.get("source_path", "")),
			})
			item.set_icon(0, _resource_icon(String(entry.get("kind", ""))))
	var has_entries := not entries.is_empty() or not visible_recents.is_empty()
	_navigator_tree.visible = true
	_navigator_empty.visible = not has_entries
	if not has_entries:
		if query.is_empty():
			_navigator_empty.call("setup", "No resources yet", "Create a level, task graph, or conversation to populate the navigator.", "Create resource")
		else:
			_navigator_empty.call("setup", "No resources match", "Clear the search filter or adjust the resource query.", "Clear search")


func _add_tree_item(root: TreeItem, label: String, kind: String, identifier: String, tooltip: String, source_path: String) -> TreeItem:
	var item := _navigator_tree.create_item(root)
	item.set_text(0, label)
	item.set_tooltip_text(0, tooltip)
	item.set_metadata(0, {"kind": kind, "identifier": identifier, "source_path": source_path})
	if kind in [WorkspaceState.KIND_PROJECT, WorkspaceState.KIND_SIMULATION, WorkspaceState.KIND_DIAGNOSTICS]:
		item.set_icon(0, _resource_icon(kind))
	return item


func _refresh_breadcrumbs() -> void:
	if _breadcrumb_bar == null:
		return
	for child in _breadcrumb_bar.get_children():
		# Breadcrumbs are a synchronous projection.  Free the previous controls
		# before reconnecting the new set so repeated navigation does not leave
		# stale focus targets queued across frames.
		child.free()
	var crumbs := WorkspaceState.breadcrumbs(_current_kind if _current_kind not in [WorkspaceState.KIND_PROJECT, WorkspaceState.KIND_SIMULATION, WorkspaceState.KIND_DIAGNOSTICS] else "", _current_identifier, _subgraph_identifier)
	for index in range(crumbs.size()):
		if index > 0:
			var separator := Label.new()
			separator.text = "/"
			separator.tooltip_text = "Breadcrumb separator"
			_breadcrumb_bar.add_child(separator)
		var crumb: Dictionary = crumbs[index]
		var button := BreadcrumbItem.new()
		button.name = "Breadcrumb_%d" % index
		button.call("setup", String(crumb.get("label", "Project")), String(crumb.get("path", "project")), ComponentState.ACTIVE if bool(crumb.get("current", false)) else ComponentState.DEFAULT)
		button.set_meta("lts_breadcrumb", crumb.duplicate(true))
		button.breadcrumb_activated.connect(_on_breadcrumb_activated.bind(crumb.duplicate(true)))
		_breadcrumb_bar.add_child(button)


func _refresh_command_bar() -> void:
	if _dirty_badge == null:
		return
	_dirty_badge.call("setup", "Unsaved changes" if _dirty else "Saved", ComponentState.ACTIVE if _dirty else ComponentState.DEFAULT)
	var counts := WorkspaceState.severity_counts(_findings)
	var total := int(counts.get("total", 0))
	var severity_state := ComponentState.ERROR if int(counts.get("error", 0)) > 0 else ComponentState.ACTIVE if int(counts.get("warning", 0)) > 0 else ComponentState.DEFAULT
	_severity_badge.call("setup", "%d finding%s" % [total, "" if total == 1 else "s"] if total > 0 else "No findings", severity_state)
	_save_button.call("set_state", ComponentState.ACTIVE if _dirty else ComponentState.DISABLED)
	_save_button.set_host_blocked(not _can_edit_current(), "Save is available after a resource is selected and the native extension is ready.")
	_validate_button.call("set_state", ComponentState.DEFAULT if native_extension_available else ComponentState.DISABLED)
	_validate_button.set_host_blocked(not native_extension_available, "Validation requires the native extension.")
	_simulate_button.call("set_state", ComponentState.DEFAULT)
	_simulate_button.set_host_blocked(_current_kind != WorkspaceState.KIND_TASK_GRAPH, "Select a task graph before opening the isolated simulator.")
	_new_button.disabled = not native_extension_available
	_overflow_button.disabled = false
	_drawer_toggle.text = "Show findings" if _drawer_collapsed else "Hide findings"
	_drawer_toggle.tooltip_text = "Show or hide the findings drawer"
	_drawer_message.text = "%d finding%s | %s" % [total, "" if total == 1 else "s", _last_validation_label] if total > 0 else _last_validation_label
	_drawer_message.tooltip_text = _drawer_message.text


func _refresh_center() -> void:
	if _center_content == null:
		return
	var degraded: bool = not native_extension_available or (_document_model != null and _document_model.has_method("is_degraded") and bool(_document_model.call("is_degraded")))
	_center_degraded.visible = degraded
	_center_empty.visible = false
	_graph_canvas.visible = false
	_conversation_editor.visible = false
	_level_view.visible = false
	_graph_toolbar.visible = false
	if degraded:
		_center_title.text = "Read-only diagnostic"
		_center_subtitle.text = "Native extension unavailable"
		_center_degraded.call("setup", "Native extension unavailable", "Build and load the Level Task System GDExtension before editing definitions.", _native_details(), ComponentState.ERROR)
		return
	if _current_kind in ["", WorkspaceState.KIND_PROJECT]:
		_center_title.text = "Level Task workspace"
		_center_subtitle.text = "Project overview"
		_center_empty.visible = true
		return
	if _current_kind == WorkspaceState.KIND_SIMULATION:
		_center_title.text = "Simulation shell"
		_center_subtitle.text = "Runtime controls are reserved for task 8.1"
		_center_empty.call("setup", "Isolated simulator shell", "Synthetic facts, event injection, and trace controls will use the production runtime in task 8.1.", "Open findings")
		_center_empty.visible = true
		return
	if _current_kind == WorkspaceState.KIND_DIAGNOSTICS:
		_center_title.text = "Diagnostics"
		_center_subtitle.text = _last_validation_label
		_center_empty.visible = false
		return
	var document: Dictionary = _document_model.call("get_document", _current_kind, _current_identifier)
	_center_title.text = _current_identifier
	_center_title.tooltip_text = _current_identifier
	_center_subtitle.text = WorkspaceState.kind_label(_current_kind) + " | " + (_current_path if not _current_path.is_empty() else "model projection")
	_center_subtitle.tooltip_text = _center_subtitle.text
	match _current_kind:
		WorkspaceState.KIND_TASK_GRAPH:
			_graph_canvas.visible = true
			_graph_canvas.call("set_document_model", _document_model)
			_graph_canvas.call("set_graph_identifier", _current_identifier)
			_graph_canvas.call("set_validation_findings", _findings)
			_graph_canvas.call("set_breadcrumb", WorkspaceState.breadcrumbs(_current_kind, _current_identifier, _subgraph_identifier))
			if _task_simulator_panel != null:
				if String(_task_simulator_panel.call("get_graph_identifier")) != _current_identifier:
					_task_simulator_panel.call("bind_graph", document, "editor.simulation.%s" % _current_identifier)
				_task_simulator_panel.call("set_graph_canvas", _graph_canvas)
		WorkspaceState.KIND_CONVERSATION:
			_conversation_editor.visible = true
			var bound_model: Variant = _conversation_editor.call("get_document_model")
			var bound_identifier := String(_conversation_editor.call("get_conversation_identifier"))
			if bound_model != _document_model or bound_identifier != _current_identifier:
				_conversation_editor.call("bind_document", _document_model, _current_identifier, _document_model.call("get_selection"))
				if undo_redo != null:
					_conversation_editor.call("set_undo_redo_manager", undo_redo)
			_conversation_editor.call("set_validation_findings", _findings)
		WorkspaceState.KIND_LEVEL:
			_level_view.visible = true
			_render_level(document)
		_:
			_center_empty.call("setup", "%s selected" % WorkspaceState.kind_label(_current_kind), "This resource is available for navigation and contextual inspection. A dedicated editor view will be added in a later workspace task.", "Open diagnostics")
			_center_empty.visible = true


func _render_graph(document: Dictionary) -> void:
	if _graph_canvas == null:
		return
	for child in _graph_canvas.get_children():
		if child is GraphNode:
			# Rebuilds are synchronous projections. Free the old projection now so
			# GraphEdit never retains a stale connection endpoint across frames.
			child.free()
	_graph_node_controls.clear()
	_graph_port_indices.clear()
	_graph_canvas.clear_connections()
	var layout: Dictionary = _document_model.call("get_layout", WorkspaceState.KIND_TASK_GRAPH, _current_identifier) if _document_model.has_method("get_layout") else {}
	var layout_nodes: Dictionary = layout.get("nodes", {})
	var nodes: Array = document.get("nodes", [])
	for index in range(nodes.size()):
		var node: Dictionary = nodes[index]
		if not node is Dictionary:
			continue
		var node_id := String(node.get("identifier", ""))
		if node_id.is_empty():
			continue
		var family := WorkspaceState.node_family(node.get("kind", 0))
		var ports: Array = []
		var port_indices: Dictionary = {}
		var projected_ports: Array = node.get("ports", [])
		for port_index in range(projected_ports.size()):
			if not projected_ports[port_index] is Dictionary:
				continue
			var port := WorkspaceState.port_projection(projected_ports[port_index])
			ports.append(port)
			# GraphNode slot indices and GraphEdit connection port indices are not
			# the same: GraphEdit compresses input/output ports independently.
			# Keep the native card's slot rows, but map edges by side-relative
			# indices to avoid invalid cache lookups when a node has both sides.
			var side := String(port.get("direction", "OUT"))
			var side_index := -1
			for previous_port in ports:
				if String(previous_port.get("direction", "OUT")) == side:
					side_index += 1
			port_indices[String(port.get("name", "port"))] = side_index
		var card := GraphNodeCard.new()
		card.name = "Node_%s" % node_id.replace(".", "_")
		card.call("setup", String(family.get("label", "Unknown node")), node_id, node_id, WorkspaceState.node_summary(node), ports, family.get("icons", [&"Node"]))
		card.set_meta("lts_identifier", node_id)
		card.set_meta("lts_kind", int(node.get("kind", 0)))
		card.custom_minimum_size = Vector2(_theme_unit() * 18.0, _theme_unit() * 12.0)
		_graph_canvas.add_child(card)
		var raw_position: Variant = layout_nodes.get(node_id, {}).get("position", WorkspaceState.default_node_position(index, _theme_unit())) if layout_nodes.get(node_id, {}) is Dictionary else WorkspaceState.default_node_position(index, _theme_unit())
		card.position_offset = _as_vector2(raw_position, WorkspaceState.default_node_position(index, _theme_unit()))
		_graph_node_controls[node_id] = card
		_graph_port_indices[node_id] = port_indices
	for edge in document.get("edges", []):
		if not edge is Dictionary:
			continue
		var from_id := String(edge.get("from_node_identifier", ""))
		var to_id := String(edge.get("to_node_identifier", ""))
		if not _graph_node_controls.has(from_id) or not _graph_node_controls.has(to_id):
			continue
		var from_port := int(_graph_port_indices.get(from_id, {}).get(String(edge.get("from_port_identifier", "")), -1))
		var to_port := int(_graph_port_indices.get(to_id, {}).get(String(edge.get("to_port_identifier", "")), -1))
		if from_port < 0 or to_port < 0:
			continue
		_graph_canvas.connect_node(StringName(_graph_node_controls[from_id].name), from_port, StringName(_graph_node_controls[to_id].name), to_port)


func _render_conversation(document: Dictionary) -> void:
	if _conversation_timeline == null or _conversation_text == null:
		return
	var timeline_column := _conversation_timeline.get_node_or_null("TimelineColumn") as VBoxContainer
	if timeline_column != null:
		for child in timeline_column.get_children():
			child.free()
		var steps: Array = document.get("steps", [])
		if steps.is_empty():
			var empty := EmptyState.new()
			empty.call("setup", "No conversation steps", "Create or project a conversation definition to populate the timeline.", "Open diagnostics")
			timeline_column.add_child(empty)
		for index in range(steps.size()):
			var step: Dictionary = steps[index]
			if not step is Dictionary:
				continue
			var row := PanelContainer.new()
			row.name = "Step_%d" % index
			row.theme_type_variation = &"LevelTaskResourceRow"
			var row_column := VBoxContainer.new()
			row.add_child(row_column)
			var heading := Label.new()
			heading.text = "%02d  %s" % [index + 1, String(step.get("identifier", "step"))]
			heading.tooltip_text = heading.text
			row_column.add_child(heading)
			var line := Label.new()
			line.text = "Speaker: %s | line key: %s" % [String(step.get("speaker_identifier", "not configured")), String(step.get("line_key", "not configured"))]
			line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			line.tooltip_text = line.text
			row_column.add_child(line)
			var choices := Array(step.get("choices", []))
			var meta := Label.new()
			meta.text = "Choices: %d | next: %s" % [choices.size(), String(step.get("next_step_identifier", "terminal or branch"))]
			meta.tooltip_text = meta.text
			row_column.add_child(meta)
			timeline_column.add_child(row)
	var lines := PackedStringArray()
	lines.append("# %s" % _current_identifier)
	lines.append("entry: %s" % String(document.get("entry_label", "not configured")))
	lines.append("")
	for step in document.get("steps", []):
		if not step is Dictionary:
			continue
		lines.append("[%s] %s" % [String(step.get("identifier", "step")), String(step.get("line_key", "")) if not String(step.get("line_key", "")).is_empty() else "(no localization key)"])
		for choice in step.get("choices", []):
			if choice is Dictionary:
				lines.append("  - %s -> %s" % [String(choice.get("label_key", choice.get("identifier", "choice"))), String(choice.get("target_step_identifier", "outcome"))])
	_conversation_text.text = "\n".join(lines)


func _render_level(document: Dictionary) -> void:
	var column := _level_view.get_node_or_null("LevelColumn") as VBoxContainer
	if column == null:
		return
	for child in column.get_children():
		child.free()
	_add_readonly_label(column, "Level definition", "Resource metadata is projected from the document model.")
	_add_readonly_label(column, "Display name key", String(document.get("display_name_key", "not configured")))
	_add_readonly_label(column, "Scene resource", String(document.get("scene_resource", "not configured")))
	_add_readonly_label(column, "Entry graphs", ", ".join(PackedStringArray(document.get("entry_graph_identifiers", []))))
	_add_readonly_label(column, "Anchors", "%d authored anchors" % Array(document.get("anchors", [])).size())
	_add_readonly_label(column, "Named exits", "%d authored exits" % Array(document.get("exits", [])).size())


func _refresh_inspector() -> void:
	if _inspector_content == null:
		return
	for child in _inspector_content.get_children():
		child.free()
	var heading := Label.new()
	heading.name = "InspectorHeading"
	heading.text = "Inspector"
	heading.tooltip_text = "Contextual fields for the selected resource or graph node"
	_inspector_content.add_child(heading)
	if _document_model == null or _current_kind in ["", WorkspaceState.KIND_PROJECT, WorkspaceState.KIND_SIMULATION, WorkspaceState.KIND_DIAGNOSTICS]:
		_add_readonly_label(_inspector_content, "Selection", "Select a resource or graph node.")
		return
	var document: Dictionary = _document_model.call("get_document", _current_kind, _current_identifier)
	_add_inspector_field("Stable identifier", _current_identifier, "Canonical runtime identity", ComponentState.DISABLED, "")
	_add_inspector_field("Source path", _current_path if not _current_path.is_empty() else "Model projection", "FileSystem source; semantic identity is separate", ComponentState.DISABLED, "")
	_add_inspector_field("Schema version", str(document.get("schema_version", 1)), "Definition schema version", ComponentState.DISABLED, "")
	var selection: Dictionary = _document_model.call("get_selection") if _document_model.has_method("get_selection") else {}
	if String(selection.get("resource_kind", "")) == _current_kind and String(selection.get("resource_identifier", "")) == _current_identifier and String(selection.get("element_kind", "")) == "node":
		var node_id := String(selection.get("element_identifier", ""))
		var node := _find_by_identifier(document.get("nodes", []), node_id)
		if not node.is_empty():
			_add_readonly_label(_inspector_content, "Selected node", node_id)
			var family := WorkspaceState.node_family(node.get("kind", 0))
			_add_readonly_label(_inspector_content, "Family", String(family.get("label", "Unknown node")))
			_add_inspector_field("Objective target", str(node.get("objective_target", 1)), "Document command preview; commit is routed through the model", ComponentState.DEFAULT, "objective_target")
			_add_inspector_field("Provider identifier", String(node.get("provider_identifier", "")), "Typed provider reference", ComponentState.DEFAULT, "provider_identifier")
			_add_inspector_field("Conversation identifier", String(node.get("conversation_identifier", "")), "Typed conversation reference", ComponentState.DEFAULT, "conversation_identifier")
			_add_inspector_field("Subgraph identifier", String(node.get("subgraph_identifier", "")), "Typed subgraph reference", ComponentState.DEFAULT, "subgraph_identifier")
	_add_readonly_label(_inspector_content, "Validation", _last_validation_label)
	for finding in _findings:
		if finding is Dictionary and String(finding.get("path", "")).begins_with(WorkspaceState.document_path(_current_kind, _current_identifier)):
			_add_readonly_label(_inspector_content, String(finding.get("code", "Diagnostic")), String(finding.get("message", "")))


func _refresh_drawer() -> void:
	if _drawer_content == null:
		return
	if _drawer_tabs.current_tab == 0:
		_show_drawer_surface(_findings_panel)
		_findings_panel.set_findings(_findings)
	elif _drawer_tabs.current_tab == 1:
		if _current_kind == WorkspaceState.KIND_TASK_GRAPH and _task_simulator_panel != null:
			_show_drawer_surface(_task_simulator_panel)
		else:
			_hide_drawer_surfaces()
			_add_drawer_shell_message("Isolated simulation", "Select a task graph to configure synthetic facts, inject events, step or run the production runtime, and inspect its deterministic trace.")
	elif _drawer_tabs.current_tab == 2:
		_show_drawer_surface(_live_runtime_debugger)
	else:
		if _current_kind == WorkspaceState.KIND_CONVERSATION and _conversation_preview != null:
			var document: Dictionary = _document_model.call("get_document", _current_kind, _current_identifier) if _document_model != null else {}
			if _conversation_preview_identifier != _current_identifier:
				_conversation_preview.call("bind_conversation", document, {}, String(document.get("entry_label", "")), native_extension_available)
				_conversation_preview_identifier = _current_identifier
			_show_drawer_surface(_conversation_preview)
		else:
			_hide_drawer_surfaces()
			_add_drawer_shell_message("Conversation preview", "Select a conversation to start an isolated chat-style preview with choices, condition visibility, variables, and restart controls.")
	if _drawer_tabs.current_tab == 0 and _findings.is_empty():
		_drawer_message.text = "No findings | validate to check"
	_drawer_message.tooltip_text = _drawer_message.text


func _hide_drawer_surfaces() -> void:
	var persistent: Array = [_findings_panel, _task_simulator_panel, _live_runtime_debugger, _conversation_preview]
	for child in _drawer_content.get_children():
		if persistent.has(child):
			child.visible = false
		else:
			child.free()


func _show_drawer_surface(surface: Control) -> void:
	_hide_drawer_surfaces()
	if surface != null:
		surface.visible = true


func _add_drawer_shell_message(title: String, message: String) -> void:
	var panel := PanelContainer.new()
	panel.name = "DrawerShellMessage"
	panel.theme_type_variation = &"LevelTaskEmptyState"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	panel.add_child(column)
	var heading := Label.new()
	heading.text = title
	heading.tooltip_text = title
	column.add_child(heading)
	var body := Label.new()
	body.text = message
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.tooltip_text = message
	column.add_child(body)
	_drawer_content.add_child(panel)


func _add_inspector_field(label: String, value: String, help: String, state: StringName, field_name: String) -> void:
	var field := InspectorField.new()
	field.name = "Field_%s" % label.replace(" ", "")
	field.call("setup", label, value, help, state)
	if not field_name.is_empty():
		field.value_committed.connect(_on_inspector_value_committed.bind(field_name))
	_inspector_content.add_child(field)


func _add_readonly_label(parent: Node, label: String, value: String) -> void:
	var row := VBoxContainer.new()
	row.name = "ReadOnly_%s" % label.replace(" ", "_")
	var heading := Label.new()
	heading.text = label
	heading.tooltip_text = label
	row.add_child(heading)
	var value_label := Label.new()
	value_label.text = value
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.tooltip_text = value
	row.add_child(value_label)
	parent.add_child(row)


func _on_search_changed(_query: String) -> void:
	_refresh_navigator()


func _on_navigator_item_selected(item: TreeItem, _column: int) -> void:
	if item == null:
		return
	var metadata: Variant = item.get_metadata(0)
	if metadata is Dictionary and String(metadata.get("kind", "")) in [WorkspaceState.KIND_PROJECT, WorkspaceState.KIND_SIMULATION, WorkspaceState.KIND_DIAGNOSTICS]:
		_update_context_from_kind(String(metadata.get("kind", "")))


func _on_navigator_item_activated() -> void:
	var item := _navigator_tree.get_selected()
	if item == null:
		return
	var metadata: Variant = item.get_metadata(0)
	if not metadata is Dictionary:
		return
	var data: Dictionary = metadata
	var kind := String(data.get("kind", ""))
	var identifier := String(data.get("identifier", ""))
	var path := String(data.get("source_path", ""))
	match kind:
		WorkspaceState.KIND_PROJECT:
			open_project_overview()
		WorkspaceState.KIND_SIMULATION:
			open_simulation_shell()
		WorkspaceState.KIND_DIAGNOSTICS:
			open_diagnostics()
		_:
			if not open_document(kind, identifier, path) and not path.is_empty():
				open_resource(null, path)


func _on_navigator_empty_action() -> void:
	if _search_field != null and not _search_field.text.is_empty():
		_search_field.clear()
		_search_field.grab_focus()
		return
	if native_extension_available:
		_open_creation_dialog(WorkspaceState.KIND_TASK_GRAPH)


func _on_center_empty_action() -> void:
	if _current_kind == WorkspaceState.KIND_SIMULATION:
		open_simulation_shell()
	else:
		_open_creation_dialog(WorkspaceState.KIND_TASK_GRAPH)


func _on_breadcrumb_activated(crumb: Dictionary) -> void:
	var path := String(crumb.get("path", "project"))
	if path == "project":
		open_project_overview()
		return
	var crumb_kind := WorkspaceState.normalize_kind(String(crumb.get("kind", "")))
	var identifier := String(crumb.get("identifier", ""))
	if not identifier.is_empty() and _document_model != null and _document_model.call("has_document", crumb_kind, identifier):
		open_document(crumb_kind, identifier)


func _on_command_button_requested(action: String) -> void:
	_on_command(action)


func _on_icon_button_requested(action: String) -> void:
	_on_command(action)


func _on_command(action: String) -> void:
	command_invoked.emit(action)
	match action:
		"save":
			_save_current()
		"validate":
			_validate_current()
		"simulate":
			open_simulation_shell()
		"toggle_navigator":
			_set_navigator_collapsed(not _navigator_collapsed, true)
		"toggle_inspector":
			_set_inspector_collapsed(not _inspector_collapsed, true)
		"toggle_drawer":
			_set_drawer_collapsed(not _drawer_collapsed, true)
		"arrange":
			_graph_canvas.call("request_auto_arrange")
		"toggle_grid":
			_graph_canvas.call("toggle_grid")
		"toggle_snap":
			_graph_canvas.call("toggle_snapping")
		"toggle_minimap":
			_graph_canvas.call("toggle_minimap")
		"refresh":
			refresh_resources()
		"open_diagnostics":
			open_diagnostics()


func _on_overflow_action(id: int) -> void:
	match id:
		1:
			open_simulation_shell()
		2:
			refresh_resources()
		3:
			open_diagnostics()
		4:
			_open_creation_dialog(WorkspaceState.KIND_TASK_GRAPH)


func _on_creation_kind_selected(id: int) -> void:
	var kinds := WorkspaceState.creation_kinds()
	if id >= 0 and id < kinds.size():
		_open_creation_dialog(kinds[id])


func _open_creation_dialog(kind: String) -> void:
	if _creation_dialog == null:
		return
	_creation_kind = WorkspaceState.normalize_kind(kind)
	var spec := WorkspaceState.creation_spec(_creation_kind)
	_creation_dialog.get_node("CreationColumn/CreationKind").text = "Create %s" % WorkspaceState.kind_label(_creation_kind)
	_creation_identifier_edit.text = String(spec.get("identifier", ""))
	_creation_path_edit.text = String(spec.get("path", ""))
	_creation_error_label.text = ""
	_creation_dialog.popup_centered(Vector2(_theme_unit() * 42.0, _theme_unit() * 20.0))
	_creation_identifier_edit.grab_focus()


func _on_creation_confirmed() -> void:
	var identifier := _creation_identifier_edit.text.strip_edges()
	var path := _creation_path_edit.text.strip_edges()
	var validation := _validate_creation_input(identifier, path)
	if not validation.is_empty():
		_creation_error_label.text = validation
		_creation_dialog.popup_centered()
		return
	if not create_resource(_creation_kind, identifier, path):
		_creation_error_label.text = "Creation failed; see the command bar diagnostic."


func _validate_creation_input(identifier: String, path: String) -> String:
	if identifier.is_empty():
		return "Identifier is required."
	if identifier.contains("/") or identifier.contains("\\") or identifier.contains(" "):
		return "Identifier must be a stable dot-separated value without path separators or spaces."
	if path.is_empty():
		return "Resource path is required."
	if not _valid_resource_path(path):
		return "Resource path must be under res:// and end in .tres or .res."
	return ""


func _valid_resource_path(path: String) -> bool:
	return path.begins_with("res://") and WorkspaceState.is_supported_path(path) and not path.contains("..")


func _on_drawer_tab_changed(_index: int) -> void:
	_refresh_drawer()


func _on_conversation_selection_changed(_selection: Dictionary) -> void:
	_refresh_inspector()


func _on_conversation_command_applied(_intent: Dictionary, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		var error: Dictionary = result.get("error", {})
		_set_command_status("Error %s: %s" % [error.get("code", "LTS-CONVERSATION-000"), error.get("message", "Conversation edit rejected")], ComponentState.ERROR)
		return
	_dirty = true
	_sync_current_resource()
	_validate_current()
	_refresh_all()


func _on_conversation_validation_changed(findings: Array) -> void:
	# View-local findings can arrive before a full catalog validation. Once the
	# workspace has findings, its cross-resource result remains authoritative.
	if not findings.is_empty() and _findings.is_empty():
		set_findings(findings)


func _on_conversation_save_requested(_identifier: String, _document: Dictionary) -> void:
	_save_current()


func _on_graph_selection_projection_changed(node_identifiers: Array) -> void:
	var node_identifier := String(node_identifiers.front()) if not node_identifiers.is_empty() else ""
	_apply_selection({
		"resource_kind": WorkspaceState.KIND_TASK_GRAPH,
		"resource_identifier": _current_identifier,
		"element_kind": "node" if not node_identifier.is_empty() else "",
		"element_identifier": node_identifier,
		"field_path": "",
	})


func _on_graph_editor_command_applied(command: Dictionary, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		return
	_dirty = true
	_register_undo_action(DocumentCommand.from_dict(command), result.get("inverse", {}), "Edit task graph")
	_sync_current_resource()
	_validate_current()
	_refresh_all()


func _on_graph_editor_command_rejected(_command: Dictionary, error: Dictionary) -> void:
	_set_command_status("Error %s: %s" % [error.get("code", "LTS-GRAPH-000"), error.get("message", "Graph edit rejected")], ComponentState.ERROR)


func _on_graph_subgraph_navigation_requested(_graph_identifier: String, _node_identifier: String, subgraph_identifier: String) -> void:
	if _document_model != null and _document_model.call("has_document", WorkspaceState.KIND_TASK_GRAPH, subgraph_identifier):
		open_document(WorkspaceState.KIND_TASK_GRAPH, subgraph_identifier)
		_subgraph_identifier = subgraph_identifier
		_refresh_breadcrumbs()
	else:
		_set_command_status("Subgraph '%s' is not present in the open catalog." % subgraph_identifier, ComponentState.ERROR)


func _on_graph_connection_feedback_changed(feedback: Dictionary) -> void:
	if not bool(feedback.get("compatible", feedback.get("ok", false))):
		_set_command_status("%s: %s" % [feedback.get("code", "Connection rejected"), feedback.get("reason", feedback.get("message", "Incompatible ports"))], ComponentState.ERROR)


func _on_graph_node_selected(node: Node) -> void:
	if node == null:
		return
	var node_id := String(node.get_meta("lts_identifier", ""))
	if node_id.is_empty():
		return
	_apply_selection({
		"resource_kind": WorkspaceState.KIND_TASK_GRAPH,
		"resource_identifier": _current_identifier,
		"element_kind": "node",
		"element_identifier": node_id,
		"field_path": "",
	})


func _on_graph_node_deselected(_node: Node) -> void:
	if _document_model == null or not _document_model.has_method("get_selection"):
		return
	var selection: Dictionary = _document_model.call("get_selection")
	if String(selection.get("resource_kind", "")) == WorkspaceState.KIND_TASK_GRAPH and String(selection.get("resource_identifier", "")) == _current_identifier:
		_apply_selection({
			"resource_kind": WorkspaceState.KIND_TASK_GRAPH,
			"resource_identifier": _current_identifier,
			"element_kind": "",
			"element_identifier": "",
			"field_path": "",
		})


func _on_graph_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	# Connection attempts are routed through the document model when endpoint
	# identifiers can be mapped.  Type/cycle rejection remains visible through
	# the deterministic finding path; GraphEdit is never the source of truth.
	if _document_model == null or not _document_model.has_method("apply_command"):
		return
	var from_id := _identifier_for_graph_name(from_node)
	var to_id := _identifier_for_graph_name(to_node)
	var from_port_id := _port_identifier_for_index(from_id, from_port)
	var to_port_id := _port_identifier_for_index(to_id, to_port)
	if from_id.is_empty() or to_id.is_empty() or from_port_id.is_empty() or to_port_id.is_empty():
		_set_command_status("Connection rejected LTS-GRAPH-PORT-001: named ports could not be resolved.", ComponentState.ERROR)
		return
	var edge_id := "%s.%s.%s" % [from_id, from_port_id, to_id]
	_apply_document_command(DocumentCommand.connect_nodes(_current_identifier, from_id, from_port_id, to_id, to_port_id, edge_id), "Connect task nodes")


func _on_graph_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if _document_model == null or not _document_model.has_method("get_document"):
		return
	var from_id := _identifier_for_graph_name(from_node)
	var to_id := _identifier_for_graph_name(to_node)
	var from_port_id := _port_identifier_for_index(from_id, from_port)
	var to_port_id := _port_identifier_for_index(to_id, to_port)
	var document: Dictionary = _document_model.call("get_document", WorkspaceState.KIND_TASK_GRAPH, _current_identifier)
	for edge in document.get("edges", []):
		if edge is Dictionary and String(edge.get("from_node_identifier", "")) == from_id and String(edge.get("to_node_identifier", "")) == to_id and String(edge.get("from_port_identifier", "")) == from_port_id and String(edge.get("to_port_identifier", "")) == to_port_id:
			_apply_document_command(DocumentCommand.remove_task_edge(_current_identifier, String(edge.get("identifier", ""))), "Disconnect task nodes")
			return


func _on_graph_connection_to_empty(_from_node: StringName, _from_port: int, _release_position: Vector2) -> void:
	# The quick-add popup is intentionally bounded to resource creation in this
	# shell.  Keep the action explicit instead of silently creating a node.
	_set_command_status("Drop target empty: use New or the later typed quick-add editor task.", ComponentState.DEFAULT)


func _on_graph_delete_nodes_request() -> void:
	if _graph_canvas == null or _document_model == null:
		return
	var selected: Array = _graph_canvas.get_selected_nodes()
	var ids: Array = []
	for node in selected:
		if node is Node:
			var identifier := String(node.get_meta("lts_identifier", ""))
			if not identifier.is_empty():
				ids.append(identifier)
	if not ids.is_empty():
		_apply_document_command(DocumentCommand.remove_task_nodes(_current_identifier, ids), "Delete task nodes")


func _on_graph_popup_request(_position: Vector2) -> void:
	_set_command_status("Graph actions remain native: pan, zoom, snapping, minimap, and selection are available from this shell.", ComponentState.DEFAULT)


func _on_inspector_value_committed(value: String, field_name: String) -> void:
	if _document_model == null or _current_kind != WorkspaceState.KIND_TASK_GRAPH:
		return
	var selection: Dictionary = _document_model.call("get_selection")
	var node_id := String(selection.get("element_identifier", ""))
	if node_id.is_empty():
		return
	var coerced: Variant = value
	if field_name == "objective_target":
		coerced = maxi(0, int(value))
	_apply_document_command(DocumentCommand.set_node_field(_current_identifier, node_id, field_name, coerced), "Edit node %s" % field_name)


func _apply_selection(selection: Dictionary) -> void:
	if _document_model == null or not _document_model.has_method("apply_command"):
		return
	var result := _document_model.call("apply_command", DocumentCommand.set_selection(selection))
	if result is Dictionary and bool(result.get("ok", false)):
		_refresh_inspector()


func _apply_navigation_context() -> void:
	if _document_model == null or not _document_model.has_method("apply_command"):
		return
	_document_model.call("apply_command", DocumentCommand.navigate_catalog(
		WorkspaceState.document_path(_current_kind, _current_identifier), _current_kind, _current_identifier,
		_search_field.text if _search_field != null else ""
	))
	_apply_selection({
		"resource_kind": _current_kind,
		"resource_identifier": _current_identifier,
		"element_kind": "",
		"element_identifier": "",
		"field_path": "",
	})


func _apply_document_command(command: Variant, action_label: String) -> bool:
	if _document_model == null or not _document_model.has_method("apply_command"):
		return false
	if not _document_model.call("can_mutate"):
		_set_command_status("Read-only: native extension is unavailable.", ComponentState.ERROR)
		return false
	var result: Dictionary = _document_model.call("apply_command", command)
	if not bool(result.get("ok", false)):
		var error: Dictionary = result.get("error", {})
		_set_command_status("Error %s: %s" % [String(error.get("code", "LTS-DOCUMENT-000")), String(error.get("message", "Command rejected"))], ComponentState.ERROR)
		return false
	_dirty = true
	_register_undo_action(command, result.get("inverse", {}), action_label)
	_sync_current_resource()
	_validate_current()
	_refresh_all()
	return true


func _register_undo_action(command: Variant, inverse: Variant, action_label: String) -> void:
	if _replaying_undo or undo_redo == null or not undo_redo.has_method("create_action"):
		return
	if not command is Object or not command.has_method("to_dict"):
		return
	var command_data: Dictionary = command.to_dict()
	var inverse_data: Dictionary = inverse if inverse is Dictionary else {}
	if inverse_data.is_empty():
		return
	undo_redo.call("create_action", action_label)
	undo_redo.call("add_do_method", self, "_replay_document_command", command_data)
	undo_redo.call("add_undo_method", self, "_replay_document_command", inverse_data)
	# The model has already applied the command; committing with execute=false
	# prevents a second mutation while still registering history.
	undo_redo.call("commit_action", false)


func _replay_document_command(data: Dictionary) -> void:
	if _document_model == null:
		return
	_replaying_undo = true
	_document_model.call("apply_command", data)
	_replaying_undo = false
	_refresh_all()


func _save_current() -> bool:
	if _current_resource == null or _current_path.is_empty():
		_set_command_status("Nothing to save: select a resource from the navigator.", ComponentState.DEFAULT)
		return false
	if not _dirty:
		_set_command_status("Saved %s." % _current_path, ComponentState.DEFAULT)
		return true
	if not _sync_current_resource():
		_set_command_status("Error LTS-SAVE-001: model changes could not be synchronized safely.", ComponentState.ERROR)
		return false
	var save_error := ResourceSaver.save(_current_resource, _current_path)
	if save_error != OK:
		_set_command_status("Error LTS-SAVE-002: save failed for %s (code %d)." % [_current_path, save_error], ComponentState.ERROR)
		return false
	_dirty = false
	_set_command_status("Saved %s." % _current_path, ComponentState.ACTIVE)
	_refresh_command_bar()
	return true


func _sync_current_resource() -> bool:
	if _current_resource == null or _document_model == null or _current_kind.is_empty():
		return true
	var document: Dictionary = _document_model.call("get_document", _current_kind, _current_identifier)
	if document.is_empty():
		return false
	if _current_resource.has_method("set_identifier") and document.has("identifier"):
		_current_resource.call("set_identifier", StringName(document.get("identifier", _current_identifier)))
	match _current_kind:
		WorkspaceState.KIND_TASK_GRAPH:
			_set_resource_property(_current_resource, "entry_node_identifier", String(document.get("entry_node_identifier", "")))
			_set_resource_property(_current_resource, "max_transitions_per_advance", int(document.get("max_transitions_per_advance", 0)))
			var resource_nodes := _resource_array(_current_resource, "nodes")
			for node_data in document.get("nodes", []):
				if not node_data is Dictionary:
					continue
				var node_resource := _find_resource_by_identifier(resource_nodes, String(node_data.get("identifier", "")))
				if node_resource == null:
					continue
				for property in ["objective_target", "provider_identifier", "conversation_identifier", "conversation_entry_label", "subgraph_identifier", "outcome_identifier"]:
					if node_data.has(property):
						_set_resource_property(node_resource, property, node_data[property])
		WorkspaceState.KIND_CONVERSATION:
			_set_resource_property(_current_resource, "entry_label", String(document.get("entry_label", "")))
		WorkspaceState.KIND_LEVEL:
			_set_resource_property(_current_resource, "scene_resource", String(document.get("scene_resource", "")))
	return true


func _validate_current() -> void:
	if _document_model == null or _current_kind in [WorkspaceState.KIND_SIMULATION, WorkspaceState.KIND_DIAGNOSTICS]:
		_findings = []
		_last_validation_label = "Not validated"
		_refresh_all()
		return
	if not native_extension_available:
		_findings = [{
			"severity": "error",
			"code": "LTS-NATIVE-001",
			"message": "Native extension unavailable; authoring is read-only.",
			"path": "native",
			"resource_kind": "",
			"resource_identifier": "",
			"element_kind": "",
			"element_identifier": "",
			"field_path": "",
		}]
	else:
		_findings = DocumentValidator.validate(_document_model)
	_last_validation_label = "Validated %s: %d finding%s" % [_current_identifier if not _current_identifier.is_empty() else "project", _findings.size(), "" if _findings.size() == 1 else "s"]
	if _findings_store != null:
		_findings_store.replace_all(_findings)
	_refresh_command_bar()
	_refresh_drawer()
	_validate_button.call("set_state", ComponentState.ACTIVE)


func _on_finding_target_activated(target: Dictionary) -> void:
	finding_activated.emit(target.duplicate(true))
	var kind := WorkspaceState.normalize_kind(String(target.get("resource_kind", "")))
	var identifier := String(target.get("resource_identifier", ""))
	if kind.is_empty() or identifier.is_empty() or _document_model == null:
		return
	if _document_model.call("has_document", kind, identifier):
		open_document(kind, identifier)
		var element_kind := String(target.get("element_kind", ""))
		var element_identifier := String(target.get("element_identifier", ""))
		if not element_kind.is_empty() and not element_identifier.is_empty():
			_apply_selection({
				"resource_kind": kind,
				"resource_identifier": identifier,
				"element_kind": element_kind,
				"element_identifier": element_identifier,
				"field_path": String(target.get("field_path", "")),
			})
			if kind == WorkspaceState.KIND_TASK_GRAPH and element_kind == "node":
				_focus_graph_node(element_identifier)


func _focus_graph_node(identifier: String) -> void:
	if _graph_canvas == null:
		return
	_graph_canvas.call("set_selected_node_identifiers", [identifier])
	_graph_canvas.grab_focus()


func _update_context_from_kind(kind: String) -> void:
	match kind:
		WorkspaceState.KIND_PROJECT:
			open_project_overview()
		WorkspaceState.KIND_SIMULATION:
			open_simulation_shell()
		WorkspaceState.KIND_DIAGNOSTICS:
			open_diagnostics()


func _set_command_status(text: String, state: StringName) -> void:
	_last_validation_label = text
	if _severity_badge != null:
		_severity_badge.call("setup", text, state)
	if _drawer_message != null:
		_drawer_message.text = text
		_drawer_message.tooltip_text = text


func _show_degraded_status() -> void:
	_set_command_status("Read-only: native extension unavailable (LTS-NATIVE-001).", ComponentState.ERROR)
	if _center_degraded != null:
		_center_degraded.visible = true


func _on_native_refresh() -> void:
	native_refresh_requested.emit()
	var available := true
	for class_name_to_check in ["LevelTaskSystemVersion", "LevelTaskLevelDefinition", "LevelTaskGraphDefinition", "LevelTaskConversationDefinition"]:
		if not ClassDB.class_exists(class_name_to_check):
			available = false
	set_native_extension_available(available)
	if available:
		refresh_resources()


func _copy_native_details() -> void:
	var details := _native_details()
	if DisplayServer.get_name() != "headless":
		DisplayServer.clipboard_set(details)
	_set_command_status("Native extension diagnostic copied.", ComponentState.ACTIVE)


func _set_navigator_collapsed(collapsed: bool, user_action: bool) -> void:
	_navigator_collapsed = collapsed
	if user_action:
		_auto_navigator_collapsed = false
	_navigator_panel.visible = not collapsed
	_update_narrow_layout()


func _set_inspector_collapsed(collapsed: bool, user_action: bool) -> void:
	_inspector_collapsed = collapsed
	if user_action:
		_auto_inspector_collapsed = false
	_inspector_panel.visible = not collapsed
	_update_narrow_layout()


func _set_drawer_collapsed(collapsed: bool, user_action: bool) -> void:
	_drawer_collapsed = collapsed
	if user_action:
		_auto_drawer_collapsed = false
	_drawer_content.visible = not collapsed
	_drawer_tabs.visible = not collapsed
	_drawer_panel.custom_minimum_size.y = maxf(36.0, _theme_unit() * 4.0) if collapsed else maxf(144.0, _theme_unit() * 18.0)
	_update_narrow_layout()


func _update_narrow_layout() -> void:
	if not _built or size.x <= 0.0:
		return
	var unit := _theme_unit()
	# Control.size is already expressed in logical pixels when the viewport uses
	# a content scale factor. These thresholds therefore cover both narrow
	# windows and 125%/150% editor scaling without double-applying the scale.
	var logical_width := size.x
	var should_collapse_navigator := logical_width < 1180.0
	var should_collapse_inspector := logical_width < 1060.0
	var should_collapse_drawer := size.y < 720.0
	if should_collapse_navigator and not _navigator_collapsed and not _auto_navigator_collapsed:
		_auto_navigator_collapsed = true
		_navigator_collapsed = true
	if should_collapse_inspector and not _inspector_collapsed and not _auto_inspector_collapsed:
		_auto_inspector_collapsed = true
		_inspector_collapsed = true
	if should_collapse_drawer and not _drawer_collapsed and not _auto_drawer_collapsed:
		_auto_drawer_collapsed = true
		_drawer_collapsed = true
	if not should_collapse_navigator and _auto_navigator_collapsed:
		_auto_navigator_collapsed = false
		_navigator_collapsed = false
	if not should_collapse_inspector and _auto_inspector_collapsed:
		_auto_inspector_collapsed = false
		_inspector_collapsed = false
	if not should_collapse_drawer and _auto_drawer_collapsed:
		_auto_drawer_collapsed = false
		_drawer_collapsed = false
	if _navigator_panel != null:
		_navigator_panel.visible = not _navigator_collapsed
	if _inspector_panel != null:
		_inspector_panel.visible = not _inspector_collapsed
	if _drawer_content != null:
		_drawer_content.visible = not _drawer_collapsed
	if _drawer_tabs != null:
		_drawer_tabs.visible = not _drawer_collapsed
	if _drawer_panel != null:
		_drawer_panel.custom_minimum_size.y = maxf(36.0, unit * 4.0) if _drawer_collapsed else maxf(144.0, unit * 18.0)
	if _simulate_button != null:
		_simulate_button.visible = logical_width >= 1280.0
	if _new_button != null:
		_new_button.visible = logical_width >= 1120.0
	if _overflow_button != null:
		_overflow_button.visible = logical_width < 1120.0
	if _search_field != null:
		_search_field.visible = logical_width >= 1180.0


func _on_workspace_resized() -> void:
	_update_narrow_layout()


func _shortcut_input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or not (key_event.ctrl_pressed or key_event.meta_pressed):
		return
	match key_event.keycode:
		KEY_S:
			_save_current()
			get_viewport().set_input_as_handled()
		KEY_P:
			if _search_field != null:
				_search_field.visible = true
				_search_field.grab_focus()
				_search_field.select_all()
				get_viewport().set_input_as_handled()


func _theme_unit() -> float:
	var separation := get_theme_constant(&"separation", &"VBoxContainer")
	if separation <= 0:
		separation = get_theme_font_size(&"font_size", &"Label")
	if separation <= 0:
		separation = 1
	return float(separation)


func _resource_icon(kind: String) -> Texture2D:
	var preferred: Array = []
	match WorkspaceState.normalize_kind(kind):
		WorkspaceState.KIND_LEVEL:
			preferred = [&"World", &"Scene", &"Node"]
		WorkspaceState.KIND_TASK_GRAPH:
			preferred = [&"Graph", &"Node"]
		WorkspaceState.KIND_CONVERSATION:
			preferred = [&"Dialogue", &"SpeechBubble", &"Node"]
		WorkspaceState.KIND_SPEAKER:
			preferred = [&"Person", &"Node"]
		WorkspaceState.KIND_PROVIDER:
			preferred = [&"Script", &"Node"]
		WorkspaceState.KIND_SIMULATION:
			preferred = [&"Play", &"Node"]
		WorkspaceState.KIND_DIAGNOSTICS:
			preferred = [&"Warning", &"Error", &"Node"]
		_:
			preferred = [&"Folder", &"Node"]
	return ComponentTheme.resolve_icon(self, preferred, &"Node")


func _native_details() -> String:
	var details := PackedStringArray()
	details.append("Required classes:")
	for candidate_class_name in ["LevelTaskSystemVersion", "LevelTaskLevelDefinition", "LevelTaskGraphDefinition", "LevelTaskConversationDefinition"]:
		details.append("- %s: %s" % [candidate_class_name, "registered" if ClassDB.class_exists(candidate_class_name) else "missing"])
	details.append("Code: LTS-NATIVE-001")
	details.append("Path: addons/level_task_system/level_task_system.gdextension")
	return "\n".join(details)


func _can_edit_current() -> bool:
	return native_extension_available and _current_resource != null and not _current_path.is_empty() and _document_model != null and _document_model.call("can_mutate")


func _scan_project_model() -> Object:
	if not native_extension_available:
		return DocumentModel.new(null, false)
	var documents := {
		"levels": {},
		"task_graphs": {},
		"conversations": {},
		"speakers": {},
		"providers": {},
	}
	var scanned := 0
	for path in _collect_resource_paths("res://", RESOURCE_SCAN_LIMIT):
		if scanned >= RESOURCE_SCAN_LIMIT:
			break
		var resource := ResourceLoader.load(path)
		var kind := WorkspaceState.supported_resource_kind(resource)
		if kind.is_empty():
			continue
		var projection := DocumentProjection.project_resource(resource, path)
		var identifier := String(projection.get("identifier", ""))
		if identifier.is_empty():
			continue
		var collection := WorkspaceState.collection_for_kind(kind)
		if not documents.has(collection):
			continue
		documents[collection][identifier] = projection
		scanned += 1
	return DocumentModel.new({"documents": documents}, native_extension_available)


func _collect_resource_paths(directory: String, remaining: int) -> PackedStringArray:
	var result := PackedStringArray()
	if remaining <= 0:
		return result
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "" and result.size() < remaining:
		if not entry.begins_with(".") and entry not in ["thirdparty", "bin", "native"]:
			var full_path := directory.path_join(entry)
			if dir.current_is_dir():
				result.append_array(_collect_resource_paths(full_path, remaining - result.size()))
			elif WorkspaceState.is_supported_path(full_path):
				result.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func _merge_projected_document(projected: Dictionary, kind: String, identifier: String) -> void:
	if _document_model == null or not _document_model.has_method("snapshot"):
		_document_model = DocumentModel.new({"documents": {WorkspaceState.collection_for_kind(kind): {identifier: projected}}}, native_extension_available)
		return
	var state: Dictionary = _document_model.call("snapshot")
	var collection := WorkspaceState.collection_for_kind(kind)
	if not state.has("documents") or not state["documents"] is Dictionary:
		state["documents"] = {}
	if not state["documents"].has(collection) or not state["documents"][collection] is Dictionary:
		state["documents"][collection] = {}
	state["documents"][collection][identifier] = projected.duplicate(true)
	_document_model = DocumentModel.new(state, native_extension_available)


func _add_recent_resource(entry: Dictionary) -> void:
	var result: Array = []
	for existing in _recent_resources:
		if existing is Dictionary and String(existing.get("kind", "")) == String(entry.get("kind", "")) and String(existing.get("identifier", "")) == String(entry.get("identifier", "")):
			continue
		result.append(existing)
	result.push_front(entry.duplicate(true))
	while result.size() > RECENT_RESOURCE_LIMIT:
		result.pop_back()
	_recent_resources = result
	_persist_recent_resources()


func _load_recent_resources() -> Array:
	if not Engine.is_editor_hint() or not ClassDB.class_exists("EditorSettings"):
		return []
	var settings: Object = EditorInterface.get_editor_settings()
	if settings == null or not settings.has_method("get_setting"):
		return []
	var value: Variant = settings.get_setting(RECENT_SETTINGS_KEY)
	return value.duplicate(true) if value is Array else []


func _persist_recent_resources() -> void:
	if not Engine.is_editor_hint() or not ClassDB.class_exists("EditorSettings"):
		return
	var settings: Object = EditorInterface.get_editor_settings()
	if settings != null and settings.has_method("set_setting"):
		settings.set_setting(RECENT_SETTINGS_KEY, _recent_resources.duplicate(true))


func _find_by_identifier(values: Array, identifier: String) -> Dictionary:
	for value in values:
		if value is Dictionary and String(value.get("identifier", "")) == identifier:
			return value
	return {}


func _identifier_for_graph_name(node_name: StringName) -> String:
	for identifier in _graph_node_controls:
		var node: Node = _graph_node_controls[identifier]
		if node != null and StringName(node.name) == node_name:
			return String(identifier)
	return ""


func _port_identifier_for_index(node_identifier: String, port_index: int) -> String:
	var node: Node = _graph_node_controls.get(node_identifier, null)
	if node == null:
		return ""
	var indices: Dictionary = _graph_port_indices.get(node_identifier, {})
	for port_identifier in indices:
		if int(indices[port_identifier]) == port_index:
			return String(port_identifier)
	return ""


func _arrange_graph() -> void:
	if _document_model == null or _current_kind != WorkspaceState.KIND_TASK_GRAPH:
		return
	var document: Dictionary = _document_model.call("get_document", _current_kind, _current_identifier)
	var commands: Array = []
	var unit := _theme_unit()
	for index in range(Array(document.get("nodes", [])).size()):
		var node: Dictionary = document["nodes"][index]
		if node is Dictionary:
			commands.append(DocumentCommand.set_node_position(_current_identifier, String(node.get("identifier", "")), WorkspaceState.default_node_position(index, unit)))
	if commands.is_empty():
		return
	_apply_document_command(DocumentCommand.batch(commands), "Arrange task graph")


func _resource_array(resource: Object, property: String) -> Array:
	if resource == null:
		return []
	if resource.has_method("get_" + property):
		var value: Variant = resource.call("get_" + property)
		return Array(value) if value is Array or value is PackedStringArray else []
	var value: Variant = resource.get(property)
	return Array(value) if value is Array or value is PackedStringArray else []


func _find_resource_by_identifier(values: Array, identifier: String) -> Object:
	for value in values:
		if value is Object and value.has_method("get_identifier") and String(value.call("get_identifier")) == identifier:
			return value
	return null


func _set_resource_property(resource: Object, property: String, value: Variant) -> void:
	if resource == null:
		return
	var setter := "set_" + property
	if resource.has_method(setter):
		resource.call(setter, value)
		return
	for item in resource.get_property_list():
		if String(item.get("name", "")) == property:
			resource.set(property, value)
			return


func _as_vector2(value: Variant, fallback: Array) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2(float(fallback[0]), float(fallback[1]))
