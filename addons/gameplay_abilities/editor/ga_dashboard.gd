@tool
class_name GameplayAbilitiesDashboard
extends VBoxContainer

## Bottom-panel editor dock for authoring GameplayAbilities definitions.
##
## Modeled loosely on yulrun/godot-gas's "Editor Dashboard" (a @tool dock
## with CRUD for tags/cues and generators), rebuilt from scratch against
## this addon's own native resource classes and
## [GameplayDefinitionValidation]/[GameplayDefinitionValidator]. Registered
## from [code]plugin.gd[/code] via [method EditorPlugin.add_control_to_bottom_panel];
## see that file for the registration/teardown side.
##
## The whole UI is built in code (no companion [code].tscn[/code]) so the
## diff for future changes stays readable. Every method that does not touch
## [EditorInterface]/[EditorFileDialog]/[EditorSettings] is a [code]static[/code]
## function taking/returning plain data (Dictionary/Array/String), so a
## headless smoke test can call them directly without running inside the
## editor or instantiating this node at all --
## [code]tests/gameplay_abilities/smoke/test_editor_dashboard.gd[/code] does
## exactly that. [method _ready] itself only touches [EditorInterface] when
## [method Engine.is_editor_hint] is true, so even instantiating the full
## node is safe in a headless [code]godot --headless run[/code] of a test
## scene (there, [code]is_editor_hint()[/code] is false, exactly like any
## other exported/runtime execution).
##
## Degrades to a single centered warning label (see [method _build_degraded_ui])
## when the native extension is not built for the current platform --
## mirrors the check [code]plugin.gd[/code] itself already performs.

const REQUIRED_NATIVE_CLASS := "GameplayAbilityVersion"

## -- Definition kinds -------------------------------------------------------
## These seven match the grouping the "Definitions browser" (item 1) and the
## "+ New" menu (item 4) both use. Deliberately excludes standalone
## GameplayTagQueryResource files -- those are embedded/authored inline on
## effects and abilities, not one of the top-level authored kinds a game
## author browses or creates fresh from this dock.

const KIND_TAG := "tag"
const KIND_ATTRIBUTE := "attribute"
const KIND_EFFECT := "effect"
const KIND_ABILITY := "ability"
const KIND_CUE := "cue"
const KIND_TARGET_SCHEMA := "target_schema"
const KIND_NETWORK_POLICY := "network_policy"

const KIND_ORDER: PackedStringArray = [
	KIND_TAG, KIND_ATTRIBUTE, KIND_EFFECT, KIND_ABILITY, KIND_CUE, KIND_TARGET_SCHEMA, KIND_NETWORK_POLICY,
]

const KIND_LABELS := {
	KIND_TAG: "Tags",
	KIND_ATTRIBUTE: "Attributes",
	KIND_EFFECT: "Effects",
	KIND_ABILITY: "Abilities",
	KIND_CUE: "Cues",
	KIND_TARGET_SCHEMA: "Target Schemas",
	KIND_NETWORK_POLICY: "Network Policies",
}

const KIND_SINGULAR_LABELS := {
	KIND_TAG: "Tag",
	KIND_ATTRIBUTE: "Attribute",
	KIND_EFFECT: "Effect",
	KIND_ABILITY: "Ability",
	KIND_CUE: "Cue",
	KIND_TARGET_SCHEMA: "Target Schema",
	KIND_NETWORK_POLICY: "Network Policy",
}

## Filename prefixes, matching the convention already used by hand-authored
## samples (see e.g. examples/gameplay_abilities/basic_combat/definitions/).
const KIND_FILE_PREFIX := {
	KIND_TAG: "tag",
	KIND_ATTRIBUTE: "attribute",
	KIND_EFFECT: "effect",
	KIND_ABILITY: "ability",
	KIND_CUE: "cue",
	KIND_TARGET_SCHEMA: "target_schema",
	KIND_NETWORK_POLICY: "network_policy",
}

## -- The identifier rule (docs/authoring.md "The identifier rule") ---------
## identifier = segment ('.' segment)+   -- at least TWO segments
## segment    = [a-z][a-z0-9_]*
const IDENTIFIER_PATTERN := "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$"
const MAX_IDENTIFIER_BYTES := 128
const MAX_IDENTIFIER_SEGMENTS := 8

const SETTINGS_SECTION := "gameplay_abilities_dashboard"
const SETTINGS_KEY_DIRECTORY := "definitions_directory"
const DEFAULT_DIRECTORY := "res://"

## Root the Catalog tab's rename/delete/migration flows scan for project
## resource/scene references (tasks.md 2.5). "res://" -- the whole project --
## matches spec.md's "project resource files" wording; scans skip
## dot-directories (see [method find_project_resource_and_scene_files]) so
## `.godot/` caches are never walked.
const PROJECT_SCAN_ROOT := "res://"

# --- UI node refs (built by _build_ui/_build_degraded_ui) -------------------

var _dir_edit: LineEdit
var _scan_button: Button
var _new_menu_button: MenuButton
var _definitions_tree: Tree
var _validate_button: Button
var _findings_list: ItemList
var _status_label: Label
var _copy_button: Button
var _tag_tree: Tree

var _new_dialog: ConfirmationDialog
var _new_identifier_edit: LineEdit
var _new_error_label: Label
var _new_folder_edit: LineEdit
var _new_kind: String = ""

# --- Catalog tab node refs (tasks.md section 2) ------------------------------
# The "Definitions"/"Validate"/"Tag Hierarchy" tabs above stay unchanged and
# keep serving the legacy directory-scan workflow (design.md "Existing
# scenes continue configuring from component arrays when no ... catalog
# resolves"); THIS tab is what a catalog-based project uses day to day, and
# is the first/default tab (tasks.md 2.1: the catalog, not a directory scan,
# is now the source of truth).

## Optional: assigned by plugin.gd so every Inspector picker anywhere shares
## this dashboard's current catalog selection (design.md decision 2). Left
## null in a headless test instantiation -- every method below tolerates
## that (see [method _select_catalog]).
var catalog_context: GAActiveCatalogContext = null

var _catalog: Resource = null
var _catalog_path: String = ""

var _catalog_path_label: Label
var _catalog_summary_label: Label
var _catalog_validate_button: Button
var _catalog_findings_list: ItemList
var _catalog_status_label: Label
## Parallel to _catalog_findings_list's items, exactly like _finding_paths.
var _catalog_finding_paths: PackedStringArray = PackedStringArray()
var _catalog_tag_list: ItemList
var _catalog_new_tag_button: Button
var _catalog_rename_tag_button: Button
var _catalog_delete_tag_button: Button

var _catalog_new_tag_dialog: ConfirmationDialog
var _catalog_new_tag_edit: LineEdit
var _catalog_new_tag_error_label: Label

