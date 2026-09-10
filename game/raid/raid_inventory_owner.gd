class_name RaidInventoryOwner
extends Node
## Explicit scene-owned lifetime for profile and raid inventory authorities.
##
## InventoryAuthority is a Node with canonical mutable state.  This owner is
## deliberately an ordinary scene child (never an autoload or static
## singleton): one owner instance represents one local session/raid pair and
## owns exactly one profile authority plus one raid authority.  All callers
## must capture `generation()` and pass it back to lifecycle methods so late
## callbacks cannot reach a replaced or torn-down pair.

enum Lifecycle {
	NOT_STARTED,
	ACTIVE,
	TORN_DOWN,
}

const PROFILE_AUTHORITY_NODE_NAME: StringName = &"ProfileInventoryAuthority"
const RAID_AUTHORITY_NODE_NAME: StringName = &"RaidInventoryAuthority"

const PROFILE_STASH_PROFILE: StringName = ZerkovInventoryCatalog.PROFILE_STASH
const RAID_PLAYER_PROFILE: StringName = ZerkovInventoryCatalog.PROFILE_PLAYER_RAID
const WORLD_CRATE_PROFILE: StringName = ZerkovInventoryCatalog.PROFILE_WORLD_CRATE
const CORPSE_PROFILE: StringName = ZerkovInventoryCatalog.PROFILE_CORPSE

## Stable, positive fixture identities.  They are game-scoped opaque values;
## Inventory System does not authenticate or interpret them.
const FIXTURE_SESSION_ID: int = 7101
const FIXTURE_ACTOR_ID: int = 7201
const FIXTURE_INSERT_ACTOR_ID: int = 7202

var lifecycle: Lifecycle = Lifecycle.NOT_STARTED
var last_error: StringName = &""
var profile_inventory_id: int = 0
var raid_player_inventory_id: int = 0
var world_crate_inventory_id: int = 0
var corpse_inventory_id: int = 0

var _generation: int = 0
var _catalog: InventoryCatalog
var _profile_authority: InventoryAuthority
var _raid_authority: InventoryAuthority
var _loot_materialized: bool = false


## Configure and create both authority children.  The supplied catalog must be
## sealed; when omitted, the game-owned first-playable catalog is built and
## sealed here.  No canonical inventory is stored in a static or global.
func configure(catalog: InventoryCatalog = null) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.NOT_STARTED:
		return _reject(&"owner_already_configured")

	_catalog = catalog if catalog != null else ZerkovInventoryCatalog.build_sealed_catalog()
	if _catalog == null or not _catalog.is_sealed():
		_catalog = null
		return _reject(&"catalog_missing_or_unsealed")

	_profile_authority = _new_authority(PROFILE_AUTHORITY_NODE_NAME)
	if _profile_authority == null:
		return _reject_and_dispose(&"profile_authority_create_failed")
	profile_inventory_id = _profile_authority.create_inventory(String(PROFILE_STASH_PROFILE))
	if profile_inventory_id <= 0:
		return _reject_and_dispose(&"profile_inventory_create_failed")

	_raid_authority = _new_authority(RAID_AUTHORITY_NODE_NAME)
	if _raid_authority == null:
		return _reject_and_dispose(&"raid_authority_create_failed")
	raid_player_inventory_id = _raid_authority.create_inventory(String(RAID_PLAYER_PROFILE))
	world_crate_inventory_id = _raid_authority.create_inventory(String(WORLD_CRATE_PROFILE))
	corpse_inventory_id = _raid_authority.create_inventory(String(CORPSE_PROFILE))
	if raid_player_inventory_id <= 0 or world_crate_inventory_id <= 0 or corpse_inventory_id <= 0:
		return _reject_and_dispose(&"raid_inventory_create_failed")

	_generation = 1
	lifecycle = Lifecycle.ACTIVE
	return true


## Alias matching the composition-root terminology used by other game-owned
## authorities.  It intentionally does not create a second lifecycle path.
func start(catalog: InventoryCatalog = null) -> bool:
	return configure(catalog)


func generation() -> int:
	return _generation


func is_current_generation(expected_generation: int) -> bool:
	return lifecycle == Lifecycle.ACTIVE and expected_generation == _generation


func catalog() -> InventoryCatalog:
	return _catalog


func profile_authority() -> InventoryAuthority:
	return _profile_authority


func raid_authority() -> InventoryAuthority:
	return _raid_authority


## Materialize the one deterministic world-crate and corpse fixture.  The
## authority allocates item ids; authored rows fix definitions, quantities,
## positions, and command ids.  Repeating this method is an idempotent no-op.
func materialize_loot_fixture(expected_generation: int = _generation) -> bool:
	last_error = &""
	if not is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if _loot_materialized:
		return true

	var crate_container_id := _root_container_id(_raid_authority, world_crate_inventory_id)
	var corpse_container_id := _root_container_id(_raid_authority, corpse_inventory_id)
	if crate_container_id <= 0 or corpse_container_id <= 0:
		return _reject(&"loot_root_container_missing")

	var crate_command_id: int = 1_001
	for row_value in ZerkovInventoryCatalog.world_crate_fixture_contents():
		var row := row_value as Dictionary
		var destination: Dictionary = (row["location"] as Dictionary).duplicate(true)
		destination["container"] = crate_container_id
		var result: Dictionary = _raid_authority.insert_item(
			world_crate_inventory_id,
			String(row["item_definition_identifier"]),
			int(row["quantity"]),
			destination,
			FIXTURE_INSERT_ACTOR_ID,
			crate_command_id
		)
		if not bool(result.get("accepted", false)):
			return _reject(&"world_crate_fixture_insert_failed")
		crate_command_id += 1

	var corpse_command_id: int = 2_001
	for row_value in ZerkovInventoryCatalog.corpse_fixture_contents():
		var row := row_value as Dictionary
		var destination: Dictionary = (row["location"] as Dictionary).duplicate(true)
		destination["container"] = corpse_container_id
		var result: Dictionary = _raid_authority.insert_item(
			corpse_inventory_id,
			String(row["item_definition_identifier"]),
			int(row["quantity"]),
			destination,
			FIXTURE_INSERT_ACTOR_ID,
			corpse_command_id
		)
		if not bool(result.get("accepted", false)):
			return _reject(&"corpse_fixture_insert_failed")
		corpse_command_id += 1

	var recipient_result: Dictionary = _raid_authority.register_discovery_recipient(
		FIXTURE_SESSION_ID,
		FIXTURE_ACTOR_ID
	)
	if not bool(recipient_result.get("ok", false)):
		return _reject(&"loot_discovery_recipient_register_failed")
	_loot_materialized = true
	return true


