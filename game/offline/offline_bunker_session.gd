class_name OfflineBunkerSession
extends Node
## The sole pre-raid writer. InventoryAuthority owns item semantics; ProfileStore
## owns disk bytes. Staged native state is never exposed before verified save acceptance.
signal changed
const PROFILE_ID := "zerkov.profile.offline.default"
const FORMAT := "zerkov.offline.bunker.v1"
const ROOTS := {
	"stash": ZerkovInventoryCatalog.CONTAINER_STASH,
	"pockets": ZerkovInventoryCatalog.CONTAINER_POCKETS,
	"rig": ZerkovInventoryCatalog.CONTAINER_RIG,
	"backpack": ZerkovInventoryCatalog.CONTAINER_BACKPACK,
	"secure": ZerkovInventoryCatalog.CONTAINER_SECURE,
	"equipment": ZerkovInventoryCatalog.CONTAINER_EQUIPMENT,
}
var _store: ProfileStore
var _catalog: InventoryCatalog
var _native: InventoryAuthority
var _payload: Dictionary = {}
var _disk_generation: int = 0
var _generation: int = 0
var _busy := false
var _blocked := false
var _status: String = "not_started"
var _last_error: String = ""
var _settings: Dictionary = {"master_volume": 80}

func start() -> bool:
	if _store != null:
		return false
	_store = ProfileStore.new()
	if not _store.configure(PROFILE_ID):
		_last_error = String(_store.last_error)
		_blocked = true
		return false
	_catalog = OfflineBunkerCatalog.build()
	if _catalog == null:
		_blocked = true
		_last_error = "offline_catalog_invalid"
		return false
	inspect_disk()
	return true

## Debug-only trusted seam; never reached by a screen or command payload.
func start_for_test(store: ProfileStore) -> bool:
	if not OS.is_debug_build() or _store != null or store == null or not store.is_configured():
		return false
	_store = store
	_catalog = OfflineBunkerCatalog.build()
	if _catalog == null:
		return false
	inspect_disk()
	return true

func inspect_disk() -> void:
	if _busy or _store == null:
		return
	var result := _store.load_profile()
	if result.get("ok", false):
		_status = "available"
		_last_error = "backup_recovered" if result.get("recovered_backup", false) else ""
	elif result.get("reason") == &"profile_missing":
		_status = "missing"
		_last_error = ""
	else:
		_status = "blocked"
		_last_error = String(result.get("reason", "profile_unreadable"))

func status() -> Dictionary:
	return RaidProgressionValues.freeze({"mode": "offline", "open": is_open(),
		"disk_status": _status, "generation": _generation, "revision": revision(),
		"save_generation": _disk_generation, "error": _last_error,
		"name": "Local Bunker", "deployment_ready": false,
		"steam_required": false, "busy": _busy, "blocked": _blocked,
		"master_volume": _settings.master_volume})

func is_open() -> bool:
	return _native != null and not _blocked

func generation() -> int:
	return _generation

func revision() -> int:
	return _native.inventory_revision(1) if _native != null else 0

func snapshot() -> InventorySnapshotResource:
	return _native.snapshot(1) if is_open() else null

func container_id(source: String) -> int:
	var current := snapshot()
	return _container(current, source) if current != null else 0

func _container(current: InventorySnapshotResource, source: String) -> int:
	for row: Dictionary in current.get_containers():
		if row.container_definition_identifier == String(ROOTS.get(source, "")) and int(row.provider_item) == 0:
			return int(row.id)
	return 0

