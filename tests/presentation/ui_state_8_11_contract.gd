extends SceneTree
## Task 8.11 domain/static contract. It does not create a viewport or render UI.
## Run with: godot --headless --path . --script res://tests/presentation/ui_state_8_11_contract.gd

const FIXTURE_PROVIDER_PATH := "res://ui/dev/fixture_provider.gd"
const FIXTURE_DIRECTORY := "res://ui/dev/fixtures/"

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("UI_STATE_8_11_CONTRACT: " + message)


func run() -> void:
	_test_fixture_provider_lifecycle()
	_test_fixture_context_lease()
	_test_typed_presentation_provider()
	_test_production_source_surface()
	print("UI_STATE_8_11_CONTRACT_RESULT checks=", checks,
		" failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_fixture_provider_lifecycle() -> void:
	var provider := ZUIFixtureProvider.new()
	check(provider.start(1), "explicit fixture provider starts at generation one")
	check(provider.prepare_route("main_menu", 1),
		"explicit fixture provider prepares front-flow data")
	check(provider.prepare_route("inventory", 1),
		"explicit fixture provider prepares Character preview data")
	var first_value: Variant = provider.state(1)
	check(first_value is Dictionary, "current fixture generation exposes a document")
	var retired := first_value as Dictionary
	check((retired.get("frontflow_worlds", []) as Array).size() == 3
			and retired.get("inventory_data", null) is Dictionary,
		"fixture samples exist only after explicit provider preparation")
	retired["retired_marker"] = 1

	check(provider.replace(1, 2), "fixture replacement advances generation")
	check(provider.state(1) == null
			and provider.last_error == &"fixture_provider_stale_generation",
		"retired fixture generation is rejected")
	var second_value: Variant = provider.state(2)
	check(second_value is Dictionary and (second_value as Dictionary).is_empty(),
		"replacement installs a fresh empty fixture document")
	retired["retired_marker"] = 2
	check(not (second_value as Dictionary).has("retired_marker"),
		"retained dictionary cannot mutate the replacement document")
	check(not provider.teardown(1) and provider.is_active(),
		"wrong-generation fixture teardown fails atomically")
	check(provider.teardown(2) and not provider.is_active(),
		"matching fixture teardown releases the provider")
	check(provider.state(2) == null
			and provider.last_error == &"fixture_provider_released",
		"released fixture document is inaccessible")
	check(not provider.start(2),
		"released provider cannot reuse a retired generation")
	check(provider.start(3),
		"released provider may begin only at a newer generation")
	check(provider.state(2) == null
			and provider.last_error == &"fixture_provider_stale_generation",
		"restart cannot revive a stale fixture lease")
	check(provider.teardown(3), "newer fixture session tears down cleanly")


func _test_fixture_context_lease() -> void:
	var host := Node.new()
	root.add_child(host)
	var provider := ZUIFixtureProvider.new()
	check(provider.start(5), "context fixture provider starts")
	var stale := ZUIContext.new(host, "main_menu", provider)
	check(stale.prepare_fixture_route() and stale.has_fixture_provider(),
		"context captures its explicit provider generation")
	check(provider.replace(5, 6), "context provider replacement succeeds")
	check(not stale.has_fixture_provider() and stale.fixture_state().is_empty()
			and not stale.fixture_set("forged", true),
		"stale context can neither read nor write the replacement fixture")
	var current := ZUIContext.new(host, "main_menu", provider)
	check(current.fixture_generation() == 6 and current.prepare_fixture_route()
			and current.fixture_has("frontflow_worlds"),
		"fresh context captures only the replacement generation")
	check(provider.teardown(6), "context fixture provider releases")
	check(not current.has_fixture_provider() and current.fixture_state().is_empty(),
		"teardown invalidates the current fixture context")
	host.free()


func _test_typed_presentation_provider() -> void:
	var provider := ZUIPresentationProvider.new()
	provider.name = "UIState811Provider"
	root.add_child(provider)
	var publications: Array[int] = []
	var invalidations: Array[StringName] = []
	provider.published.connect(func(generation: int) -> void:
		publications.append(generation))
	provider.invalidated.connect(func(_generation: int, reason: StringName) -> void:
		invalidations.append(reason))
	check(provider.start_unavailable(7, &"test_services_missing"),
		"typed production provider starts with unavailable truth")
	check(provider.bunker_view(7) is BunkerView
			and provider.raid_view(7) is RaidView
			and provider.task_view(7) is TaskView
			and provider.map_view(7) is MapView
			and provider.summary_view(7) is SummaryView,
		"every missing production service publishes its declared view type")
	check(provider.bunker_view(7).diagnostic() == &"test_services_missing_bunker"
			and not provider.bunker_view(7).is_ready(),
		"missing service truth is coherent and never ready sample data")

	var first := _unavailable_views(7, 1, 10, "first")
	check(provider.publish_views(7, first.bunker, first.raid, first.tasks,
		first.map, first.summary),
		"same-generation immutable publication advances revision and tick")
	check(provider.publish_views(7, first.bunker, first.raid, first.tasks,
		first.map, first.summary),
		"exact immutable replay is accepted")
	var divergent := _unavailable_views(7, 1, 10, "divergent")
	check(not provider.publish_views(7, divergent.bunker, divergent.raid,
		divergent.tasks, divergent.map, divergent.summary)
			and provider.last_error \
				== &"ui_presentation_provider_version_divergent"
			and provider.bunker_view(7) == first.bunker,
		"equal-version divergent publication cannot replace truth")
	var regressed := _unavailable_views(7, 0, 11, "regressed")
	check(not provider.publish_views(7, regressed.bunker, regressed.raid,
		regressed.tasks, regressed.map, regressed.summary)
			and provider.last_error \
				== &"ui_presentation_provider_version_regressed",
		"revision regression is rejected atomically")

	var host := Node.new()
	root.add_child(host)
	var stale_context := ZUIContext.new(
		host, "tasks", null, false, null, null, provider)
	var invalid_replacement := _unavailable_views(7, 2, 11, "wrong_generation")
	check(not provider.replace_views(8,
		invalid_replacement.bunker, invalid_replacement.raid,
		invalid_replacement.tasks, invalid_replacement.map,
		invalid_replacement.summary) and provider.generation() == 7,
		"replacement rejects views from the wrong generation without mutation")
	check(provider.replace_unavailable(8, &"replacement_services_missing"),
		"authority replacement advances the typed provider generation")
	check(stale_context.presentation_diagnostic()
			== &"ui_presentation_provider_stale_generation"
			and stale_context.task_view().diagnostic()
				== &"ui_presentation_provider_stale_generation",
		"retained screen context observes explicit stale-generation truth")
	var current_context := ZUIContext.new(
		host, "tasks", null, false, null, null, provider)
	check(current_context.presentation_generation() == 8
			and current_context.task_view().diagnostic()
				== &"replacement_services_missing_tasks",
		"replacement context observes only the current typed view")
	check(not provider.teardown(7) and provider.is_active(),
		"wrong-generation presentation teardown fails atomically")
	check(provider.teardown(8) and not provider.is_active()
			and invalidations == [&"ui_presentation_provider_released"],
		"matching presentation teardown emits one invalidation")
	check(current_context.task_view().diagnostic()
			== &"ui_presentation_provider_released",
		"teardown leaves a typed released view rather than stale sample data")
	check(publications == [7, 7, 7, 8],
		"provider publication sequence is deterministic")
	host.free()
	provider.free()


func _unavailable_views(
	generation: int,
	revision: int,
	source_tick: int,
	prefix: String
) -> Dictionary:
	return {
		"bunker": BunkerView.unavailable(
			ZReadOnlyView.SyncState.UNBOUND, StringName(prefix + "_bunker"),
			generation, revision, source_tick),
		"raid": RaidView.unavailable(
			ZReadOnlyView.SyncState.UNBOUND, StringName(prefix + "_raid"),
			generation, revision, source_tick),
		"tasks": TaskView.unavailable(
			ZReadOnlyView.SyncState.UNBOUND, StringName(prefix + "_tasks"),
			generation, revision, source_tick),
		"map": MapView.unavailable(
			ZReadOnlyView.SyncState.UNBOUND, StringName(prefix + "_map"),
			generation, revision, source_tick),
		"summary": SummaryView.unavailable(
			ZReadOnlyView.SyncState.UNBOUND, StringName(prefix + "_summary"),
			generation, revision, source_tick),
	}


func _test_production_source_surface() -> void:
	var legacy_member := "app." + "state"
	var reflective_legacy := ".get(\"" + "state" + "\")"
	var direct_fixture_imports: Array[String] = []
	var legacy_references: Array[String] = []
	var fixture_store_escapes: Array[String] = []
	var files: Array[String] = []
	_collect_gd_files("res://ui", files)
	_collect_gd_files("res://game", files)
	for path in files:
		var source := FileAccess.get_file_as_string(path)
		if source.contains(legacy_member) or source.contains(reflective_legacy):
			legacy_references.append(path)
		if source.contains(FIXTURE_DIRECTORY) and path != FIXTURE_PROVIDER_PATH:
			direct_fixture_imports.append(path)
		if source.contains("ZUIFixtureStore") \
				and not path.begins_with("res://ui/dev/"):
			fixture_store_escapes.append(path)
	check(not files.is_empty(), "production source audit enumerates UI and game scripts")
	check(legacy_references.is_empty(),
		"production source contains zero legacy app-state reads or writes: " \
			+ str(legacy_references))
	check(direct_fixture_imports.is_empty(),
		"only the explicit developer provider imports sample fixtures: " \
			+ str(direct_fixture_imports))
	check(fixture_store_escapes.is_empty(),
		"mutable fixture store does not escape ui/dev: " + str(fixture_store_escapes))

	var main_script := load("res://ui/main.gd") as Script
	var context_script := load("res://ui/core/ui_context.gd") as Script
	check(not _script_has_property(main_script, &"state")
			and not _script_has_property(main_script, &"fixtures"),
		"production app exposes no legacy mutable state property")
	check(not _script_has_property(context_script, &"state")
			and not _script_has_property(context_script, &"fixtures"),
		"screen context exposes no legacy mutable state property")
	var main_source := main_script.source_code
	var screen_source := FileAccess.get_file_as_string("res://ui/core/screen.gd")
	check(not main_source.contains("ZUIFixtureStore.new"),
		"production app never constructs the mutable fixture store directly")
	check(main_source.contains("if qa_mode or review_start:")
			and main_source.contains("get_window().size = DESKTOP_CANVAS"),
		"built-in smoke and review runners are statically pinned to exact 1920x1080")
	check(main_source.contains("inject_character_runtime")
			and main_source.contains("character_runtime_for_route"),
		"accepted Task 8.6 Character composition remains injection-only")
	check(screen_source.contains("PRODUCTION_SELF_MANAGED_ROUTES")
			and screen_source.contains("_should_render_locked_state")
			and screen_source.contains("PRODUCTION DATA UNAVAILABLE"),
		"shared screen permanently gates unbound production builders")


func _script_has_property(script: Script, property_name: StringName) -> bool:
	for property in script.get_script_property_list():
		if StringName(property.get("name", "")) == property_name:
			return true
	return false


func _collect_gd_files(directory_path: String, result: Array[String]) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var path := directory_path.path_join(entry)
		if directory.current_is_dir():
			_collect_gd_files(path, result)
		elif entry.ends_with(".gd"):
			result.append(path)
		entry = directory.get_next()
	directory.list_dir_end()