## Shared by both the rename and delete confirmation flows -- see
## [method _on_catalog_rename_tag_pressed]/[method _on_catalog_delete_tag_pressed].
var _rename_dialog: ConfirmationDialog
var _rename_current_label: Label
var _rename_new_id_label: Label
var _rename_identifier_edit: LineEdit
var _rename_error_label: Label
var _rename_usage_label: Label
var _lifecycle_mode: String = "" # "rename" or "delete"
var _lifecycle_kind: String = "" # a GACatalogService.KIND_* definition kind, e.g. "tag"
var _lifecycle_target_identifier: String = ""
var _lifecycle_usage_report: Dictionary = {}

# --- Migration tab node refs (tasks.md 2.6) ----------------------------------

var _migration_scan_button: Button
var _migration_preview_list: ItemList
var _migration_accept_button: Button
var _migration_status_label: Label
var _migration_sources: Array = []
var _migration_preview_result: Dictionary = {}

# --- State -------------------------------------------------------------------

## kind (String) -> Array of {identifier: String, path: String, resource: Resource}
var _last_scan: Dictionary = {}
## Parallel to _findings_list's items: resource_path for each row, "" if none.
var _finding_paths: PackedStringArray = PackedStringArray()
var _last_fingerprint_text: String = ""


func _ready() -> void:
	if not ClassDB.class_exists(REQUIRED_NATIVE_CLASS):
		_build_degraded_ui()
		return

	_build_ui()

	# EditorSettings/EditorInterface are only meaningful while actually
	# running inside the editor -- guarding here is what keeps this node
	# safe to instantiate in a headless `godot --headless run` of a test
	# scene (Engine.is_editor_hint() is false there, same as any other
	# runtime execution).
	if Engine.is_editor_hint():
		_restore_directory()
	_scan()

	# Default-select the project catalog (tasks.md 2.1). When the runtime
	# project setting is intentionally empty but the project contains exactly
	# one saved catalog, that catalog is also an unambiguous editor selection.
	# This keeps Inspector pickers useful for samples/tests that must leave the
	# global runtime default empty to exercise legacy component arrays.
	var project_default_catalog_path := GACatalogService.project_default_path()
	var saved_catalog_paths := PackedStringArray()
	if Engine.is_editor_hint() and project_default_catalog_path.is_empty():
		saved_catalog_paths = GACatalogService.find_catalog_paths(
			find_definition_files(PROJECT_SCAN_ROOT)
		)
	var initial_catalog_path := GACatalogService.initial_editor_catalog_path(
		project_default_catalog_path, saved_catalog_paths
	)
	_select_catalog(initial_catalog_path)


# =============================================================================
# Pure logic -- no EditorInterface/EditorFileDialog/EditorSettings calls.
# Safe to call directly on the class (no instantiation needed), exactly like
# GameplayDefinitionValidation's own static entry points.
# =============================================================================

## Classifies [param resource] into one of the [constant KIND_ORDER] kinds,
## or "" when it is null or not one of the seven authored definition types.
static func classify_resource(resource: Resource) -> String:
	if resource == null:
		return ""
	if resource is GameplayTagDefinition:
		return KIND_TAG
	if resource is GameplayAttributeDefinition:
		return KIND_ATTRIBUTE
	if resource is GameplayEffectDefinition:
		return KIND_EFFECT
	if resource is GameplayAbilityDefinition:
		return KIND_ABILITY
	if resource is GameplayCueDefinition:
		return KIND_CUE
	if resource is GameplayTargetDataSchema:
		return KIND_TARGET_SCHEMA
	if resource is GameplayNetworkPolicy:
		return KIND_NETWORK_POLICY
	return ""


## Recursively collects every [code].tres[/code]/[code].res[/code]/
## [code].tscn[/code] path beneath [param p_directory] -- broader than
## [method find_definition_files] below (which only collects .tres/.res,
## since scenes are never one of the seven authored definition KINDs this
## dashboard classifies) because rename/delete/migration usage scanning
## (tasks.md 2.5, [GAUsageScanner]) must also find references embedded in
## scenes. Skips dot-directories exactly like [method find_definition_files].
static func find_project_resource_and_scene_files(p_directory: String) -> PackedStringArray:
	var results := PackedStringArray()
	var dir := DirAccess.open(p_directory)
	if dir == null:
		return results
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full_path := p_directory.path_join(entry)
			if dir.current_is_dir():
				results.append_array(find_project_resource_and_scene_files(full_path))
			elif entry.ends_with(".tres") or entry.ends_with(".res") or entry.ends_with(".tscn"):
				results.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	return results


## Recursively collects every [code].tres[/code]/[code].res[/code] path
## beneath [param p_directory]. Returns an empty result rather than erroring
## when the directory is missing, matching
## [code]GameplayDefinitionValidation._find_tres_files[/code]'s own
## bounded-no-op behavior.
static func find_definition_files(p_directory: String) -> PackedStringArray:
	var results := PackedStringArray()
	var dir := DirAccess.open(p_directory)
	if dir == null:
		return results
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full_path := p_directory.path_join(entry)
			if dir.current_is_dir():
				results.append_array(find_definition_files(full_path))
			elif entry.ends_with(".tres") or entry.ends_with(".res"):
				results.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	return results


## Recursively finds every definition resource under [param p_directory],
## loads each with [ResourceLoader], classifies it, and groups the result by
## kind. Each entry is [code]{identifier, path, resource}[/code]; groups are
## sorted by identifier (falling back to path when the identifier is empty,
## e.g. [GameplayNetworkPolicy], which has no identifier field). Every one of
## [constant KIND_ORDER] is present in the returned Dictionary, even if empty.
static func scan_directory(p_directory: String) -> Dictionary:
	var grouped: Dictionary = {}
	for kind in KIND_ORDER:
		grouped[kind] = []

	for path in find_definition_files(p_directory):
		var resource: Resource = ResourceLoader.load(path)
		var kind := classify_resource(resource)
		if kind.is_empty():
			continue
		var identifier := ""
		if resource.has_method("get_identifier"):
			identifier = String(resource.call("get_identifier"))
		var entries: Array = grouped[kind]
		entries.append({"identifier": identifier, "path": path, "resource": resource})

	for kind in grouped:
		var entries: Array = grouped[kind]
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if a["identifier"] == b["identifier"]:
				return a["path"] < b["path"]
			return a["identifier"] < b["identifier"])

	return grouped


## Client-side syntax check for the identifier grammar (docs/authoring.md
## "The identifier rule"). Returns "" when [param identifier] is valid, or a
## human-readable error message otherwise -- the "+ New" dialog shows this
## inline rather than letting an invalid identifier reach [ResourceSaver].
## This mirrors, but does not replace, the authoritative check
## (`ga::validate_identifier`) [GameplayDefinitionValidator] runs at
## validation time -- this is a fast client-side pre-check only.
static func check_identifier(identifier: String) -> String:
	if identifier.is_empty():
		return "Identifier must not be empty."
	var byte_count := identifier.to_utf8_buffer().size()
	if byte_count > MAX_IDENTIFIER_BYTES:
		return "Identifier must be at most %d bytes (got %d)." % [MAX_IDENTIFIER_BYTES, byte_count]
	var segments := identifier.split(".")
	if segments.size() < 2:
		return "Identifier needs at least two dot-separated segments (e.g. \"state.control\"), not \"%s\"." % identifier
	if segments.size() > MAX_IDENTIFIER_SEGMENTS:
		return "Identifier must have at most %d segments (got %d)." % [MAX_IDENTIFIER_SEGMENTS, segments.size()]
	var regex := RegEx.new()
	regex.compile(IDENTIFIER_PATTERN)
	if regex.search(identifier) == null:
		return "Each segment must be lowercase, start with a letter, and contain only [a-z0-9_] (e.g. \"state.control.stunned\")."
	return ""


