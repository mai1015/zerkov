extends SceneTree
## Task 8.6 headless domain/composition contract. Every authority created here
## is test-only; production Character composition is injection-only.
## Run with: godot --headless --path . --script res://tests/presentation/character_presentation_composition_contract.gd

const MAX_TRANSFER_DISTANCE_RAW := 2_000_000

var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("CHARACTER_PRESENTATION_COMPOSITION: " + message)


func settle(frames: int = 3) -> void:
	for _index in range(frames):
		await process_frame


func run() -> void:
	var unavailable := CharacterPresentationComposition.new()
	unavailable.name = "UnavailableCharacterComposition"
	root.add_child(unavailable)
	check(unavailable.start() and unavailable.is_started(),
		"composition starts without manufacturing missing product authority")
	var unavailable_runtime := unavailable.character_runtime()
	check(unavailable_runtime != null and not unavailable_runtime.is_configured()
		and unavailable_runtime.inventory_view(&"profile").diagnostic()
			== CharacterPresentationComposition.REASON_AUTHORITY_NOT_INJECTED
		and unavailable_runtime.health_view().diagnostic()
			== CharacterPresentationComposition.REASON_AUTHORITY_NOT_INJECTED,
		"uninjected composition publishes matching typed unavailable views")
	check(unavailable.find_children("*", "RaidInventoryOwner", true, false).is_empty(),
		"composition never creates a parallel RaidInventoryOwner")
	var composition_source := String(
		(unavailable.get_script() as Script).source_code)
	check(not composition_source.contains("RaidInventoryOwner.new")
		and not composition_source.contains("SessionCoordinator.new")
		and not composition_source.contains("OfflineInventoryIdentity.new"),
		"production composition source contains no owner/session/identity constructor")
	check(_has_no_authority_escape_surface(unavailable),
		"composition exposes no raw owner, bridge, adapter, admission, or runtime field")
	unavailable.queue_free()
	await settle()

	var fixture := _build_fixture("primary")
	check(bool(fixture.get("ok", false)),
		"test-only external authority dependencies configure")
	if not bool(fixture.get("ok", false)):
		_finish()
		return
	var composition := CharacterPresentationComposition.new()
	composition.name = "InjectedCharacterComposition"
	root.add_child(composition)
	check(composition.start(
		fixture.owner, fixture.bridge, fixture.adapter,
		fixture.admission, fixture.health),
		"composition binds only the externally supplied dependency set")
	var runtime := composition.character_runtime()
	check(runtime != null and runtime.is_configured()
		and runtime.inventory_view(&"profile").is_ready()
		and runtime.health_view().is_ready(),
		"injected dependencies project ready immutable views")
	var high_watermark := _health_view(
		fixture.admission as ZSessionAdmission, 5, 500, 90)
	check(runtime.publish_health_view(high_watermark)
		and runtime.health_view().revision() == 5
		and runtime.health_view().source_tick() == 500,
		"ready health establishes the same-lineage revision and tick watermark")

	var invalidations: Array[StringName] = []
	var health_updates: Array[HealthView] = []
	runtime.binding_invalidated.connect(func(reason: StringName) -> void:
		invalidations.append(reason))
	runtime.health_view_changed.connect(func(view: HealthView) -> void:
		health_updates.append(view))
	check(not composition.rebind(
		null, fixture.bridge, fixture.adapter, fixture.admission, fixture.health),
		"partial dependency replacement fails closed")
	check(not runtime.is_configured()
		and runtime.last_error == &"character_runtime_dependency_missing"
		and runtime.inventory_view(&"profile").diagnostic() == runtime.last_error
		and runtime.health_view().diagnostic() == runtime.last_error
		and invalidations == [&"character_runtime_dependency_missing"]
		and not health_updates.is_empty()
		and health_updates.back().diagnostic() == runtime.last_error,
		"failed reconfigure atomically publishes one matching unavailable state")
	check((fixture.owner as RaidInventoryOwner).lifecycle
			== RaidInventoryOwner.Lifecycle.ACTIVE
		and (fixture.bridge as InventoryProjectionBridge).is_bound()
		and (fixture.adapter as InventoryIntentAdapter).is_bound(),
		"failed composition rebind cannot dispose externally owned dependencies")

	var regressed_recovery := _health_view(
		fixture.admission as ZSessionAdmission, 6, 499, 89)
	check(not composition.rebind(
		fixture.owner, fixture.bridge, fixture.adapter,
		fixture.admission, regressed_recovery)
		and runtime.last_error == &"health_view_version_regressed"
		and not runtime.is_configured()
		and runtime.health_view().revision() == 5
		and runtime.health_view().source_tick() == 500,
		"failed rebind cannot erase the ready watermark or admit a lower tick")
	var divergent_recovery := _health_view(
		fixture.admission as ZSessionAdmission, 5, 500, 88)
	check(not composition.rebind(
		fixture.owner, fixture.bridge, fixture.adapter,
		fixture.admission, divergent_recovery)
		and runtime.last_error == &"health_view_version_divergent"
		and not runtime.is_configured(),
		"same-version divergent health remains rejected after unavailable state")
	var valid_recovery := _health_view(
		fixture.admission as ZSessionAdmission, 6, 501, 89)
	check(composition.rebind(
		fixture.owner, fixture.bridge, fixture.adapter,
		fixture.admission, valid_recovery),
		"same-lineage recovery requires monotonic ready health")
	check(composition.character_runtime() == runtime and runtime.is_configured(),
		"rebind preserves presentation runtime identity")
	composition.teardown()
	check(not runtime.is_configured()
		and runtime.last_error == &"character_composition_teardown"
		and runtime.inventory_view(&"raid").diagnostic() == runtime.last_error
		and runtime.health_view().diagnostic() == runtime.last_error,
		"composition teardown publishes coherent disconnected views")
	check((fixture.owner as RaidInventoryOwner).lifecycle
			== RaidInventoryOwner.Lifecycle.ACTIVE
		and (fixture.bridge as InventoryProjectionBridge).is_bound()
		and (fixture.adapter as InventoryIntentAdapter).is_bound(),
		"composition teardown leaves authority lifecycle to the game root")
	var post_teardown_regression := _health_view(
		fixture.admission as ZSessionAdmission, 7, 500, 87)
	check(not composition.start(
		fixture.owner, fixture.bridge, fixture.adapter,
		fixture.admission, post_teardown_regression)
		and runtime.last_error == &"health_view_version_regressed",
		"teardown preserves the last ready watermark for the same authority lineage")

	var replacement := _build_fixture("replacement")
	check(bool(replacement.get("ok", false)),
		"test-only honest replacement authority dependencies configure")
	if bool(replacement.get("ok", false)):
		var replacement_health := _health_view(
			replacement.admission as ZSessionAdmission, 1, 1, 100)
		check(composition.rebind(
			replacement.owner, replacement.bridge, replacement.adapter,
			replacement.admission, replacement_health)
			and runtime.is_configured()
			and runtime.health_view().revision() == 1
			and runtime.health_view().source_tick() == 1,
			"honest authority identity replacement resets the ready-health watermark")
		composition.teardown()
		check((replacement.owner as RaidInventoryOwner).lifecycle
				== RaidInventoryOwner.Lifecycle.ACTIVE
			and (replacement.bridge as InventoryProjectionBridge).is_bound()
			and (replacement.adapter as InventoryIntentAdapter).is_bound(),
			"replacement teardown also preserves external authority ownership")
		_dispose_fixture(replacement)

	composition.queue_free()
	await settle()
	_dispose_fixture(fixture)
	_finish()


