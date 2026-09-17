extends RefCounted
## Genuine shared native component. Equipment may change only its own passive
## state inside its exact registered invocation; health mutations stay guarded.
const HEALTH = preload("res://game/combat/content/zerkov_health_ability_content.gd")
const EQUIPMENT = preload("res://game/content/zerkov_equipment_ability_content.gd")
var _test: SceneTree
var _parent: Node
var _raid: RaidAuthority
var _health: EquipmentHealthConsequenceAdapter
var _owner: RaidInventoryOwner
var _component: GameplayAbilityComponent
var _equipment: InventoryAbilityAdapter
var _actor: ZEntityId
var _poisoned: bool = false
var _last_equipment_event: Dictionary = {}

func run(context: SceneTree) -> void:
	_test = context
	for scenario: String in ["owned", "external_health", "external_equipment", "reentrant_health"]:
		if _setup(scenario):
			_exercise(scenario)
		_cleanup()
	_test = null

func _check(ok: bool, label: String) -> bool:
	return bool(_test.call("check", ok, "equipment/health: " + label))

func _setup(scenario: String) -> bool:
	_poisoned = false
	_last_equipment_event = {}
	_parent = Node.new()
	_test.root.add_child(_parent)
	_owner = RaidInventoryOwner.new()
	_parent.add_child(_owner)
	if not _check(_owner.configure() and LocalCampaignContent.equip_starter(_owner), "native inventory " + scenario): return false
	var id := ZRaidId.from_parts(PackedStringArray(["equipment_health", scenario]))
	var admission := SessionCoordinator.new().open_offline(id, &"equipment_health")
	_actor = admission.actor_id
	_raid = RaidAuthority.new()
	if not _check(_raid.configure(id, admission, 41), "raid identity " + scenario): return false
	_health = EquipmentHealthConsequenceAdapter.new()
	if not _check(_health.bind_authority(_raid, _raid.generation()), "health authority binding"): return false
	_component = GameplayAbilityComponent.new()
	_component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	_component.entity_id = 813005
	_component.tick_rate = RaidClock.TICK_RATE
	_component.definition_catalog = ZerkovGameplayAbilityContent.build_definition_catalog()
	_parent.add_child(_component)
	if not _check(GameplayDefinitionValidator.is_ok(_component.configure())
			and ZerkovGameplayAbilityContent.initialize_component(_component).get("accepted", false), "real compiled combined content"): return false
	if not _check(_health.register_actor(_actor, ZRaidIntent.Source.PLAYER, _component, _component.entity_id).accepted, "registered health actor"): return false
	var identity := OfflineInventoryIdentity.new()
	var port := GameplayAbilityEquipmentPort.new()
	_equipment = InventoryAbilityAdapter.new()
	if not _check(identity.configure(admission, _owner, _component.entity_id) and port.configure(_component)
			and _equipment.bind_owner(_owner, admission, identity, port, _raid, _owner.generation()), "exact equipment executor"): return false
	if not _check(_health.bind_equipment_source(_actor, _equipment), "bind scoped shared-component source"): return false
	_check(not _health.bind_equipment_source(_actor, _equipment), "duplicate binding rejected")
	_component.tag_changed.connect(_remember_equipment_event)
	if scenario == "reentrant_health":
		_component.tag_changed.connect(_inject_health_signal)
	if not _check(_raid.transition(RaidAuthority.Lifecycle.ACTIVE, _raid.generation()), "activate shared authority"): return false
	_check(not _health.bind_equipment_source(_actor, _equipment), "active roster cannot acquire new scopes")
	return true

func _exercise(scenario: String) -> void:
	if not _check(_raid.advance_one(_raid.generation()), "initial equipment grant tick: " + String(_health.last_error)): return
	if scenario == "reentrant_health":
		_check(_poisoned, "native equipment notification invoked hostile subscriber")
		_expect_poison()
		return
	if not _check(_component.has_tag_exact(String(EQUIPMENT.TAG_AKM_EQUIPPED))
			and _component.has_tag_exact(String(EQUIPMENT.TAG_MACHETE_EQUIPPED)), "actual passive effects are active"): return
	if not _check(_raid.advance_one(_raid.generation()), "equipment signals do not poison following health tick: " + String(_health.last_error)): return
	if scenario == "owned":
		var before := _health.actor_snapshot(_actor)
		for _i in range(3):
			if not _check(_raid.advance_one(_raid.generation()), "unchanged equipment remains valid"): return
		var after := _health.actor_snapshot(_actor)
		_check(before == after, "equipment-only signals leave health projection unchanged")
		return
	if scenario == "external_health":
		var stamina_spec: int = 0
		for spec: int in _component.granted_specs():
			var grant := _component.get_grant(spec)
			if not grant.get("revoked", false) and grant.get("ability_identifier", "") == String(HEALTH.ABILITY_STAMINA_SPEND):
				stamina_spec = spec
		if not _check(stamina_spec > 0, "owned stamina grant exists"): return
		var result := HEALTH.apply_bounded_instant(_component, stamina_spec,
			HEALTH.EFFECT_STAMINA_SPEND, 1_000_000, _component.get_current_tick(), 9_000_101)
		if not _check(result.get("accepted", false), "out-of-band native health mutation really occurred"): return
	else:
		# A familiar equipment identifier alone is not enough: this signal is
		# outside the registered equipment invocation and must still fail-stop.
		if not _check(not _last_equipment_event.is_empty(), "native equipment event captured"): return
		_component.tag_changed.emit(_last_equipment_event.duplicate(true))
	_expect_poison()

func _remember_equipment_event(event: Dictionary) -> void:
	_last_equipment_event = event.duplicate(true)

func _inject_health_signal(_event: Dictionary) -> void:
	if _poisoned: return
	_poisoned = true
	# Exercise reentrancy while the legitimate equipment mutation flags are
	# active. This is explicitly a forged signal, not a native damage assertion.
	_component.ability_snapshot_restored.emit({"tick": _component.get_current_tick()})

func _expect_poison() -> void:
	_check(not _raid.advance_one(_raid.generation())
		and _health.lifecycle == HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED
		and _health.last_error == &"health_component_mutated_outside_authority", "unauthorized health/equipment event remains fail-stop")

func _cleanup() -> void:
	if _component != null and _component.tag_changed.is_connected(_remember_equipment_event):
		_component.tag_changed.disconnect(_remember_equipment_event)
	if _component != null and _component.tag_changed.is_connected(_inject_health_signal):
		_component.tag_changed.disconnect(_inject_health_signal)
	if _equipment != null and _equipment.lifecycle == InventoryAbilityAdapter.Lifecycle.BOUND:
		_equipment.release_binding(&"scope_test_teardown", _raid.last_processed_tick)
	if _health != null and _health.lifecycle in [HealthConsequenceAdapter.Lifecycle.BOUND,
		HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED, HealthConsequenceAdapter.Lifecycle.INVALIDATED]:
		_check(_health.release_binding(), "health teardown")
	if _raid != null and _raid.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		_check(_raid.teardown(_raid.generation()), "authority teardown")
	if _owner != null and _owner.is_current_generation(_owner.generation()):
		_check(_owner.teardown(_owner.generation()), "inventory teardown")
	if _parent != null: _parent.free()
	_equipment = null; _health = null; _component = null; _owner = null; _raid = null; _parent = null