## Builds a nested-Dictionary hierarchy from a flat list of dotted tag
## identifiers -- [code]state.control.stunned[/code] nests under
## [code]state.control[/code] under [code]state[/code]. Each level is
## [code]{segment_name: {full, has_resource, children}}[/code]:
##   full:         the dotted identifier up to and including this segment
##   has_resource: true when this exact dotted path is one of the input
##                 identifiers (i.e. an actual GameplayTagDefinition exists);
##                 false for a purely intermediate segment with no backing
##                 resource ("implicit" in the tag hierarchy view)
##   children:     the same shape, one level deeper
## Body moved to [method GATagHierarchy.build_hierarchy] (tasks.md 2.1/2.2
## refactor, so [GAPickerPopup] and this dashboard share ONE implementation)
## -- this forwards to it so the return shape and this method's own already
## smoke-tested public API stay byte-for-byte identical.
static func build_tag_hierarchy(identifiers: PackedStringArray) -> Dictionary:
	return GATagHierarchy.build_hierarchy(identifiers)


## Suggested filename for a newly created definition, matching the existing
## sample naming convention (e.g. "tag_state_control_stunned.tres").
static func suggest_filename(kind: String, identifier: String) -> String:
	var prefix: String = KIND_FILE_PREFIX.get(kind, kind)
	var slug := identifier.replace(".", "_")
	return "%s_%s.tres" % [prefix, slug]


## Instantiates the native resource class for [param kind] and sets its
## identifier (when the class has one -- [GameplayNetworkPolicy] does not,
## see that class's header comment). Returns null for an unrecognized kind.
static func create_definition(kind: String, identifier: String) -> Resource:
	var resource: Resource
	match kind:
		KIND_TAG:
			resource = GameplayTagDefinition.new()
		KIND_ATTRIBUTE:
			resource = GameplayAttributeDefinition.new()
		KIND_EFFECT:
			resource = GameplayEffectDefinition.new()
		KIND_ABILITY:
			resource = GameplayAbilityDefinition.new()
		KIND_CUE:
			resource = GameplayCueDefinition.new()
		KIND_TARGET_SCHEMA:
			resource = GameplayTargetDataSchema.new()
		KIND_NETWORK_POLICY:
			resource = GameplayNetworkPolicy.new()
		_:
			return null
	if resource.has_method("set_identifier"):
		resource.call("set_identifier", StringName(identifier))
	return resource


## Canonical, zero-padded, unsigned 64-bit hex rendering of a manifest
## fingerprint (native side stores it as a signed int64_t bit pattern -- see
## [method GameplayDefinitionValidator.get_last_manifest_fingerprint]).
## [method String.num_uint64] treats the bit pattern as unsigned, unlike
## plain "%x" formatting, so two builds with the same underlying fingerprint
## always render the identical hex string.
static func format_fingerprint(fingerprint: int) -> String:
	return "0x%s" % String.num_uint64(fingerprint, 16).lpad(16, "0")


static func _severity_badge(severity: String) -> String:
	if severity.is_empty():
		return "[?]"
	if severity == "error":
		return "[ERROR]"
	if severity == "warning":
		return "[WARN]"
	return "[%s]" % severity.to_upper()


# =============================================================================
# UI construction
# =============================================================================

func _build_degraded_ui() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = (
		"GameplayAbilities: native class '%s' is not registered. Build the addon's "
		% REQUIRED_NATIVE_CLASS
		+ "GDExtension for this platform (see addons/gameplay_abilities/release_manifest.json)."
	)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(label)


func _build_ui() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, 260)

	var toolbar := HBoxContainer.new()
	add_child(toolbar)

	var dir_label := Label.new()
	dir_label.text = "Directory:"
	toolbar.add_child(dir_label)

	_dir_edit = LineEdit.new()
	_dir_edit.text = DEFAULT_DIRECTORY
	_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dir_edit.text_submitted.connect(func(_text: String) -> void: _scan())
	toolbar.add_child(_dir_edit)

	var browse_button := Button.new()
	browse_button.text = "Browse..."
	browse_button.pressed.connect(_on_browse_pressed)
	toolbar.add_child(browse_button)

	_scan_button = Button.new()
	_scan_button.text = "Scan"
	_scan_button.pressed.connect(_on_scan_pressed)
	toolbar.add_child(_scan_button)

	_new_menu_button = MenuButton.new()
	_new_menu_button.text = "+ New"
	var new_popup := _new_menu_button.get_popup()
	for i in range(KIND_ORDER.size()):
		new_popup.add_item(KIND_SINGULAR_LABELS[KIND_ORDER[i]], i)
	new_popup.id_pressed.connect(_on_new_menu_item_pressed)
	toolbar.add_child(_new_menu_button)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)

	# --- Catalog tab (first/default -- tasks.md 2.1: the selected catalog,
	# not a directory scan, is the source of truth) ---
	tabs.add_child(_build_catalog_tab())

	# --- Definitions tab (legacy directory scan) ---
	var definitions_tab := VBoxContainer.new()
	definitions_tab.name = "Definitions"
	definitions_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_definitions_tree = Tree.new()
	_definitions_tree.columns = 2
	_definitions_tree.column_titles_visible = true
	_definitions_tree.set_column_title(0, "Identifier")
	_definitions_tree.set_column_title(1, "Path")
	_definitions_tree.hide_root = true
	_definitions_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_definitions_tree.item_activated.connect(_on_definitions_tree_item_activated)
	definitions_tab.add_child(_definitions_tree)
	tabs.add_child(definitions_tab)

	# --- Validate tab ---
	var validate_tab := VBoxContainer.new()
	validate_tab.name = "Validate"
	validate_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_validate_button = Button.new()
	_validate_button.text = "Validate"
	_validate_button.pressed.connect(_on_validate_pressed)
	validate_tab.add_child(_validate_button)
	_findings_list = ItemList.new()
	_findings_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_findings_list.item_activated.connect(_on_findings_item_activated)
	validate_tab.add_child(_findings_list)
	var status_row := HBoxContainer.new()
	_status_label = Label.new()
	_status_label.text = "Not yet validated."
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)
	_copy_button = Button.new()
	_copy_button.text = "Copy"
	_copy_button.disabled = true
	_copy_button.tooltip_text = "Copy the content-manifest fingerprint to the clipboard."
	_copy_button.pressed.connect(_on_copy_fingerprint_pressed)
	status_row.add_child(_copy_button)
	validate_tab.add_child(status_row)
	tabs.add_child(validate_tab)

	# --- Tag Hierarchy tab ---
	var hierarchy_tab := VBoxContainer.new()
	hierarchy_tab.name = "Tag Hierarchy"
	hierarchy_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tag_tree = Tree.new()
	_tag_tree.hide_root = true
	_tag_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hierarchy_tab.add_child(_tag_tree)
	tabs.add_child(hierarchy_tab)

	# --- Migration tab (tasks.md 2.6) ---
	tabs.add_child(_build_migration_tab())

	_build_new_dialog()


