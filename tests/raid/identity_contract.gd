extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/identity_contract.gd

const ID_TYPES: Array[Script] = [
	preload("res://game/domain/z_entity_id.gd"),
	preload("res://game/domain/z_inventory_id.gd"),
	preload("res://game/domain/z_weapon_id.gd"),
	preload("res://game/domain/z_task_id.gd"),
	preload("res://game/domain/z_request_id.gd"),
	preload("res://game/domain/z_consequence_id.gd"),
	preload("res://game/domain/z_raid_id.gd"),
	preload("res://game/domain/z_settlement_id.gd"),
	preload("res://game/domain/z_session_id.gd"),
]

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("IDENTITY_CONTRACT: " + message)


func run() -> void:
	var seen: Dictionary = {}
	for type_index in ID_TYPES.size():
		var id_script := ID_TYPES[type_index]
		for value_index in 1024:
			var parts := PackedStringArray([
				"fixture",
				"type_%02d" % type_index,
				"value_%04d" % value_index,
			])
			var identifier: ZStableId = id_script.from_parts(parts)
			check(identifier != null, "valid ID constructs")
			if identifier == null:
				continue
			var key := identifier.canonical_key()
			check(not seen.has(key), "no canonical collision for " + key)
			seen[key] = true
	check(seen.size() == ID_TYPES.size() * 1024, "all fixture identities are unique")

	var entity := ZEntityId.parse("zerkov.entity.raid.actor_01")
	var weapon := ZWeaponId.parse("zerkov.weapon.raid.actor_01")
	check(entity != null and weapon != null, "parallel typed IDs parse")
	check(entity != null and weapon != null and not entity.is_equal(weapon),
		"different identity kinds never compare equal")
	check(ZEntityId.parse("Zerkov.entity.raid.actor") == null, "uppercase is rejected")
	check(ZEntityId.parse("zerkov.entity.actor") == null, "missing scope is rejected")
	check(ZEntityId.parse("zerkov.weapon.raid.actor") == null, "wrong kind is rejected")
	check(ZEntityId.parse("zerkov.entity.raid.bad value") == null, "spaces are rejected")
	check(ZEntityId.parse("zerkov.entity.raid..actor") == null, "empty segments are rejected")
	var wrong_kind_instance := ZEntityId.new()
	check(not wrong_kind_instance._initialize(
		ZWeaponId.KIND,
		"zerkov.weapon.raid.actor_01"
	), "a concrete ID cannot be initialized as another kind")
	var stable_key := entity.canonical_key()
	check(not entity._initialize(ZEntityId.KIND, "zerkov.entity.raid.actor_02")
		and entity.canonical_key() == stable_key, "an initialized ID cannot be rebound")

	print("IDENTITY_CONTRACT_RESULT checks=", checks, " failures=", failures,
		" unique=", seen.size())
	quit(0 if failures == 0 else 1)