func _has_no_authority_escape_surface(composition: CharacterPresentationComposition) -> bool:
	var script := composition.get_script() as Script
	var forbidden_methods := [
		&"owner", &"bridge", &"adapter", &"admission",
	]
	for method in script.get_script_method_list():
		if StringName(method.get("name", "")) in forbidden_methods:
			return false
	var forbidden_properties := [
		&"owner", &"bridge", &"adapter", &"admission", &"runtime",
		&"_owner", &"_bridge", &"_adapter", &"_admission",
	]
	for property in script.get_script_property_list():
		if StringName(property.get("name", "")) in forbidden_properties:
			return false
	return true


func _build_fixture(tag: String) -> Dictionary:
	var owner := RaidInventoryOwner.new()
	owner.name = "CharacterCompositionOwner_" + tag
	root.add_child(owner)
	if not owner.configure():
		return {"ok": false, "owner": owner}
	var admission := SessionCoordinator.new().open_offline(
		ZRaidId.from_parts(PackedStringArray(["test", "character", tag])),
		StringName("test_profile_" + tag), &"player")
	var identity := OfflineInventoryIdentity.new()
	if not identity.configure(admission, owner, RaidInventoryOwner.FIXTURE_ACTOR_ID):
		return {"ok": false, "owner": owner, "identity": identity}
	var adapter := InventoryIntentAdapter.new()
	if not adapter.configure(
		owner, admission, identity, ZInventoryWorldPolicyPort.new(),
		MAX_TRANSFER_DISTANCE_RAW):
		return {"ok": false, "owner": owner, "identity": identity,
			"adapter": adapter}
	var bridge := InventoryProjectionBridge.new()
	bridge.name = "CharacterCompositionBridge_" + tag
	root.add_child(bridge)
	if not bridge.bind_owner(owner, owner.generation()):
		return {"ok": false, "owner": owner, "identity": identity,
			"adapter": adapter, "bridge": bridge}
	var parts: Array[HealthView.BodyPart] = [
		HealthView.BodyPart.create(
			&"thorax", "Thorax", 85, 85, HealthView.BodyPartState.HEALTHY),
	]
	var effects: Array[HealthView.StatusEffect] = []
	var health := HealthView.create(
		admission.generation, 1, 10, admission.actor_id,
		HealthView.LifeState.ALIVE, 100, 100, 100, 100, 100, 100,
		parts, effects)
	return {
		"ok": health != null,
		"owner": owner,
		"identity": identity,
		"adapter": adapter,
		"bridge": bridge,
		"admission": admission,
		"health": health,
	}


