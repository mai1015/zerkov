class_name WeaponInspectorPanel
extends Control

## Optional read-only inspector: effective MOA, recoil profile base values
## plus current anchors, accepted attachment loadout, and loaded ammunition
## profile -- entirely from CONFIRMED canonical data
## (`WeaponAuthority.snapshot()` / `effective_modifiers()` /
## `effective_recoil()` / `loaded_profile()`) plus the game's own retained
## sealed-content dictionaries (weapon-presentation spec.md "Weapon
## inspector displays mechanics": "those displayed values are derived from
## canonical data without becoming authority").
##
## KNOWN FAÇADE GAP: neither `WeaponAuthority` nor `WeaponDefinitionCatalog`
## expose a public getter to read sealed CONTENT back out (base
## `accuracy_moa_milli`, a recoil profile's kick/recovery magnitudes, or an
## attachment definition's modifier_ppm fields) -- only instance snapshots,
## aggregate `effective_modifiers()`/`effective_recoil()`, and
## count()/fingerprint() are queryable. See this change's final report. The
## game/inspector is therefore the catalog of record for declarative
## content here, exactly like every other `configure()` caller already must
## be (it authored these dictionaries itself); this panel never invents a
## value the game did not already supply, and never reads or displays
## predicted/speculative state.

var weapon_authority: Node
var instance_id := ""
var base_accuracy_moa_milli: int = 0
var base_recoil_profile: Dictionary = {}
var attachment_definitions: Dictionary = {} # attachment_id -> {accuracy_modifier_ppm, recoil_modifier_ppm, noise_modifier_ppm, ...}
var slot_labels: Dictionary = {} # slot_id -> human-readable label

var last_report: Dictionary = {}
## Bounded counter a headless check can assert against without a display.
var refresh_count := 0


func configure(p_weapon_authority: Node, p_instance_id: String,
		p_base_accuracy_moa_milli: int, p_base_recoil_profile: Dictionary,
		p_attachment_definitions: Dictionary, p_slot_labels: Dictionary) -> void:
	weapon_authority = p_weapon_authority
	instance_id = p_instance_id
	base_accuracy_moa_milli = p_base_accuracy_moa_milli
	base_recoil_profile = p_base_recoil_profile
	attachment_definitions = p_attachment_definitions
	slot_labels = p_slot_labels


## Rebuilds `last_report` from confirmed canonical data only. Call whenever
## the game wants a fresh inspector snapshot (e.g. every frame the panel is
## visible, or on `attachment_loadout_changed`/`recoil_anchor_changed`).
func refresh(current_tick: int) -> Dictionary:
	last_report = {}
	if weapon_authority == null or instance_id.is_empty():
		return last_report
	var state: Dictionary = weapon_authority.snapshot(instance_id)
	if state.is_empty():
		return last_report
	var modifiers: Dictionary = weapon_authority.effective_modifiers(instance_id)
	var recoil: Dictionary = weapon_authority.effective_recoil(instance_id, current_tick)
	var loaded_profile: Dictionary = weapon_authority.loaded_profile(instance_id)

	var accuracy_multiplier_ppm := int(modifiers.get("accuracy_multiplier_ppm", 1_000_000))
	var effective_moa_milli := int(round(
		float(base_accuracy_moa_milli) * float(accuracy_multiplier_ppm) / 1_000_000.0))

	var loadout_report: Array = []
	for entry: Dictionary in (state.get("attachment_loadout", []) as Array):
		var attachment_id := String(entry.get("attachment_id", ""))
		var definition: Dictionary = attachment_definitions.get(attachment_id, {})
		var slot_id := String(entry.get("slot_id", ""))
		loadout_report.append({
			"slot_id": slot_id,
			"slot_label": String(slot_labels.get(slot_id, slot_id)),
			"attachment_id": attachment_id,
			"attachment_version": int(entry.get("attachment_version", 0)),
			"accuracy_modifier_ppm": int(definition.get("accuracy_modifier_ppm", 1_000_000)),
			"recoil_modifier_ppm": int(definition.get("recoil_modifier_ppm", 1_000_000)),
			"noise_modifier_ppm": int(definition.get("noise_modifier_ppm", 1_000_000)),
		})

	last_report = {
		"instance_id": instance_id,
		"revision": int(state.get("revision", 0)),
		"effective_moa_milli": effective_moa_milli,
		"base_accuracy_moa_milli": base_accuracy_moa_milli,
		"accuracy_multiplier_ppm": accuracy_multiplier_ppm,
		"recoil_multiplier_ppm": int(modifiers.get("recoil_multiplier_ppm", 1_000_000)),
		"noise_multiplier_ppm": int(modifiers.get("noise_multiplier_ppm", 1_000_000)),
		"reload_duration_multiplier_ppm": int(modifiers.get("reload_duration_multiplier_ppm", 1_000_000)),
		"cadence_multiplier_ppm": int(modifiers.get("cadence_multiplier_ppm", 1_000_000)),
		"recoil_profile_base": base_recoil_profile,
		"recoil_anchor_vertical_nrad": int(state.get("recoil_vertical_offset_nrad", 0)),
		"recoil_anchor_horizontal_nrad": int(state.get("recoil_horizontal_offset_nrad", 0)),
		"recoil_anchor_tick": int(state.get("recoil_anchor_tick", 0)),
		"recoil_current_vertical_nrad": int(recoil.get("vertical_offset_nrad", 0)),
		"recoil_current_horizontal_nrad": int(recoil.get("horizontal_offset_nrad", 0)),
		"attachment_loadout": loadout_report,
		"loaded_profile_id": String(loaded_profile.get("id", "")),
		"loaded_profile_version": int(loaded_profile.get("version", 0)),
		"loaded_profile_present": bool(loaded_profile.get("has_profile", false)),
		"loaded_rounds": int(state.get("loaded_rounds", 0)),
		"phase": String(state.get("phase", "ready")),
	}
	refresh_count += 1
	return last_report
