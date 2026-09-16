class_name LocalCampaign
extends RefCounted
## Single local writer. Existing ProfileStore owns files, checksums, backup/CAS
## and interrupted-settlement recovery. No remote save or parallel save format.
const V = preload("res://game/raid/progression/raid_progression_values.gd")
var last_error: StringName = &""
var store: ProfileStore
var loaded: Dictionary = {}
var recovered_result: Dictionary = {}
var _native: NativeSettlementInventory

func open(existing_store: ProfileStore = null) -> bool:
	if store != null: return _fail(&"local_campaign_already_open")
	store = existing_store if existing_store != null else ProfileStore.new()
	if existing_store == null and not store.configure(LocalCampaignContent.PROFILE_ID):
		return _fail(store.last_error)
	if not store.is_configured(): return _fail(&"local_profile_store_unavailable")
	_native = NativeSettlementInventory.new()
	if not _native.configure(): return _fail(&"local_inventory_catalog_unavailable")
	return reload(true)

func reload(recover_active: bool = false) -> bool:
	last_error = &""
	loaded = store.load_profile()
	if not loaded.ok:
		return true if loaded.reason == &"profile_missing" else _fail(StringName(loaded.reason))
	if not _valid_domains(loaded.payload): return _fail(&"local_profile_domains_invalid")
	var policy: Dictionary = loaded.payload.project.get("local_campaign", {})
	if policy.get("version") != LocalCampaignContent.VERSION or policy.get("health_policy") != "recover_at_home":
		return _fail(&"local_campaign_migration_required")
	var state: Dictionary = loaded.payload.project.get(V.STATE_KEY, V.initial_state())
	if not V.valid_state(state): return _fail(&"local_profile_progression_invalid")
	if not state.active.is_empty():
		if not recover_active: return _fail(&"local_profile_active_raid")
		var service := RaidSettlementService.new()
		if not service.configure(store, _native): return _fail(&"local_recovery_unavailable")
		recovered_result = service.recover()
		if recovered_result.get("ok") != true: return _fail(StringName(recovered_result.get("reason", &"local_recovery_failed")))
		loaded = store.load_profile()
		if not loaded.ok: return _fail(StringName(loaded.reason))
	return true

func create(parent: Node) -> bool:
	# Re-read immediately before issuing one-time content. Never replace a save.
	if not reload() or loaded.get("reason") != &"profile_missing": return _fail(&"local_profile_already_exists")
	var payload := LocalCampaignContent.create_payload(parent)
	if payload.is_empty(): return _fail(&"local_initial_content_failed")
	var saved := store.save_profile(payload, 0, 1)
	if saved.get("committed") != true: return _fail(StringName(saved.get("reason", &"local_create_failed")))
	return reload()

func has_profile() -> bool:
	return loaded.get("ok") == true and last_error.is_empty()

func instantiate_home(parent: Node) -> RaidInventoryOwner:
	return _native.instantiate_owner(parent, loaded.payload.domains) if has_profile() else null

func save_home(owner: RaidInventoryOwner) -> bool:
	if store == null or not store.is_configured() or loaded.get("ok") != true \
		or owner == null or not owner.is_current_generation(owner.generation()):
		return _fail(&"local_loadout_unavailable")
	var current := store.load_profile()
	if not current.ok or current.generation != loaded.generation: return _fail(&"local_profile_generation_changed")
	var state: Dictionary = current.payload.project.get(V.STATE_KEY, V.initial_state())
	if not V.valid_state(state) or not state.active.is_empty(): return _fail(&"local_profile_active_raid")
	var payload: Dictionary = current.payload.duplicate(true)
	payload.domains[V.LOADOUT] = owner.raid_authority().make_persistence_record(owner.raid_player_inventory_id)
	payload.domains[V.STASH] = owner.profile_authority().make_persistence_record(owner.profile_inventory_id)
	if payload == current.payload:
		loaded = current
		last_error = &""
		return true
	if not _valid_domains(payload): return _fail(&"local_loadout_invalid")
	var result := store.save_profile(payload, current.generation, current.generation + 1)
	if result.get("committed") != true: return _fail(StringName(result.get("reason", &"local_save_failed")))
	return reload()

func close() -> bool:
	return store == null or not store.is_configured() or store.close()

func _valid_domains(payload: Dictionary) -> bool:
	return payload.get("domains") is Dictionary and payload.domains.get(V.LOADOUT) is PackedByteArray \
		and payload.domains.get(V.STASH) is PackedByteArray \
		and _native.validate_loadout(payload.domains[V.LOADOUT]) and _native.validate_stash(payload.domains[V.STASH])

func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