func _health_view(
	admission: ZSessionAdmission,
	revision: int,
	source_tick: int,
	stamina: int
) -> HealthView:
	var parts: Array[HealthView.BodyPart] = [
		HealthView.BodyPart.create(
			&"thorax", "Thorax", 85, 85, HealthView.BodyPartState.HEALTHY),
	]
	var effects: Array[HealthView.StatusEffect] = []
	return HealthView.create(
		admission.generation, revision, source_tick, admission.actor_id,
		HealthView.LifeState.ALIVE, stamina, 100, 100, 100, 100, 100,
		parts, effects)


func _dispose_fixture(fixture: Dictionary) -> void:
	var adapter := fixture.get("adapter") as InventoryIntentAdapter
	if adapter != null and adapter.is_bound():
		adapter.release_binding(&"test_fixture_disposed")
	var bridge := fixture.get("bridge") as InventoryProjectionBridge
	if bridge != null and is_instance_valid(bridge):
		bridge.release_binding()
		bridge.queue_free()
	var identity := fixture.get("identity") as OfflineInventoryIdentity
	if identity != null:
		identity.release()
	var owner := fixture.get("owner") as RaidInventoryOwner
	if owner != null and is_instance_valid(owner):
		if owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
			owner.teardown(owner.generation())
		owner.queue_free()


func _finish() -> void:
	print("CHARACTER_PRESENTATION_COMPOSITION_RESULT checks=%d failures=%d" % [
		checks, failures])
	quit(0 if failures == 0 else 1)
