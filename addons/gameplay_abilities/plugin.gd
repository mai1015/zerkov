@tool
extends EditorPlugin

## Editor entry point for the GameplayAbilities addon.
##
## Unlike CommonUI, this addon installs no autoload: gameplay ability state
## belongs to whichever GameplayAbilityComponent nodes a game scene creates,
## so there is no process-global singleton to own it. A single shared
## "gameplay" object would also make dedicated-server and multi-instance
## testing (two clients + one server in one process) impossible, which the
## platform-support spec requires. This plugin registers editor-time tooling
## only (validation, diagnostics, and now the "Gameplay Abilities" dashboard
## dock below) -- it never calls add_autoload_singleton().

const REQUIRED_CLASSES: PackedStringArray = [
	"GameplayAbilityVersion",
]

## The dock's own name (distinct from _get_plugin_name(), which the editor
## uses to label the plugin itself in Project Settings > Plugins).
const DASHBOARD_TITLE := "Gameplay Abilities"

## GameplayAbilitiesDashboard (editor/ga_dashboard.gd) declares its own
## `class_name`, so it is usable here without a preload -- exactly like
## GameplayDefinitionValidation elsewhere in this addon.
var _dashboard: Control

## Shared "which catalog is currently selected" holder (design.md decision 2)
## -- the dashboard's Catalog tab updates it, [GAReferenceInspectorPlugin]'s
## pickers read it, so every Inspector picker anywhere reflects the
## dashboard's current selection. See GAActiveCatalogContext's own header
## comment (editor/ga_active_catalog_context.gd).
var _catalog_context: GAActiveCatalogContext

## Registers the searchable catalog-backed Inspector reference pickers
## (tasks.md 2.2/2.3) via GAReferenceRegistry's explicit table -- see
## editor/ga_reference_inspector_plugin.gd.
var _reference_inspector_plugin: EditorInspectorPlugin


func _enter_tree() -> void:
	for class_name_to_check in REQUIRED_CLASSES:
		if not ClassDB.class_exists(class_name_to_check):
			push_warning(
				"GameplayAbilities: native class '%s' is not registered. Build the addon's "
				% class_name_to_check
				+ "GDExtension for this platform (see addons/gameplay_abilities/release_manifest.json)."
			)

	_catalog_context = GAActiveCatalogContext.new()

	# Registered unconditionally: GameplayAbilitiesDashboard itself shows a
	# single warning label in place of its full UI when the native extension
	# above is missing (see that script's _build_degraded_ui()), rather than
	# this plugin skipping registration altogether.
	_dashboard = GameplayAbilitiesDashboard.new()
	_dashboard.catalog_context = _catalog_context
	add_control_to_bottom_panel(_dashboard, DASHBOARD_TITLE)

	_reference_inspector_plugin = GAReferenceInspectorPlugin.new(_catalog_context)
	add_inspector_plugin(_reference_inspector_plugin)


func _exit_tree() -> void:
	if _dashboard != null:
		remove_control_from_bottom_panel(_dashboard)
		_dashboard.queue_free()
		_dashboard = null
	if _reference_inspector_plugin != null:
		remove_inspector_plugin(_reference_inspector_plugin)
		_reference_inspector_plugin = null
	_catalog_context = null


func _get_plugin_name() -> String:
	return "GameplayAbilities"