func _build_new_dialog() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New Definition"
	_new_dialog.min_size = Vector2i(380, 180)

	var vbox := VBoxContainer.new()

	var identifier_label := Label.new()
	identifier_label.text = "Identifier"
	vbox.add_child(identifier_label)

	_new_identifier_edit = LineEdit.new()
	_new_identifier_edit.placeholder_text = "e.g. state.control.stunned"
	_new_identifier_edit.text_changed.connect(_on_new_identifier_changed)
	vbox.add_child(_new_identifier_edit)

	_new_error_label = Label.new()
	_new_error_label.add_theme_color_override("font_color", Color(0.94, 0.36, 0.36))
	_new_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_new_error_label)

	var folder_label := Label.new()
	folder_label.text = "Target Folder"
	vbox.add_child(folder_label)

	var folder_row := HBoxContainer.new()
	_new_folder_edit = LineEdit.new()
	_new_folder_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folder_row.add_child(_new_folder_edit)
	var folder_browse_button := Button.new()
	folder_browse_button.text = "Browse..."
	folder_browse_button.pressed.connect(_on_new_folder_browse_pressed)
	folder_row.add_child(folder_browse_button)
	vbox.add_child(folder_row)

	_new_dialog.add_child(vbox)
	_new_dialog.confirmed.connect(_on_new_dialog_confirmed)
	add_child(_new_dialog)


func _build_catalog_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Catalog"
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var path_row := HBoxContainer.new()
	var path_caption := Label.new()
	path_caption.text = "Catalog:"
	path_row.add_child(path_caption)
	_catalog_path_label = Label.new()
	_catalog_path_label.text = "(none selected)"
	_catalog_path_label.clip_text = true
	_catalog_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(_catalog_path_label)
	var open_button := Button.new()
	open_button.text = "Open..."
	open_button.pressed.connect(_on_open_catalog_pressed)
	path_row.add_child(open_button)
	var new_catalog_button := Button.new()
	new_catalog_button.text = "New..."
	new_catalog_button.pressed.connect(_on_new_catalog_pressed)
	path_row.add_child(new_catalog_button)
	var reload_button := Button.new()
	reload_button.text = "Reload"
	reload_button.pressed.connect(func() -> void: _select_catalog(_catalog_path))
	path_row.add_child(reload_button)
	var use_default_button := Button.new()
	use_default_button.text = "Use Project Default"
	use_default_button.tooltip_text = "gameplay_abilities/default_definition_catalog"
	use_default_button.pressed.connect(func() -> void: _select_catalog(GACatalogService.project_default_path()))
	path_row.add_child(use_default_button)
	tab.add_child(path_row)

	_catalog_summary_label = Label.new()
	_catalog_summary_label.text = "No catalog selected."
	tab.add_child(_catalog_summary_label)

	_catalog_validate_button = Button.new()
	_catalog_validate_button.text = "Validate Catalog"
	_catalog_validate_button.pressed.connect(_on_validate_catalog_pressed)
	tab.add_child(_catalog_validate_button)

	_catalog_findings_list = ItemList.new()
	_catalog_findings_list.custom_minimum_size = Vector2(0, 80)
	_catalog_findings_list.item_activated.connect(_on_catalog_findings_item_activated)
	tab.add_child(_catalog_findings_list)

	_catalog_status_label = Label.new()
	_catalog_status_label.text = "Not yet validated."
	tab.add_child(_catalog_status_label)

	var tags_label := Label.new()
	tags_label.text = "Tags in catalog:"
	tab.add_child(tags_label)

	_catalog_tag_list = ItemList.new()
	_catalog_tag_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(_catalog_tag_list)

	var tag_buttons_row := HBoxContainer.new()
	_catalog_new_tag_button = Button.new()
	_catalog_new_tag_button.text = "New Tag..."
	_catalog_new_tag_button.pressed.connect(_on_catalog_new_tag_pressed)
	tag_buttons_row.add_child(_catalog_new_tag_button)
	_catalog_rename_tag_button = Button.new()
	_catalog_rename_tag_button.text = "Rename..."
	_catalog_rename_tag_button.pressed.connect(_on_catalog_rename_tag_pressed)
	tag_buttons_row.add_child(_catalog_rename_tag_button)
	_catalog_delete_tag_button = Button.new()
	_catalog_delete_tag_button.text = "Delete..."
	_catalog_delete_tag_button.pressed.connect(_on_catalog_delete_tag_pressed)
	tag_buttons_row.add_child(_catalog_delete_tag_button)
	tab.add_child(tag_buttons_row)

	_build_catalog_new_tag_dialog()
	_build_rename_dialog()

	return tab


func _build_catalog_new_tag_dialog() -> void:
	_catalog_new_tag_dialog = ConfirmationDialog.new()
	_catalog_new_tag_dialog.title = "New Tag"
	_catalog_new_tag_dialog.min_size = Vector2i(380, 160)

	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = "Identifier"
	vbox.add_child(label)

	_catalog_new_tag_edit = LineEdit.new()
	_catalog_new_tag_edit.placeholder_text = "e.g. state.control.stunned"
	_catalog_new_tag_edit.text_changed.connect(_on_catalog_new_tag_identifier_changed)
	vbox.add_child(_catalog_new_tag_edit)

	_catalog_new_tag_error_label = Label.new()
	_catalog_new_tag_error_label.add_theme_color_override("font_color", Color(0.94, 0.36, 0.36))
	_catalog_new_tag_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_catalog_new_tag_error_label)

	_catalog_new_tag_dialog.add_child(vbox)
	_catalog_new_tag_dialog.confirmed.connect(_on_catalog_new_tag_confirmed)
	add_child(_catalog_new_tag_dialog)


## Shared by both the rename and delete flows (tasks.md 2.5) -- which fields
## are visible/what gets applied on confirm depends on [member _lifecycle_mode].
func _build_rename_dialog() -> void:
	_rename_dialog = ConfirmationDialog.new()
	_rename_dialog.min_size = Vector2i(440, 260)

	var vbox := VBoxContainer.new()

	_rename_current_label = Label.new()
	vbox.add_child(_rename_current_label)

	_rename_new_id_label = Label.new()
	_rename_new_id_label.text = "New Identifier"
	vbox.add_child(_rename_new_id_label)

	_rename_identifier_edit = LineEdit.new()
	_rename_identifier_edit.text_changed.connect(_on_rename_identifier_changed)
	vbox.add_child(_rename_identifier_edit)

	_rename_error_label = Label.new()
	_rename_error_label.add_theme_color_override("font_color", Color(0.94, 0.36, 0.36))
	_rename_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_rename_error_label)

	_rename_usage_label = Label.new()
	_rename_usage_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_rename_usage_label)

	_rename_dialog.add_child(vbox)
	_rename_dialog.confirmed.connect(_on_rename_dialog_confirmed)
	add_child(_rename_dialog)


