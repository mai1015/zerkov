class_name ZReplicationGrant
extends RefCounted
## Credential-free recipient capability for product-owned replication egress.
##
## A grant is derived only from an active authenticated session admission. It
## names the exact recipient session/peer/epoch, its owned actor, the channels it
## may receive, and the native inventory identifiers owned by that actor. It is
## not a transport token and is never accepted from a client.

const CHANNEL_INVENTORY: StringName = &"inventory"
const CHANNEL_WEAPON: StringName = &"weapon"
const CHANNEL_ABILITY: StringName = &"ability"
const CHANNEL_VISION: StringName = &"vision"
const CHANNELS: PackedStringArray = [
	"ability",
	"inventory",
	"vision",
	"weapon",
]
const MAX_INVENTORY_IDS: int = 32
const MAX_INVENTORY_ID: int = 2_147_483_647

var admission: ZSessionAdmission
var channels: PackedStringArray = PackedStringArray()
var inventory_ids: PackedInt64Array = PackedInt64Array()
var grant_digest: String = ""


static func create(
	p_admission: ZSessionAdmission,
	p_channels: PackedStringArray,
	p_inventory_ids: PackedInt64Array = PackedInt64Array()
) -> ZReplicationGrant:
	if (
		p_admission == null
		or not p_admission.is_usable()
		or p_admission.trust_level
			!= ZSessionAdmission.TrustLevel.REMOTE_AUTHENTICATED
	):
		return null
	var normalized_channels := _normalize_channels(p_channels)
	if normalized_channels.is_empty():
		return null
	var normalized_inventory_ids := _normalize_inventory_ids(p_inventory_ids)
	if (
		normalized_inventory_ids.is_empty()
		and not p_inventory_ids.is_empty()
	):
		return null
	if (
		normalized_channels.has(String(CHANNEL_INVENTORY))
		and normalized_inventory_ids.is_empty()
	):
		return null
	if (
		not normalized_channels.has(String(CHANNEL_INVENTORY))
		and not normalized_inventory_ids.is_empty()
	):
		return null

	var frozen_admission := p_admission.snapshot()
	if frozen_admission == null:
		return null
	var result := ZReplicationGrant.new()
	result.admission = frozen_admission
	result.channels = normalized_channels
	result.inventory_ids = normalized_inventory_ids
	result.grant_digest = result._calculate_digest()
	return result if result.is_usable() else null


func is_usable() -> bool:
	if (
		admission == null
		or not admission.is_usable()
		or admission.trust_level
			!= ZSessionAdmission.TrustLevel.REMOTE_AUTHENTICATED
		or channels.is_empty()
		or channels.size() > CHANNELS.size()
		or inventory_ids.size() > MAX_INVENTORY_IDS
	):
		return false
	var previous_channel := ""
	for raw_channel in channels:
		var channel := String(raw_channel)
		if not CHANNELS.has(channel):
			return false
		if not previous_channel.is_empty() and channel <= previous_channel:
			return false
		previous_channel = channel
	var previous_inventory_id: int = 0
	for inventory_id in inventory_ids:
		if (
			inventory_id <= 0
			or inventory_id > MAX_INVENTORY_ID
			or inventory_id <= previous_inventory_id
		):
			return false
		previous_inventory_id = inventory_id
	if (
		allows_channel(CHANNEL_INVENTORY)
		!= not inventory_ids.is_empty()
	):
		return false
	return (
		ZProductCompatibilityManifest.is_sha256(grant_digest)
		and grant_digest == _calculate_digest()
	)


func allows_channel(channel: StringName) -> bool:
	return channels.has(String(channel))


func owns_inventory(inventory_id: int) -> bool:
	return inventory_ids.has(inventory_id)


func session_id() -> ZSessionId:
	return (
		ZSessionId.parse(admission.session_id.canonical_key())
		if admission != null
		else null
	)


func actor_id() -> ZEntityId:
	return (
		ZEntityId.parse(admission.actor_id.canonical_key())
		if admission != null
		else null
	)


func snapshot() -> ZReplicationGrant:
	if not is_usable():
		return null
	return create(
		admission.snapshot(),
		channels.duplicate(),
		inventory_ids.duplicate()
	)


func _calculate_digest() -> String:
	if admission == null:
		return ""
	var channel_values: Array = []
	for channel in channels:
		channel_values.append(String(channel))
	var inventory_values: Array = []
	for inventory_id in inventory_ids:
		inventory_values.append(inventory_id)
	return ZCanonicalValue.sha256({
		"actor_id": admission.actor_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"channels": channel_values,
		"compatibility_digest": admission.compatibility_digest,
		"inventory_ids": inventory_values,
		"session_id": admission.session_id.canonical_key(),
		"transport_peer_id": admission.transport_peer_id,
	})


static func _normalize_channels(source: PackedStringArray) -> PackedStringArray:
	if source.is_empty() or source.size() > CHANNELS.size():
		return PackedStringArray()
	var seen: Dictionary = {}
	var result := PackedStringArray()
	for raw_channel in source:
		var channel := String(raw_channel)
		if not CHANNELS.has(channel):
			return PackedStringArray()
		if seen.has(channel):
			continue
		seen[channel] = true
		result.append(channel)
	result.sort()
	return result


static func _normalize_inventory_ids(
	source: PackedInt64Array
) -> PackedInt64Array:
	if source.size() > MAX_INVENTORY_IDS:
		return PackedInt64Array()
	var seen: Dictionary = {}
	var values: Array[int] = []
	for inventory_id in source:
		if inventory_id <= 0 or inventory_id > MAX_INVENTORY_ID:
			return PackedInt64Array()
		if seen.has(inventory_id):
			continue
		seen[inventory_id] = true
		values.append(inventory_id)
	values.sort()
	var result := PackedInt64Array()
	for inventory_id in values:
		result.append(inventory_id)
	return result