func open_profile(create_new: bool) -> bool:
	if _busy or _store == null or _catalog == null:
		return false
	_busy = true
	var loaded := _store.load_profile()
	var candidate: InventoryAuthority
	var payload: Dictionary
	if create_new:
		if loaded.get("ok", false) or loaded.get("reason") != &"profile_missing":
			return _fail_open("profile_exists_or_unreadable")
		candidate = _new_native()
		if candidate.create_inventory(OfflineBunkerCatalog.PROFILE) != 1:
			candidate.free()
			return _fail_open("new_inventory_failed")
		var stash := _container(candidate.snapshot(1), "stash")
		for row: Dictionary in OfflineBunkerCatalog.starter():
			var result := candidate.insert_item(1, String(row.definition), row.quantity,
				{"kind": "spatial", "container": stash, "x": row.at[0], "y": row.at[1], "rotated": false}, 1)
			if not result.get("accepted", false):
				candidate.free()
				return _fail_open("starter_content_rejected")
		payload = {"project": {"offline_bunker": {"schema": FORMAT,
			"starter_version": OfflineBunkerCatalog.STARTER_VERSION, "trust": "local_only",
			"settings": {"master_volume": 80}}},
			"domains": {OfflineBunkerCatalog.DOMAIN: candidate.make_persistence_record(1)}}
		_disk_generation = 0
		if not _save_candidate(payload):
			candidate.free()
			_busy = false
			changed.emit()
			return false
	else:
		if not loaded.get("ok", false):
			return _fail_open(String(loaded.get("reason", "load_failed")))
		payload = loaded.payload.duplicate(true)
		if not _valid_payload(payload):
			return _fail_open("offline_profile_migration_required")
		candidate = _restore(payload.domains[OfflineBunkerCatalog.DOMAIN])
		if candidate == null:
			return _fail_open("native_inventory_record_invalid")
		_disk_generation = int(loaded.generation)
		_last_error = "backup_recovered" if loaded.get("recovered_backup", false) else ""
	if _native != null:
		_native.free()
	_native = candidate
	_payload = payload
	_settings = payload.project.offline_bunker.settings.duplicate(true)
	_generation += 1
	_blocked = false
	_status = "available"
	_busy = false
	changed.emit()
	return true

func _fail_open(reason: String) -> bool:
	_last_error = reason
	_status = "blocked" if reason != "profile_exists_or_unreadable" else _status
	_busy = false
	changed.emit()
	return false

func _valid_payload(value: Dictionary) -> bool:
	if not value.get("project") is Dictionary or not value.get("domains") is Dictionary:
		return false
	# Explicitly exclude active/pending raids, foreign schemas and silent conversions.
	if value.domains.size() != 1 or not value.domains.get(OfflineBunkerCatalog.DOMAIN) is PackedByteArray:
		return false
	if value.project.size() != 1 or not value.project.get("offline_bunker") is Dictionary:
		return false
	var meta: Dictionary = value.project.offline_bunker
	if meta.size() != 4 or typeof(meta.get("schema")) != TYPE_STRING \
			or typeof(meta.get("starter_version")) != TYPE_INT \
			or typeof(meta.get("trust")) != TYPE_STRING \
			or not meta.get("settings") is Dictionary:
		return false
	if meta.schema != FORMAT or meta.starter_version != 1 or meta.trust != "local_only":
		return false
	return meta.settings.size() == 1 \
		and typeof(meta.settings.get("master_volume")) == TYPE_INT \
		and meta.settings.master_volume >= 0 and meta.settings.master_volume <= 100


func _new_native() -> InventoryAuthority:
	var value := InventoryAuthority.new()
	value.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	value.set_catalog(_catalog)
	return value

func _restore(bytes: PackedByteArray) -> InventoryAuthority:
	if bytes.is_empty() or bytes.size() > ProfileCanonicalCodec.MAX_BLOB_BYTES:
		return null
	var value := _new_native()
	var result := value.apply_persistence_record(bytes)
	if not result.get("ok", false) or int(result.get("inventory_id", 0)) != 1:
		value.free()
		return null
	var snap := value.snapshot(1)
	if snap == null or snap.get_profile_identifier() != OfflineBunkerCatalog.PROFILE:
		value.free()
		return null
	return value

func _save_candidate(payload: Dictionary) -> bool:
	var result := _store.save_profile(payload, _disk_generation, _disk_generation + 1)
	if result.get("status") == ProfileStore.WRITE_COMMITTED_RECOVERY_REQUIRED:
		_blocked = true
		_last_error = "save_requires_reload"
		return false
	if not result.get("committed", false):
		_last_error = "save_failed_" + String(result.get("reason", "unknown"))
		return false
	# Verify exact bytes/generation before publishing. Never retry a native edit
	# after an ambiguous write; Continue reloads the committed record instead.
	var readback := _store.load_profile()
	if not readback.get("ok", false) or readback.generation != _disk_generation + 1 		or readback.payload != payload:
		_blocked = true
		_last_error = "save_requires_reload"
		return false
	_disk_generation = int(readback.generation)
	_last_error = ""
	return true

