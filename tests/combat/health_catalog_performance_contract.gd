extends SceneTree
## Real-native differential acceptance for expected-metadata/lookup optimization.
## The pre-change implementation is frozen in health_catalog_reference.gd.
const Reference = preload("res://tests/combat/health_catalog_reference.gd")
var checks: int = 0
var failures: int = 0
var _next_entity: int = 95_000
# Dynamic only so the unchanged baseline can import this candidate-only test.
# The runner executes it against the candidate, never against the old API.
var _content = load("res://game/combat/content/zerkov_health_ability_content.gd")

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("HEALTH_CATALOG_PERFORMANCE: " + label)

func run() -> void:
	print("HEALTH_CATALOG_CONTEXT ", JSON.stringify({"engine":Engine.get_version_info(),
		"debug_build":OS.is_debug_build(), "cpu":OS.get_processor_name(),
		"logical_processors":OS.get_processor_count(), "display":DisplayServer.get_name()}))
	_metadata_contract()
	_index_contract()
	_compiled_runtime_isolation_contract()
	for combined: bool in [false, true]:
		var catalog := _catalog(combined)
		var component := _component(catalog)
		_same(component, "fresh catalog", true)
		_same(component, "warm metadata", true)
		for category: StringName in [&"tag", &"attribute", &"effect", &"ability"]:
			var definitions: Array = catalog.call("get_%s_definitions" % category)
			var original: Array = definitions.duplicate()
			definitions.reverse()
			catalog.set("%s_definitions" % category, definitions)
			_same(component, "reordered " + String(category), true)
			definitions.append(definitions[0])
			definitions.append(definitions[0])
			catalog.set("%s_definitions" % category, definitions)
			_same(component, "triple duplicate after warm " + String(category), false,
				&"health_catalog_changed_after_configure")
			catalog.set("%s_definitions" % category, original)
			_same(component, "restored " + String(category), true)
		# Mutate a nested magnitude through the retained authoring alias. No top-
		# level Resource.changed signal is required for this to be detected.
		var effect := Reference._find_definition(catalog.get_effect_definitions(),
			ZerkovHealthAbilityContent.EFFECT_LIFE_ALIVE) as GameplayEffectDefinition
		var modifier := effect.modifiers[0] as GameplayModifierDeclaration
		var magnitude := modifier.magnitude
		var coefficient: float = magnitude.coefficient
		magnitude.coefficient = coefficient + 1.0
		_same(component, "nested magnitude after warm", false,
			&"health_catalog_changed_after_configure")
		magnitude.coefficient = coefficient
		_same(component, "nested magnitude restored", true)
		var original_modifiers: Array[GameplayModifierDeclaration] = effect.modifiers
		var changed_modifiers: Array[GameplayModifierDeclaration] = original_modifiers.duplicate()
		changed_modifiers.append(modifier)
		effect.modifiers = changed_modifiers
		_same(component, "nested modifier array after warm", false,
			&"health_catalog_changed_after_configure")
		effect.modifiers = original_modifiers
		_same(component, "modifier array restored", true)
		# Non-semantic metadata is not silently redefined as catalog semantics.
		effect.set_meta(&"health_catalog_probe", [1, 2, 3])
		_same(component, "non-semantic metadata matches reference", true)
		effect.remove_meta(&"health_catalog_probe")
		_free(component)

	# A coherent-but-different catalog must not pass merely because native
	# configure() sealed it successfully. Preserve exact rejection precedence.
	var altered := _catalog(false)
	altered.get_attribute_definitions()[0].max_value -= 1.0
	var component := _component(altered)
	_same(component, "different canonical semantics before configure", false,
		&"health_catalog_semantics_mismatch")
	_free(component)
	var missing := _catalog(false)
	var abilities: Array[GameplayAbilityDefinition] = missing.get_ability_definitions()
	abilities.pop_back()
	missing.ability_definitions = abilities
	component = _component(missing)
	_same(component, "missing health ability before configure", false,
		&"health_ability_definition_missing")
	_free(component)

	component = _component(_catalog(true))
	_paired_measurement(component)
	_free(component)
	await process_frame
	await process_frame
	print("HEALTH_CATALOG_PERFORMANCE_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

func _metadata_contract() -> void:
	var metadata: Dictionary = _content._expected_catalog_metadata
	check(metadata.is_read_only() and bool(metadata.get("ok", false)), "expected metadata is read-only and valid")
	check(_immutable_values_only(metadata), "metadata has no Resource, Callable or mutable nested container")
	var current: Dictionary = _content._build_expected_catalog_metadata()
	check(metadata == current, "retained metadata equals freshly built native expected manifest")
	_content._expected_catalog_metadata = {"ok": false}
	check(_content._expected_catalog_metadata == current,
		"write-once metadata cannot be replaced")
	var authoring := ZerkovHealthAbilityContent.build_definition_catalog()
	authoring.get_attribute_definitions()[0].max_value -= 1.0
	check(_content._expected_catalog_metadata == current,
		"independent authoring resources cannot mutate expected metadata")

func _immutable_values_only(value: Variant) -> bool:
	match typeof(value):
		TYPE_DICTIONARY:
			if not value.is_read_only(): return false
			for key in value:
				if not _immutable_values_only(key) or not _immutable_values_only(value[key]): return false
		TYPE_ARRAY:
			if not value.is_read_only(): return false
			for child in value:
				if not _immutable_values_only(child): return false
		TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME:
			return true
		_:
			return false
	return true

func _index_contract() -> void:
	var catalog := _catalog(false)
	for category: StringName in [&"tag", &"attribute", &"effect", &"ability"]:
		var definitions: Array = catalog.call("get_%s_definitions" % category)
		for repeats: int in [0, 1, 2, 3]:
			var values: Array = []
			values.append_array(definitions)
			for _i in range(repeats): values.append(definitions[0])
			values.append(null)
			values.append(Resource.new()) # No get_identifier(): ignored by both.
			var index: Dictionary = _content._index_definitions(values)
			for definition: Resource in definitions:
				var id := StringName(definition.call("get_identifier"))
				check(index.get(id) == Reference._find_definition(values, id),
					"duplicate-aware index matches linear lookup " + String(category))
			check(index.get(&"absent") == null, "absent index lookup stays missing")

func _compiled_runtime_isolation_contract() -> void:
	var catalog := _catalog(false)
	var component := _component(catalog)
	var initialized := ZerkovHealthAbilityContent.initialize_component(component, 0)
	check(bool(initialized.get("accepted", false)),
		"compiled-runtime fixture initializes native health state")
	var granted := component.grant_ability(
		String(ZerkovHealthAbilityContent.ABILITY_STAMINA_SPEND), 1,
		"zerkov.test.catalog_runtime_isolation", 0)
	var spec := int(granted.get("spec", 0))
	check(bool((granted.get("status", {}) as Dictionary).get("ok", false))
		and not bool(granted.get("queued", false)) and spec > 0,
		"compiled-runtime fixture grants stamina spend")

	var effect := Reference._find_definition(catalog.get_effect_definitions(),
		ZerkovHealthAbilityContent.EFFECT_STAMINA_SPEND) as GameplayEffectDefinition
	var modifier := effect.modifiers[0] as GameplayModifierDeclaration
	var magnitude := modifier.magnitude
	var authored_coefficient: float = magnitude.coefficient
	var before := _micros(component.get_attribute_current(
		String(ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)))
	# Mutate the retained authoring Resource after configure. The active native
	# descriptor must stay sealed even though live catalog validation correctly
	# reports that the authoring graph no longer matches its manifest.
	magnitude.coefficient = authored_coefficient * 2.0
	var validation := ZerkovHealthAbilityContent._validate_catalog_subset(component)
	check(not bool(validation.get("ok", true))
		and validation.get("reason", &"") == &"health_catalog_changed_after_configure",
		"post-configure authoring mutation is visible to diagnostic validation")
	var activation := component.request_activation({
		"spec": spec,
		"command_sequence": 1,
		"set_by_caller": [{
			"field": String(ZerkovHealthAbilityContent.SET_BY_CALLER_AMOUNT),
			"value": 1.0,
		}],
	}, 0)
	var after := _micros(component.get_attribute_current(
		String(ZerkovHealthAbilityContent.ATTRIBUTE_STAMINA)))
	check(bool((activation.get("status", {}) as Dictionary).get("ok", false))
		and not bool(activation.get("queued", false))
		and after == before - 1_000_000,
		"sealed native descriptor ignores later authoring magnitude mutation")
	magnitude.coefficient = authored_coefficient
	check(bool(ZerkovHealthAbilityContent._validate_catalog_subset(component).get(
		"ok", false)), "restored authoring graph matches the active manifest")
	_free(component)


func _micros(value: float) -> int:
	return roundi(value * float(ZerkovHealthAbilityContent.FIXED_SCALE))


func _catalog(combined: bool) -> GameplayDefinitionCatalog:
	return ZerkovGameplayAbilityContent.build_definition_catalog() if combined \
		else ZerkovHealthAbilityContent.build_definition_catalog()

func _component(catalog: GameplayDefinitionCatalog) -> GameplayAbilityComponent:
	_next_entity += 1
	var component := GameplayAbilityComponent.new()
	component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	component.entity_id = _next_entity
	component.tick_rate = 60
	component.definition_catalog = catalog
	root.add_child(component)
	var findings: Array = component.configure()
	check(GameplayDefinitionValidator.is_ok(findings) and component.is_configured(),
		"fixture configures with shipped native component")
	return component

func _same(component: GameplayAbilityComponent, label: String, expected: bool,
	reason: StringName = &"") -> void:
	var before := component.write_snapshot()
	var reference: Dictionary = Reference.validate(component)
	var actual: Dictionary = ZerkovHealthAbilityContent._validate_catalog_subset(component)
	check(actual == reference, "exact reference result: " + label)
	check(bool(actual.get("ok", false)) == expected, "expected acceptance: " + label)
	if not reason.is_empty(): check(actual.get("reason", &"") == reason, "exact reason: " + label)
	check(component.write_snapshot() == before, "side-effect-free: " + label)

func _paired_measurement(component: GameplayAbilityComponent) -> void:
	for _i in range(4):
		Reference.validate(component)
		ZerkovHealthAbilityContent._validate_catalog_subset(component)
	var expected := Reference.validate(component)
	for mode: String in ["reference", "candidate", "candidate", "reference"]:
		var samples: Array[int] = []
		for _i in range(32):
			var start := Time.get_ticks_usec()
			var result: Dictionary = Reference.validate(component) if mode == "reference" \
				else ZerkovHealthAbilityContent._validate_catalog_subset(component)
			samples.append(Time.get_ticks_usec() - start)
			check(result == expected, "paired preflight result equality")
		samples.sort()
		var total: int = 0
		for sample in samples: total += sample
		print("HEALTH_CATALOG_TIMING ", JSON.stringify({"mode":mode, "count":samples.size(),
			"mean_us":float(total) / samples.size(), "p50_us":samples[15],
			"p95_us":samples[30], "p99_us":samples[31], "max_us":samples[-1]}))

func _free(component: GameplayAbilityComponent) -> void:
	component.queue_teardown(component.get_current_tick())
	component.free()