func _build_migration_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Migration"
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var info := Label.new()
	info.text = (
		"Preview legacy component-array definitions found under the currently "
		+ "edited scene, then copy the unique ones into the selected catalog and "
		+ "clear the migrated component fields in one undoable action. Never "
		+ "run implicitly -- this tab is the only way legacy fields change."
	)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	tab.add_child(info)

	_migration_scan_button = Button.new()
	_migration_scan_button.text = "Scan Edited Scene"
	_migration_scan_button.pressed.connect(_on_migration_scan_pressed)
	tab.add_child(_migration_scan_button)

	_migration_preview_list = ItemList.new()
	_migration_preview_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(_migration_preview_list)

	_migration_accept_button = Button.new()
	_migration_accept_button.text = "Accept Migration"
	_migration_accept_button.disabled = true
	_migration_accept_button.pressed.connect(_on_migration_accept_pressed)
	tab.add_child(_migration_accept_button)

	_migration_status_label = Label.new()
	_migration_status_label.text = "Not yet scanned."
	tab.add_child(_migration_status_label)

	return tab


# =============================================================================
# Scan / definitions browser / tag hierarchy
# =============================================================================

func _scan() -> void:
	var directory := _dir_edit.text.strip_edges()
	if directory.is_empty():
		directory = DEFAULT_DIRECTORY
	_dir_edit.text = directory
	_last_scan = scan_directory(directory)
	_populate_definitions_tree()
	_populate_tag_hierarchy()
	if Engine.is_editor_hint():
		_persist_directory(directory)


func _on_scan_pressed() -> void:
	_scan()


func _populate_definitions_tree() -> void:
	_definitions_tree.clear()
	var root := _definitions_tree.create_item()
	for kind in KIND_ORDER:
		var entries: Array = _last_scan.get(kind, [])
		var kind_item := _definitions_tree.create_item(root)
		kind_item.set_text(0, "%s (%d)" % [KIND_LABELS[kind], entries.size()])
		kind_item.set_selectable(0, false)
		kind_item.set_selectable(1, false)
		for entry in entries:
			var identifier: String = entry["identifier"]
			var path: String = entry["path"]
			var child := _definitions_tree.create_item(kind_item)
			child.set_text(0, identifier if not identifier.is_empty() else "(no identifier)")
			child.set_text(1, path)
			child.set_tooltip_text(0, path)
			child.set_metadata(0, path)


func _on_definitions_tree_item_activated() -> void:
	var item := _definitions_tree.get_selected()
	if item == null:
		return
	var path_variant: Variant = item.get_metadata(0)
	if typeof(path_variant) != TYPE_STRING:
		return
	var path := String(path_variant)
	if not path.is_empty():
		_open_resource(path)


func _populate_tag_hierarchy() -> void:
	_tag_tree.clear()
	var identifiers := PackedStringArray()
	for entry in _last_scan.get(KIND_TAG, []):
		identifiers.append(entry["identifier"])
	var hierarchy := build_tag_hierarchy(identifiers)
	var root := _tag_tree.create_item()
	_add_tag_tree_children(root, hierarchy)


func _add_tag_tree_children(parent: TreeItem, node: Dictionary) -> void:
	var segments := node.keys()
	segments.sort()
	for segment in segments:
		var info: Dictionary = node[segment]
		var item := _tag_tree.create_item(parent)
		var has_resource: bool = info["has_resource"]
		item.set_text(0, segment if has_resource else "%s (implicit)" % segment)
		item.set_tooltip_text(0, info["full"])
		if not has_resource:
			item.set_custom_color(0, Color(0.6, 0.6, 0.6))
		_add_tag_tree_children(item, info["children"])


func _resources_of_kind(kind: String) -> Array:
	var result: Array = []
	for entry in _last_scan.get(kind, []):
		result.append(entry["resource"])
	return result


# =============================================================================
# Validate panel
# =============================================================================

func _on_validate_pressed() -> void:
	_scan()

	var directory := _dir_edit.text
	var result := GameplayDefinitionValidation.validate_directory_with_manifest(directory)
	var findings: Array[Dictionary] = result["findings"]

	var abilities := _resources_of_kind(KIND_ABILITY)
	if not abilities.is_empty():
		var typed_tags: Array[GameplayTagDefinition] = []
		typed_tags.assign(_resources_of_kind(KIND_TAG))
		var typed_attributes: Array[GameplayAttributeDefinition] = []
		typed_attributes.assign(_resources_of_kind(KIND_ATTRIBUTE))
		var typed_effects: Array[GameplayEffectDefinition] = []
		typed_effects.assign(_resources_of_kind(KIND_EFFECT))
		var typed_cues: Array[GameplayCueDefinition] = []
		typed_cues.assign(_resources_of_kind(KIND_CUE))
		var typed_abilities: Array[GameplayAbilityDefinition] = []
		typed_abilities.assign(abilities)

		var ability_findings: Array[Dictionary] = []
		ability_findings.assign(GameplayDefinitionValidator.validate_prediction_eligibility_seam(
			typed_tags, typed_attributes, typed_effects, typed_cues, typed_abilities))
		findings.append_array(ability_findings)

	_populate_findings(findings)

	var ok := GameplayDefinitionValidation.is_ok(findings)
	if ok and bool(result.get("manifest_ok", false)):
		_last_fingerprint_text = format_fingerprint(result["fingerprint"])
		_status_label.text = "OK  fingerprint=%s  entries=%d  tick_rate=%d" % [
			_last_fingerprint_text, result["entry_count"], result["tick_rate"],
		]
		_copy_button.disabled = false
	else:
		_last_fingerprint_text = ""
		_status_label.text = "%d finding(s) -- see list below." % findings.size()
		_copy_button.disabled = true


func _populate_findings(findings: Array[Dictionary]) -> void:
	_findings_list.clear()
	_finding_paths.clear()

	if findings.is_empty():
		_findings_list.add_item("No findings.")
		_finding_paths.append("")
		return

	for finding in findings:
		var severity := String(finding.get("severity", ""))
		var code := String(finding.get("code", ""))
		var path := String(finding.get("resource_path", ""))
		var message := String(finding.get("message", ""))
		var text := "%s (%s) %s: %s" % [_severity_badge(severity), code, path, message]
		var index := _findings_list.add_item(text)
		if severity == GameplayDefinitionValidation.SEVERITY_ERROR:
			_findings_list.set_item_custom_fg_color(index, Color(0.94, 0.36, 0.36))
		_finding_paths.append(path)


func _on_findings_item_activated(index: int) -> void:
	if index < 0 or index >= _finding_paths.size():
		return
	var path := _finding_paths[index]
	if not path.is_empty():
		_open_resource(path)


func _on_copy_fingerprint_pressed() -> void:
	if _last_fingerprint_text.is_empty():
		return
	DisplayServer.clipboard_set(_last_fingerprint_text)


# =============================================================================
# "+ New" definition creation
# =============================================================================