func execute(command: Dictionary) -> Dictionary:
	if _busy:
		return _rejected("command_busy")
	if not is_open():
		return _rejected("profile_not_open")
	# Closed command envelope. The native library retains all geometry, stacking,
	# slot filtering, nesting and retention checks. Screens cannot spawn items.
	var required := ["operation", "generation", "revision", "item_id", "source", "target", "x", "y", "quantity", "other_item_id", "slot"]
	if command.size() != required.size():
		return _rejected("command_shape_invalid")
	for key: String in required:
		if not command.has(key):
			return _rejected("command_shape_invalid")
	for key: String in ["generation", "revision", "item_id", "x", "y", "quantity", "other_item_id"]:
		if typeof(command[key]) != TYPE_INT:
			return _rejected("command_type_invalid")
	for key: String in ["operation", "source", "target", "slot"]:
		if typeof(command[key]) != TYPE_STRING:
			return _rejected("command_type_invalid")
	if command.generation != _generation or command.revision != revision():
		return _rejected("stale_inventory_gesture")
	if not ROOTS.has(command.source) or not ROOTS.has(command.target):
		return _rejected("inventory_source_unknown")
	var item: Dictionary = {}
	for row: Dictionary in _native.snapshot(1).get_items():
		if int(row.id) == command.item_id:
			item = row
	if item.is_empty() or int(item.location.container) != container_id(command.source):
		return _rejected("item_source_changed")
	_busy = true
	var candidate := _restore(_native.make_persistence_record(1))
	if candidate == null:
		_busy = false
		return _rejected("inventory_stage_failed")
	var destination := {"kind": "spatial", "container": container_id(command.target),
		"x": command.x, "y": command.y, "rotated": bool(item.location.get("rotated", false))}
	var result: Dictionary = {}
	match command.operation:
		"move":
			if command.target == "equipment":
				result = candidate.equip_item(1, command.item_id, container_id("equipment"), command.slot, 1)
			elif command.source == "equipment":
				result = candidate.unequip_item(1, command.item_id, destination, 1)
			else:
				result = candidate.move_item(1, command.item_id, destination, 1)
		"rotate":
			result = candidate.rotate_item(1, command.item_id, not bool(item.location.get("rotated", false)), 1)
		"split":
			result = candidate.split_stack(1, command.item_id, command.quantity, destination, 1)
		"merge":
			result = candidate.merge_stacks(1, command.item_id, command.other_item_id, 1)
		"quick":
			result = candidate.auto_place_item(1, command.item_id, container_id(command.target), 1)
		_:
			candidate.free()
			_busy = false
			return _rejected("operation_not_supported")
	if not result.get("accepted", false):
		candidate.free()
		_busy = false
		return _rejected("native_inventory_rejected", result)
	var next := _payload.duplicate(true)
	next.domains[OfflineBunkerCatalog.DOMAIN] = candidate.make_persistence_record(1)
	if not _save_candidate(next):
		candidate.free()
		_busy = false
		changed.emit()
		return _rejected(_last_error)
	var previous := _native
	_native = candidate
	_payload = next
	previous.free()
	# Publication is within the busy boundary: reentrant callbacks cannot submit.
	changed.emit()
	_busy = false
	return RaidProgressionValues.freeze({"accepted": true, "committed": true,
		"revision": revision(), "generation": _generation, "save_generation": _disk_generation})

func set_volume(value: int, expected_generation: int) -> bool:
	if _busy or not is_open() or expected_generation != _generation or value < 0 or value > 100:
		return false
	if value == _settings.master_volume:
		return true
	_busy = true
	var next := _payload.duplicate(true)
	next.project.offline_bunker.settings.master_volume = value
	var ok := _save_candidate(next)
	if ok:
		_payload = next
		_settings = next.project.offline_bunker.settings.duplicate(true)
	changed.emit()
	_busy = false
	return ok

func close_profile() -> bool:
	if _busy:
		return false
	if _native != null:
		_native.free()
	_native = null
	_payload = {}
	_generation += 1
	_blocked = false
	inspect_disk()
	changed.emit()
	return true

func _rejected(reason: String, detail: Dictionary = {}) -> Dictionary:
	_last_error = reason
	return RaidProgressionValues.freeze({"accepted": false, "committed": false,
		"reason": reason, "reason_token": reason, "status": {"reason": reason}, "detail": detail})

func _exit_tree() -> void:
	if _native != null:
		_native.free()
		_native = null
	if _store != null:
		_store.close()
