class_name WeaponDiagnosticsPanel
extends Control

## Optional bounded diagnostic overlay (weapon-presentation spec.md "Stable
## Presentation Signals"; reference-slice task 10.5). Fed exclusively by
## public signals/return values from `WeaponAuthority`, the optional
## `WeaponInventoryAdapter`/`WeaponGasAdapter` (both expose the SAME
## `health_changed(ready, diagnostic)` signal shape), and, if present, a
## `WeaponNetworkBridge`. Never grows unboundedly -- entries past
## `max_entries` evict the oldest first (a ring buffer via `Array.pop_front`).
## Never mutates weapon/inventory/GAS/network state; safe to remove.

signal entry_logged(entry: Dictionary)

const CATEGORY_REJECTED := "rejected_command"
const CATEGORY_CORRECTED := "state_corrected"
const CATEGORY_ADAPTER_HEALTH := "adapter_health"
const CATEGORY_CONTENT_INCOMPATIBLE := "content_incompatible"
const CATEGORY_MISSING_CLASS := "missing_native_class"
const CATEGORY_RESYNC := "resync_in_progress"
const CATEGORY_NETWORK := "network_diagnostic"

@export var max_entries: int = 50

var entries: Array[Dictionary] = []


func log_entry(category: String, message: String, detail: Dictionary = {}) -> void:
	var entry := {"category": category, "message": message, "detail": detail}
	entries.append(entry)
	while entries.size() > max_entries:
		entries.pop_front()
	entry_logged.emit(entry)


func clear() -> void:
	entries.clear()


func count_in_category(category: String) -> int:
	var total := 0
	for entry: Dictionary in entries:
		if String(entry.get("category", "")) == category:
			total += 1
	return total


# -- Wiring helpers -------------------------------------------------------

func watch_weapon_authority(weapon_authority: Node) -> void:
	if weapon_authority == null:
		return
	weapon_authority.command_rejected.connect(func(outcome: Dictionary) -> void:
		log_entry(CATEGORY_REJECTED, "command rejected: code %d" % int(outcome.get("rejection", -1)), outcome))
	weapon_authority.state_corrected.connect(func(snapshots: Array) -> void:
		log_entry(CATEGORY_CORRECTED, "state corrected: %d snapshot(s)" % snapshots.size(), {"count": snapshots.size()}))


## `adapter_name` is a display label only ("inventory", "gas", ...) -- both
## optional adapters this change ships expose the identical
## `health_changed(ready: bool, diagnostic: String)` signal shape.
func watch_adapter(adapter: Node, adapter_name: String) -> void:
	if adapter == null or not adapter.has_signal("health_changed"):
		return
	adapter.health_changed.connect(func(ready: bool, diagnostic: String) -> void:
		log_entry(CATEGORY_ADAPTER_HEALTH, "%s %s: %s" % [adapter_name, "READY" if ready else "UNHEALTHY", diagnostic],
			{"ready": ready, "diagnostic": diagnostic}))


## Wires the (networked-play-only) resync/diagnostic signals a
## `WeaponNetworkBridge` client role exposes. A bridge is optional plumbing
## (design.md "Protocol and networking") -- most reference scenes in this
## change run offline and never call this.
func watch_network_bridge(bridge: Node) -> void:
	if bridge == null:
		return
	if bridge.has_signal("resync_needed"):
		bridge.resync_needed.connect(func(instance_id: String) -> void:
			log_entry(CATEGORY_RESYNC, "resync in progress: %s" % instance_id, {"instance_id": instance_id}))
	if bridge.has_signal("network_diagnostic"):
		bridge.network_diagnostic.connect(func(peer: int, status: Dictionary) -> void:
			log_entry(CATEGORY_NETWORK, "peer %d diagnostic: %s" % [peer, str(status)], status))


## Directly reports content-fingerprint incompatibility. Both fingerprints
## are canonical public values (`WeaponAuthority.content_fingerprint()`);
## comparing them is an ordinary game-owned check, exactly what a real
## `WeaponNetworkBridge` compatibility handshake does internally before ever
## admitting a peer's commands.
func report_content_incompatible(local_fingerprint: int, remote_fingerprint: int) -> void:
	log_entry(CATEGORY_CONTENT_INCOMPATIBLE,
		"content fingerprint mismatch: local=%d remote=%d" % [local_fingerprint, remote_fingerprint],
		{"local": local_fingerprint, "remote": remote_fingerprint})


## Verifies every native class this scene depends on is actually registered
## (a dedicated-server or content-mismatched export missing the GDExtension
## would otherwise fail confusingly deep inside a `.new()` call). Bounded,
## single pass, safe to call repeatedly. Returns true only if every class
## in `required_classes` is present.
func check_required_native_classes(required_classes: PackedStringArray) -> bool:
	var all_present := true
	for class_id in required_classes:
		if not ClassDB.class_exists(class_id):
			all_present = false
			log_entry(CATEGORY_MISSING_CLASS, "missing native class: %s" % class_id, {"class": class_id})
	return all_present