func _on_new_menu_item_pressed(id: int) -> void:
	if id < 0 or id >= KIND_ORDER.size():
		return
	_new_kind = KIND_ORDER[id]
	_new_dialog.title = "New %s" % KIND_SINGULAR_LABELS[_new_kind]
	_new_identifier_edit.text = ""
	_new_error_label.text = ""
	_new_folder_edit.text = _dir_edit.text if not _dir_edit.text.is_empty() else DEFAULT_DIRECTORY
	_new_dialog.get_ok_button().disabled = true
	_new_dialog.popup_centered()


func _on_new_identifier_changed(_new_text: String) -> void:
	var error := check_identifier(_new_identifier_edit.text.strip_edges())
	_new_error_label.text = error
	_new_dialog.get_ok_button().disabled = not error.is_empty()


func _on_new_dialog_confirmed() -> void:
	var identifier := _new_identifier_edit.text.strip_edges()
	if not check_identifier(identifier).is_empty():
		return # Defensive only -- the OK button is disabled while invalid.

	var folder := _new_folder_edit.text.strip_edges()
	if folder.is_empty():
		folder = DEFAULT_DIRECTORY

	var resource := create_definition(_new_kind, identifier)
	if resource == null:
		push_warning("GameplayAbilitiesDashboard: unknown definition kind '%s'" % _new_kind)
		return

	var path := folder.path_join(suggest_filename(_new_kind, identifier))
	var err := ResourceSaver.save(resource, path)
	if err != OK:
		push_warning("GameplayAbilitiesDashboard: failed to save '%s' (error %d)" % [path, err])
		return

	if Engine.is_editor_hint():
		var filesystem := EditorInterface.get_resource_filesystem()
		if filesystem != null:
			filesystem.scan()
		var reloaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		EditorInterface.edit_resource(reloaded if reloaded != null else resource)

	_scan()


# =============================================================================
# Catalog tab (tasks.md 2.1, 2.4, 2.5) -- operates on ONE selected
# GameplayDefinitionCatalog instead of the legacy directory scan above being
# the source of truth. Every pure decision (what counts as a reference, how
# to rewrite/clear one, how to build a usage report) is delegated to
# GAReferenceRegistry/GAUsageScanner/GARewritePlanner -- this section is
# just the EditorInterface/EditorUndoRedoManager-touching glue around them,
# exactly like the rest of this file's own documented split.
# =============================================================================

func _get_undo_redo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


func _project_resource_paths() -> PackedStringArray:
	return find_project_resource_and_scene_files(PROJECT_SCAN_ROOT)


func _select_catalog(path: String) -> void:
	_catalog_path = path
	_catalog = GACatalogService.load_catalog(path)
	if catalog_context != null:
		catalog_context.set_catalog(_catalog)
	_refresh_catalog_tab()


func _refresh_catalog_tab() -> void:
	if _catalog_path_label == null:
		return # Not built yet (degraded UI, or called before _build_ui()).

	_catalog_path_label.text = _catalog_path if not _catalog_path.is_empty() else "(none selected)"

	if _catalog == null:
		_catalog_summary_label.text = "No catalog selected."
	else:
		var summary := GACatalogService.summarize(_catalog)
		var counts: Dictionary = summary["counts"]
		var lines := PackedStringArray()
		for kind in GACatalogService.KIND_ORDER:
			lines.append("%s: %d" % [GACatalogService.KIND_LABELS[kind], int(counts[kind])])
		lines.append("Total: %d" % int(summary["total"]))
		_catalog_summary_label.text = "\n".join(lines)

	_populate_catalog_tag_list()


func _populate_catalog_tag_list() -> void:
	_catalog_tag_list.clear()
	if _catalog == null:
		return
	var identifiers := GAReferenceRegistry.identifiers_in_catalog(_catalog, GAReferenceRegistry.KIND_TAG)
	var sorted_identifiers := identifiers.duplicate()
	sorted_identifiers.sort()
	for identifier in sorted_identifiers:
		_catalog_tag_list.add_item(identifier)


func _on_open_catalog_pressed() -> void:
	if not Engine.is_editor_hint():
		return
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.tres,*.res", "Gameplay Definition Catalog")
	dialog.file_selected.connect(_select_catalog)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio()


func _on_new_catalog_pressed() -> void:
	if not Engine.is_editor_hint():
		return
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.tres", "Gameplay Definition Catalog")
	dialog.file_selected.connect(_on_new_catalog_path_selected)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio()


func _on_new_catalog_path_selected(path: String) -> void:
	var catalog := GACatalogService.create_empty_catalog()
	var err := ResourceSaver.save(catalog, path)
	if err != OK:
		push_warning("GameplayAbilitiesDashboard: failed to save new catalog '%s' (error %d)" % [path, err])
		return
	if Engine.is_editor_hint():
		var filesystem := EditorInterface.get_resource_filesystem()
		if filesystem != null:
			filesystem.scan()
	_select_catalog(path)


func _on_validate_catalog_pressed() -> void:
	if _catalog == null:
		_catalog_status_label.text = "No catalog selected."
		_populate_catalog_findings([])
		return
	var result := GameplayDefinitionValidation.validate_catalog_resource(_catalog)
	var findings: Array[Dictionary] = result["findings"]
	_populate_catalog_findings(findings)
	if GameplayDefinitionValidator.is_ok(findings) and bool(result.get("manifest_ok", false)):
		_last_fingerprint_text = format_fingerprint(result["fingerprint"])
		_catalog_status_label.text = "OK  fingerprint=%s  entries=%d  tick_rate=%d" % [
			_last_fingerprint_text, result["entry_count"], result["tick_rate"],
		]
	else:
		_catalog_status_label.text = "%d finding(s) -- see list above." % findings.size()


func _populate_catalog_findings(findings: Array[Dictionary]) -> void:
	_catalog_findings_list.clear()
	_catalog_finding_paths.clear()
	if findings.is_empty():
		_catalog_findings_list.add_item("No findings.")
		_catalog_finding_paths.append("")
		return
	for finding in findings:
		var severity := String(finding.get("severity", ""))
		var code := String(finding.get("code", ""))
		var path := String(finding.get("resource_path", ""))
		var message := String(finding.get("message", ""))
		var text := "%s (%s) %s: %s" % [_severity_badge(severity), code, path, message]
		var index := _catalog_findings_list.add_item(text)
		if severity == GameplayDefinitionValidation.SEVERITY_ERROR:
			_catalog_findings_list.set_item_custom_fg_color(index, Color(0.94, 0.36, 0.36))
		_catalog_finding_paths.append(path)


func _on_catalog_findings_item_activated(index: int) -> void:
	if index < 0 or index >= _catalog_finding_paths.size():
		return
	var path := _catalog_finding_paths[index]
	if not path.is_empty():
		_open_resource(path)


# --- Create tag (tasks.md 2.5) -----------------------------------------------

func _on_catalog_new_tag_pressed() -> void:
	if _catalog == null:
		push_warning("GameplayAbilitiesDashboard: select or create a catalog before adding a tag.")
		return
	_catalog_new_tag_edit.text = ""
	_catalog_new_tag_error_label.text = ""
	_catalog_new_tag_dialog.get_ok_button().disabled = true
	_catalog_new_tag_dialog.popup_centered()


