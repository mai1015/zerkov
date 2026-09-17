class_name RaidProgressionValues
extends RefCounted
## Closed persistence values. No scene objects or executable data cross saves.
const STATE_KEY := "raid_progression"
const LOADOUT := "zerkov.inventory.loadout"
const STASH := "zerkov.inventory.stash"
const PENDING_LOADOUT := "zerkov.raid.pending_loadout"
const VERSION: int = 1
const MAX_HISTORY: int = 128 # Reserve a receipt slot BEFORE deploying, never evict silently.

static func digest(value: Variant) -> String:
	var encoded := ProfileCanonicalCodec.encode(value)
	return ProfileCanonicalCodec.sha256_domain("zerkov.raid.progression.v1", encoded.bytes) if encoded.ok else ""

static func encode(value: Variant) -> PackedByteArray:
	var result := ProfileCanonicalCodec.encode(value)
	return result.bytes if result.ok else PackedByteArray()

static func decode(bytes: PackedByteArray) -> Dictionary:
	var result := ProfileCanonicalCodec.decode(bytes)
	return result.value if result.ok and result.value is Dictionary else {}

static func freeze(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = freeze(value[key])
		result.make_read_only()
		return result
	if value is Array:
		var result: Array = []
		for child in value: result.append(freeze(child))
		result.make_read_only()
		return result
	if value is PackedByteArray: return value.duplicate()
	return value

static func failure(reason: StringName) -> Dictionary:
	return freeze({"ok": false, "reason": reason, "committed": false})

static func initial_state() -> Dictionary:
	return {"version": VERSION, "next_sequence": 1, "active": {}, "history": {}}

static func valid_state(state: Dictionary) -> bool:
	if state.size()!=4 or state.get("version")!=VERSION or not counter(state.get("next_sequence"),1) \
		or not state.get("active") is Dictionary or not state.get("history") is Dictionary or state.history.size()>MAX_HISTORY:
		return false
	for key: Variant in state.history:
		if typeof(key)!=TYPE_STRING or not ZIdentityRules.is_valid(key,&"raid") or not state.history[key] is PackedByteArray:
			return false
		var receipt := decode(state.history[key])
		if not valid_receipt(receipt) or receipt.raid_id!=key: return false
	var active: Dictionary=state.active
	if active.is_empty(): return true
	if active.get("phase") not in ["deployed","prepared"] or active.get("resume_enabled")!=false \
		or active.size()!=((9 if active.phase=="prepared" else 8)+(1 if active.has("map") else 0)): return false
	if active.has("map") and not valid_map_descriptor(active.map): return false
	for pair: Array in [["raid_id",&"raid"],["settlement_id",&"settlement"],["request_id",&"request"]]:
		if typeof(active.get(pair[0]))!=TYPE_STRING or not ZIdentityRules.is_valid(active[pair[0]],pair[1]): return false
	if not counter(active.get("start_generation"),1) \
		or not sha(active.get("start_fingerprint")) or not sha(active.get("escrow_digest")): return false
	if active.phase=="prepared":
		if not active.get("receipt_bytes") is PackedByteArray: return false
		var receipt := decode(active.receipt_bytes)
		if not valid_receipt(receipt) or receipt.raid_id!=active.raid_id \
			or receipt.settlement_id!=active.settlement_id or receipt.deployment_request!=active.request_id \
			or receipt.source_profile_generation!=active.start_generation \
			or receipt.get("map",{})!=active.get("map",{}): return false
	return true

static func valid_receipt(receipt: Dictionary) -> bool:
	if receipt.size()!=(20 if receipt.has("map") else 19) or receipt.get("schema")!="zerkov.raid.settlement.v1" \
		or receipt.get("outcome") not in ["extracted","dead","timeout","abandoned"] \
		or typeof(receipt.get("audit_available"))!=TYPE_BOOL \
		or receipt.get("valuation_available")!=false or receipt.get("currency_reward")!=0: return false
	if receipt.has("map") and not valid_map_descriptor(receipt.map): return false
	for pair: Array in [["raid_id",&"raid"],["settlement_id",&"settlement"],["deployment_request",&"request"]]:
		if typeof(receipt.get(pair[0]))!=TYPE_STRING or not ZIdentityRules.is_valid(receipt[pair[0]],pair[1]): return false
	for key: String in ["input_digest","audit_digest","inventory_digest"]:
		if not sha(receipt.get(key)): return false
	if not counter(receipt.get("source_profile_generation"),1) or not counter(receipt.get("profile_generation"),4) \
		or receipt.profile_generation!=receipt.source_profile_generation+3 \
		or not counter(receipt.get("duration_ticks"),0) or receipt.duration_ticks>2_147_483_647: return false
	for key: String in ["stats","health","task"]:
		if not receipt.get(key) is Dictionary: return false
	for key: String in ["retained","lost"]:
		if not receipt.get(key) is Array: return false
		for row: Variant in receipt[key]:
			if not row is Dictionary or row.size()!=2 or typeof(row.get("definition"))!=TYPE_STRING \
				or row.definition.is_empty() or not counter(row.get("quantity"),1): return false
	return not encode(receipt).is_empty()

## Optional closed extension of existing v1 records. Empty means legacy
## Sawmill only; an explicitly present descriptor is never silently dropped.
static func valid_map_descriptor(value: Variant) -> bool:
	return value is Dictionary and value.size()==3 \
		and typeof(value.get("id"))==TYPE_STRING and value.id in ["northline","blackwater"] \
		and counter(value.get("revision"),1) and sha(value.get("digest"))

static func counter(value: Variant, minimum: int) -> bool:
	return typeof(value)==TYPE_INT and value>=minimum and value<ProfileStore.MAX_COUNTER-4
static func sha(value: Variant) -> bool:
	return typeof(value)==TYPE_STRING and ProfileCanonicalCodec.is_sha256(value)

static func ids(profile_id: String, sequence: int) -> Dictionary:
	var suffix := profile_id.sha256_text().substr(0, 32) + ".r" + str(sequence)
	return {"raid_id": "zerkov.raid." + suffix, "settlement_id": "zerkov.settlement." + suffix}