func loot_fixture_ready(expected_generation: int = _generation) -> bool:
	return is_current_generation(expected_generation) and _loot_materialized


func world_crate_container_id() -> int:
	return _root_container_id(_raid_authority, world_crate_inventory_id)


func corpse_container_id() -> int:
	return _root_container_id(_raid_authority, corpse_inventory_id)


## Returns a recipient-safe staged-discovery view for the selected fixture.
## The caller still advances searches through the trusted authority API.
func loot_discovery_view(inventory_id: int = 0) -> InventoryDiscoverySnapshotResource:
	if not loot_fixture_ready():
		return null
	var target_inventory := world_crate_inventory_id if inventory_id <= 0 else inventory_id
	return _raid_authority.discovery_view(FIXTURE_SESSION_ID, FIXTURE_ACTOR_ID, target_inventory)


func advance_loot_discovery(elapsed_ms: int) -> InventoryDiscoveryResultResource:
	if not loot_fixture_ready():
		return null
	return _raid_authority.advance_discovery(FIXTURE_SESSION_ID, FIXTURE_ACTOR_ID, elapsed_ms)


## Synchronously unloads both authorities' inventories, removes the authority
## nodes, and advances the owner generation.  A stale/late callback is a
## no-op at this boundary and cannot mutate a replacement owner.
func teardown(expected_generation: int) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.ACTIVE:
		return _reject(&"owner_not_active")
	if expected_generation != _generation:
		return _reject(&"stale_generation")

	var recipient_ok := true
	if _loot_materialized and _raid_authority != null:
		var recipient_result: Dictionary = _raid_authority.teardown_discovery_recipient(
			FIXTURE_SESSION_ID,
			FIXTURE_ACTOR_ID
		)
		recipient_ok = bool(recipient_result.get("ok", false))

	var profile_ok := _unload_inventory(_profile_authority, profile_inventory_id)
	var raid_ok := _unload_inventory(_raid_authority, raid_player_inventory_id)
	raid_ok = _unload_inventory(_raid_authority, world_crate_inventory_id) and raid_ok
	raid_ok = _unload_inventory(_raid_authority, corpse_inventory_id) and raid_ok

	_dispose_authority_children()
	_catalog = null
	profile_inventory_id = 0
	raid_player_inventory_id = 0
	world_crate_inventory_id = 0
	corpse_inventory_id = 0
	_loot_materialized = false
	lifecycle = Lifecycle.TORN_DOWN
	_generation += 1
	if not recipient_ok:
		return _reject(&"discovery_recipient_teardown_failed")
	if not profile_ok or not raid_ok:
		return _reject(&"authority_inventory_teardown_failed")
	return true


func _exit_tree() -> void:
	# Scene removal is also an explicit lifetime boundary.  The normal game
	# path calls teardown first, but this guard covers owner queue_free() during
	# shutdown without retaining canonical native runtimes in orphan nodes.
	if lifecycle == Lifecycle.ACTIVE:
		teardown(_generation)


func _new_authority(node_name: StringName) -> InventoryAuthority:
	var authority := InventoryAuthority.new()
	authority.name = node_name
	authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	authority.set_catalog(_catalog)
	add_child(authority)
	return authority


func _root_container_id(authority: InventoryAuthority, inventory_id: int) -> int:
	if authority == null or inventory_id <= 0:
		return 0
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0:
			return int(container.get("id", 0))
	return 0


func _unload_inventory(authority: InventoryAuthority, inventory_id: int) -> bool:
	if authority == null or inventory_id <= 0:
		return true
	if not authority.has_inventory(inventory_id):
		return true
	var result: Dictionary = authority.unload_inventory(inventory_id)
	return bool(result.get("ok", false))


func _dispose_authority_children() -> void:
	for authority in [_profile_authority, _raid_authority]:
		if authority == null:
			continue
		if authority.get_parent() == self:
			remove_child(authority)
		authority.queue_free()
	_profile_authority = null
	_raid_authority = null


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


func _reject_and_dispose(reason: StringName) -> bool:
	# A failed multi-authority bootstrap can happen after the profile runtime or
	# a prefix of the raid runtimes already exists. Unload each live runtime
	# before releasing its Node so failure leaves no temporarily reachable
	# canonical state and a retry starts from a clean lifecycle boundary.
	_unload_inventory(_profile_authority, profile_inventory_id)
	_unload_inventory(_raid_authority, raid_player_inventory_id)
	_unload_inventory(_raid_authority, world_crate_inventory_id)
	_unload_inventory(_raid_authority, corpse_inventory_id)
	_dispose_authority_children()
	_catalog = null
	profile_inventory_id = 0
	raid_player_inventory_id = 0
	world_crate_inventory_id = 0
	corpse_inventory_id = 0
	_loot_materialized = false
	return _reject(reason)