func _on_catalog_new_tag_identifier_changed(_new_text: String) -> void:
	var identifier := _catalog_new_tag_edit.text.strip_edges()
	var error := check_identifier(identifier)
	if error.is_empty() and _catalog != null:
		var existing := GAReferenceRegistry.identifiers_in_catalog(_catalog, GAReferenceRegistry.KIND_TAG)
		if existing.has(identifier):
			error = "A tag with this identifier already exists in the selected catalog."
	_catalog_new_tag_error_label.text = error
	_catalog_new_tag_dialog.get_ok_button().disabled = not error.is_empty()


func _on_catalog_new_tag_confirmed() -> void:
	if _catalog == null:
		return
	var identifier := _catalog_new_tag_edit.text.strip_edges()
	if not check_identifier(identifier).is_empty():
		return # Defensive only -- the OK button is disabled while invalid.

	var tag := GameplayTagDefinition.new()
	tag.set_identifier(StringName(identifier))
	var old_array: Array = _catalog.get_tag_definitions()
	var new_array := old_array.duplicate()
	new_array.append(tag)

	var undo_redo := _get_undo_redo()
	if undo_redo == null:
		_catalog.set_tag_definitions(new_array)
	else:
		undo_redo.create_action("Create Gameplay Tag '%s'" % identifier)
		undo_redo.add_do_property(_catalog, "tag_definitions", new_array)
		undo_redo.add_undo_property(_catalog, "tag_definitions", old_array)
		undo_redo.commit_action()

	_refresh_catalog_tab()


# --- Rename / delete (tasks.md 2.5) ------------------------------------------

func _selected_catalog_tag_identifier() -> String:
	var selected := _catalog_tag_list.get_selected_items()
	if selected.is_empty():
		return ""
	return _catalog_tag_list.get_item_text(selected[0])


func _on_catalog_rename_tag_pressed() -> void:
	var identifier := _selected_catalog_tag_identifier()
	if identifier.is_empty() or _catalog == null:
		push_warning("GameplayAbilitiesDashboard: select a tag in the list before renaming.")
		return
	_lifecycle_mode = "rename"
	_lifecycle_kind = "tag"
	_lifecycle_target_identifier = identifier
	_rename_dialog.title = "Rename Tag '%s'" % identifier
	_rename_current_label.text = "Renaming: %s" % identifier
	_rename_new_id_label.visible = true
	_rename_identifier_edit.visible = true
	_rename_identifier_edit.text = identifier
	_rename_error_label.text = ""
	_rename_usage_label.text = "Computing usage report..."
	_rename_dialog.get_ok_button().disabled = true
	_rename_dialog.popup_centered()
	_compute_and_show_usage_report(identifier)


func _on_catalog_delete_tag_pressed() -> void:
	var identifier := _selected_catalog_tag_identifier()
	if identifier.is_empty() or _catalog == null:
		push_warning("GameplayAbilitiesDashboard: select a tag in the list before deleting.")
		return
	_lifecycle_mode = "delete"
	_lifecycle_kind = "tag"
	_lifecycle_target_identifier = identifier
	_rename_dialog.title = "Delete Tag '%s'" % identifier
	_rename_current_label.text = "Deleting: %s" % identifier
	_rename_new_id_label.visible = false
	_rename_identifier_edit.visible = false
	_rename_error_label.text = ""
	_rename_usage_label.text = "Computing usage report..."
	_rename_dialog.get_ok_button().disabled = true
	_rename_dialog.popup_centered()
	_compute_and_show_usage_report(identifier)


## Runs [GAUsageScanner.usage_report] for [param identifier] across every
## reference kind that shares [member _lifecycle_kind]'s catalog collection
## (tags: scalar AND packed-array properties -- see
## [method GAReferenceRegistry.reference_kinds_for_definition_kind]), shows
## the result, and enables/disables the dialog's OK button accordingly:
## rename requires a valid, non-colliding new identifier AND an unblocked
## report; delete only requires an unblocked report (spec.md "A reference
## cannot be rewritten safely" blocks BOTH operations identically).
func _compute_and_show_usage_report(identifier: String) -> void:
	var kinds := GAReferenceRegistry.reference_kinds_for_definition_kind(_lifecycle_kind)
	var report := GAUsageScanner.usage_report(_catalog, kinds, identifier, _project_resource_paths())
	_lifecycle_usage_report = report

	var supported: Array = report["supported"]
	var unsupported: Array = report["unsupported"]
	var lines := PackedStringArray()
	lines.append("%d rewritable reference(s) found." % supported.size())
	for location in supported:
		lines.append(" - %s: %s" % [String(location.get("resource_path", "")), String(location.get("path", ""))])
	if not unsupported.is_empty():
		lines.append("%d reference(s) CANNOT be rewritten safely -- operation blocked:" % unsupported.size())
		for location in unsupported:
			lines.append(" - %s: %s" % [String(location.get("resource_path", "")), String(location.get("path", ""))])
	_rename_usage_label.text = "\n".join(lines)

	if _lifecycle_mode == "rename":
		_on_rename_identifier_changed(_rename_identifier_edit.text)
	else:
		_rename_dialog.get_ok_button().disabled = bool(report.get("blocked", false))


func _on_rename_identifier_changed(_new_text: String) -> void:
	if _lifecycle_mode != "rename":
		return
	var new_identifier := _rename_identifier_edit.text.strip_edges()
	var error := check_identifier(new_identifier)
	if error.is_empty() and new_identifier != _lifecycle_target_identifier and _catalog != null:
		var existing := GAReferenceRegistry.identifiers_in_catalog(_catalog, GAReferenceRegistry.KIND_TAG)
		if existing.has(new_identifier):
			error = "A tag with this identifier already exists in the selected catalog."
	_rename_error_label.text = error
	var blocked := bool(_lifecycle_usage_report.get("blocked", false))
	_rename_dialog.get_ok_button().disabled = not error.is_empty() or blocked


func _find_catalog_tag(identifier: String) -> GameplayTagDefinition:
	if _catalog == null:
		return null
	for entry in _catalog.get_tag_definitions():
		if entry != null and String(entry.get_identifier()) == identifier:
			return entry
	return null


## Applies the confirmed rename/delete as ONE undoable transaction (spec.md
## "A rename or delete MUST either update every supported reference in one
## undoable editor transaction or remain blocked"): every rewritten/cleared
## reference from [member _lifecycle_usage_report]'s `supported` locations,
## PLUS the definition's own identifier change (rename) or removal from the
## catalog array (delete), share one [method EditorUndoRedoManager.commit_action]
## call, so undo restores the complete prior serialized state in one step.
func _on_rename_dialog_confirmed() -> void:
	if _catalog == null:
		return
	var supported: Array = _lifecycle_usage_report.get("supported", [])
	var undo_redo := _get_undo_redo()

	if _lifecycle_mode == "rename":
		var new_identifier := _rename_identifier_edit.text.strip_edges()
		if not check_identifier(new_identifier).is_empty():
			return # Defensive only -- the OK button is disabled while invalid.
		var definition := _find_catalog_tag(_lifecycle_target_identifier)
		if definition == null:
			return
		var edits := GARewritePlanner.plan_rename(supported, new_identifier)
		edits.append({
			"resource": definition, "property": "identifier",
			"old_value": definition.get_identifier(), "new_value": StringName(new_identifier),
		})
		var action_name := "Rename Gameplay Tag '%s' to '%s'" % [_lifecycle_target_identifier, new_identifier]
		if undo_redo == null:
			for edit in edits:
				edit["resource"].set(edit["property"], edit["new_value"])
		else:
			GARewritePlanner.apply_with_undo_redo(undo_redo, action_name, edits)
	else: # "delete"
		var edits := GARewritePlanner.plan_clear(supported)
		var old_array: Array = _catalog.get_tag_definitions()
		var new_array: Array = []
		for entry in old_array:
			if entry == null or String(entry.get_identifier()) != _lifecycle_target_identifier:
				new_array.append(entry)
		edits.append({
			"resource": _catalog, "property": "tag_definitions", "old_value": old_array, "new_value": new_array,
		})
		var action_name := "Delete Gameplay Tag '%s'" % _lifecycle_target_identifier
		if undo_redo == null:
			for edit in edits:
				edit["resource"].set(edit["property"], edit["new_value"])
		else:
			GARewritePlanner.apply_with_undo_redo(undo_redo, action_name, edits)

	_refresh_catalog_tab()


# =============================================================================
# Migration tab (tasks.md 2.6) -- explicit preview/accept only; NEVER
# triggered implicitly on load (design.md "Migration": "migration is never
# performed silently on load").
# =============================================================================

func _on_migration_scan_pressed() -> void:
	_migration_sources.clear()
	_migration_preview_list.clear()
	_migration_preview_result = {}
	_migration_accept_button.disabled = true

	if not Engine.is_editor_hint():
		_migration_status_label.text = "Migration scan requires the running editor."
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_migration_status_label.text = "No scene is currently open in the editor."
		return

	_collect_migration_sources(scene_root)
	if _catalog == null:
		_migration_status_label.text = "Select or create a catalog before migrating."
		return

	_migration_preview_result = GAMigrationPlanner.preview(_migration_sources, _catalog)
	_populate_migration_preview()


## Recursively collects every [GameplayAbilityComponent] under [param node]
## with at least one populated legacy definition array into
## [member _migration_sources], in the plain Dictionary shape
## [GAMigrationPlanner] consumes (see that class's own header comment).
func _collect_migration_sources(node: Node) -> void:
	if node is GameplayAbilityComponent:
		var component: GameplayAbilityComponent = node
		var tag_defs: Array = component.get_tag_definitions()
		var attribute_defs: Array = component.get_attribute_definitions()
		var effect_defs: Array = component.get_effect_definitions()
		var cue_defs: Array = component.get_cue_definitions()
		var schema_defs: Array = component.get_target_data_schemas()
		var ability_defs: Array = component.get_ability_definitions()
		var has_content := (
			not tag_defs.is_empty() or not attribute_defs.is_empty() or not effect_defs.is_empty()
			or not cue_defs.is_empty() or not schema_defs.is_empty() or not ability_defs.is_empty()
		)
		if has_content:
			_migration_sources.append({
				"label": String(node.get_path()),
				"component": component,
				"tag_definitions": tag_defs,
				"attribute_definitions": attribute_defs,
				"effect_definitions": effect_defs,
				"cue_definitions": cue_defs,
				"target_data_schemas": schema_defs,
				"has_legacy_abilities": not ability_defs.is_empty(),
			})
	for child in node.get_children():
		_collect_migration_sources(child)


func _populate_migration_preview() -> void:
	_migration_preview_list.clear()
	var per_kind: Dictionary = _migration_preview_result.get("per_kind", {})
	for kind in GAMigrationPlanner.KIND_ORDER:
		var info: Dictionary = per_kind.get(kind, {})
		var unique: Array = info.get("unique", [])
		var duplicates: Array = info.get("duplicates", [])
		var collisions: Array = info.get("collisions", [])
		_migration_preview_list.add_item("%s: %d unique, %d duplicate group(s), %d collision(s)" % [
			String(kind).capitalize(), unique.size(), duplicates.size(), collisions.size(),
		])

	var unmigratable: PackedStringArray = _migration_preview_result.get(
		"unmigratable_ability_sources", PackedStringArray())
	for source_label in unmigratable:
		_migration_preview_list.add_item(
			"NOT migrated (legacy ability_definitions has no Resource form to copy): %s" % source_label)

	var has_change := bool(_migration_preview_result.get("has_any_change", false))
	_migration_accept_button.disabled = not has_change
	_migration_status_label.text = (
		"Preview ready. %d source(s) scanned." % _migration_sources.size() if has_change
		else "Preview ready -- nothing new to migrate."
	)


func _on_migration_accept_pressed() -> void:
	if _catalog == null or _migration_preview_result.is_empty():
		return
	var edits := GAMigrationPlanner.plan_apply(_migration_preview_result, _catalog, _migration_sources)
	if edits.is_empty():
		return

	var undo_redo := _get_undo_redo()
	if undo_redo == null:
		for edit in edits:
			edit["resource"].set(edit["property"], edit["new_value"])
	else:
		GARewritePlanner.apply_with_undo_redo(undo_redo, "Migrate Legacy Gameplay Definitions Into Catalog", edits)

	_migration_status_label.text = "Migration applied."
	_migration_accept_button.disabled = true
	_refresh_catalog_tab()


# =============================================================================
# EditorInterface-dependent helpers (only ever invoked from signal handlers,
# and each still guards Engine.is_editor_hint() defensively).
# =============================================================================

func _open_resource(path: String) -> void:
	if not Engine.is_editor_hint():
		return
	if not ResourceLoader.exists(path):
		return
	var resource := ResourceLoader.load(path)
	if resource != null:
		EditorInterface.edit_resource(resource)


func _on_browse_pressed() -> void:
	_open_directory_picker(_dir_edit.text, func(dir: String) -> void:
		_dir_edit.text = dir
		_scan())


func _on_new_folder_browse_pressed() -> void:
	_open_directory_picker(_new_folder_edit.text, func(dir: String) -> void:
		_new_folder_edit.text = dir)


func _open_directory_picker(start_dir: String, callback: Callable) -> void:
	if not Engine.is_editor_hint():
		return
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	if not start_dir.is_empty():
		dialog.current_dir = start_dir
	dialog.dir_selected.connect(callback)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio()


func _persist_directory(directory: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings != null:
		settings.set_project_metadata(SETTINGS_SECTION, SETTINGS_KEY_DIRECTORY, directory)


func _restore_directory() -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return
	var directory: String = settings.get_project_metadata(
		SETTINGS_SECTION, SETTINGS_KEY_DIRECTORY, DEFAULT_DIRECTORY)
	_dir_edit.text = directory
