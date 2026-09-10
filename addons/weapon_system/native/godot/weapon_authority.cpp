#include "godot/weapon_authority.h"

#include "core/wpn_numerics.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <cstdint>
#include <initializer_list>

namespace godot {

namespace {

std::string to_std(const String &p_value) {
	return p_value.utf8().get_data();
}

std::uint64_t nonnegative_u64(int64_t p_value) {
	return p_value < 0 ? 0 : std::uint64_t(p_value);
}

Dictionary error_dictionary(const wpn::Status &p_status, bool p_command = false) {
	Dictionary result;
	result[p_command ? "accepted" : "ok"] = false;
	Dictionary status;
	status["ok"] = p_status.ok();
	status["code"] = int(p_status.code);
	status["diagnostic"] = int(p_status.diagnostic);
	status["detail"] = int64_t(p_status.detail);
	result["status"] = status;
	return result;
}

// Strict conversion validation for the new checked Dictionary/value APIs
// (weapon-runtime façade contract: "reject unknown keys ... with actionable
// diagnostics"). Returns true (and sets r_key) for the FIRST key in
// p_dict absent from p_allowed; stable, deterministic iteration order isn't
// required here since the caller only needs ONE actionable offender.
bool find_unknown_key(const Dictionary &p_dict, std::initializer_list<const char *> p_allowed, String &r_key) {
	const Array keys = p_dict.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const String key = String(keys[i]);
		bool known = false;
		for (const char *allowed : p_allowed) {
			if (key == String(allowed)) {
				known = true;
				break;
			}
		}
		if (!known) {
			r_key = key;
			return true;
		}
	}
	return false;
}

// Translates a raw `wpn::AttachmentSlotKind` BIT value (1, 2, 4, or 8 --
// the SAME vocabulary an attachment's `compatible_slot_kinds_mask` uses) into
// the core enum. Returns false for anything else, including 0 or a
// combination of bits (a weapon attachment slot names exactly ONE kind).
bool slot_kind_from_bit(int p_bit, wpn::AttachmentSlotKind &r_kind) {
	switch (p_bit) {
		case 1:
			r_kind = wpn::AttachmentSlotKind::OPTIC;
			return true;
		case 2:
			r_kind = wpn::AttachmentSlotKind::MUZZLE;
			return true;
		case 4:
			r_kind = wpn::AttachmentSlotKind::STOCK;
			return true;
		case 8:
			r_kind = wpn::AttachmentSlotKind::GRIP;
			return true;
		default:
			return false;
	}
}

// Strictly validates and converts `p_slots` (an Array of
// {slot_id: String, slot_kind: int}) into `r_slots`, failing closed with an
// actionable field/message on the FIRST unknown key or malformed
// `slot_kind` rather than silently defaulting it.
wpn::Status parse_weapon_attachment_slots(const Array &p_slots, std::vector<wpn::WeaponAttachmentSlot> &r_slots, String &r_field, String &r_message) {
	r_slots.clear();
	r_slots.reserve(p_slots.size());
	for (int i = 0; i < p_slots.size(); ++i) {
		const Dictionary slot_value = p_slots[i];
		String unknown_key;
		if (find_unknown_key(slot_value, { "slot_id", "slot_kind" }, unknown_key)) {
			r_field = vformat("attachment_slots[%d].%s", i, unknown_key);
			r_message = vformat("attachment_slots[%d] has unknown key '%s'.", i, unknown_key);
			return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM);
		}
		const int bit = int(int64_t(slot_value.get("slot_kind", int64_t(0))));
		wpn::AttachmentSlotKind kind;
		if (!slot_kind_from_bit(bit, kind)) {
			r_field = vformat("attachment_slots[%d].slot_kind", i);
			r_message = vformat("attachment_slots[%d].slot_kind %d must be one of 1 (Optic), 2 (Muzzle), 4 (Stock), 8 (Grip).", i, bit);
			return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM, std::uint64_t(bit < 0 ? 0 : bit));
		}
		wpn::WeaponAttachmentSlot slot;
		slot.slot_id = to_std(String(slot_value.get("slot_id", String())));
		slot.slot_kind = kind;
		r_slots.push_back(slot);
	}
	return wpn::ok_status();
}

} // namespace

Dictionary WeaponAuthority::status_dict(const wpn::Status &p_status) {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["code"] = int(p_status.code);
	result["diagnostic"] = int(p_status.diagnostic);
	result["detail"] = int64_t(p_status.detail);
	return result;
}

wpn::FixedVec2 WeaponAuthority::fixed_vec_from_dict(const Dictionary &p_value) {
	return {
		int64_t(p_value.get("x", int64_t(0))),
		int64_t(p_value.get("y", int64_t(0))),
	};
}

wpn::AuthorityContext WeaponAuthority::authority_from_dict(const Dictionary &p_value) {
	wpn::AuthorityContext result;
	result.actor_live = bool(p_value.get("actor_live", false));
	result.weapon_equipped = bool(p_value.get("weapon_equipped", false));
	result.weapon_usable = bool(p_value.get("weapon_usable", false));
	result.authoritative_origin = fixed_vec_from_dict(p_value.get("authoritative_origin", Dictionary()));
	result.authoritative_aim = fixed_vec_from_dict(p_value.get("authoritative_aim", Dictionary()));
	result.spread_modifier_ppm = int64_t(p_value.get("spread_modifier_ppm", int64_t(1000000)));
	result.damage_modifier_ppm = int64_t(p_value.get("damage_modifier_ppm", int64_t(1000000)));
	result.range_modifier_ppm = int64_t(p_value.get("range_modifier_ppm", int64_t(1000000)));
	result.noise_modifier_ppm = int64_t(p_value.get("noise_modifier_ppm", int64_t(1000000)));
	result.recoil_modifier_ppm = int64_t(p_value.get("recoil_modifier_ppm", int64_t(1000000)));
	return result;
}

// {has_profile, id, version}. `has_profile` false means id/version are not
// meaningful (an absent optional, never a zero-value profile).
Dictionary WeaponAuthority::profile_dict(const std::optional<wpn::BallisticProfileIdentity> &p_value) {
	Dictionary result;
	result["has_profile"] = p_value.has_value();
	result["id"] = p_value.has_value() ? String(p_value->id.c_str()) : String();
	result["version"] = p_value.has_value() ? int(p_value->version) : 0;
	return result;
}

Dictionary WeaponAuthority::snapshot_dict(const wpn::WeaponSnapshot &p_snapshot) {
	Dictionary result;
	result["instance_id"] = String(p_snapshot.instance_id.c_str());
	result["definition_id"] = String(p_snapshot.definition_id.c_str());
	result["definition_version"] = int(p_snapshot.definition_version);
	result["revision"] = int64_t(p_snapshot.revision);
	result["loaded_rounds"] = int(p_snapshot.loaded_rounds);
	result["loaded_profile"] = profile_dict(p_snapshot.loaded_profile);
	result["phase"] = p_snapshot.phase == wpn::WeaponPhase::READY ? "ready" : "reloading";
	result["has_last_fire_tick"] = p_snapshot.has_last_fire_tick;
	result["last_fire_tick"] = int64_t(p_snapshot.last_fire_tick);
	result["has_last_command_sequence"] = p_snapshot.has_last_command_sequence;
	result["last_command_sequence"] = int64_t(p_snapshot.last_command_sequence);
	if (p_snapshot.reload.has_value()) {
		Dictionary reload;
		reload["reservation_id"] = String(p_snapshot.reload->reservation_id.c_str());
		reload["reserved_rounds"] = int(p_snapshot.reload->reserved_rounds);
		reload["start_tick"] = int64_t(p_snapshot.reload->start_tick);
		reload["due_tick"] = int64_t(p_snapshot.reload->due_tick);
		reload["reserved_profile"] = profile_dict(std::optional<wpn::BallisticProfileIdentity>(p_snapshot.reload->reserved_profile));
		result["reload"] = reload;
	} else {
		result["reload"] = Dictionary();
	}

	// --- Authority scope/epoch/tick command envelope (tasks.md 4.13) ---
	result["authority_scope"] = String(p_snapshot.authority_scope.c_str());
	result["authority_epoch"] = int64_t(p_snapshot.authority_epoch);
	result["authority_tick_floor"] = int64_t(p_snapshot.authority_tick_floor);
	result["admitted_sequence_high_watermark"] = int64_t(p_snapshot.admitted_sequence_high_watermark);
	result["tick_unhealthy"] = p_snapshot.tick_unhealthy;

	// --- Deterministic recoil kick/recovery anchor (tasks.md 4.10). No
	// per-tick canonical recovery value is published here on purpose --
	// presenters derive recovery from this anchor + the current tick via
	// `effective_recoil()` below. ---
	result["recoil_vertical_offset_nrad"] = int64_t(p_snapshot.recoil_vertical_offset_nrad);
	result["recoil_horizontal_offset_nrad"] = int64_t(p_snapshot.recoil_horizontal_offset_nrad);
	result["recoil_anchor_tick"] = int64_t(p_snapshot.recoil_anchor_tick);

	// --- Flat attachment loadout (tasks.md 4.11) ---
	Array attachment_loadout;
	for (const wpn::AttachmentLoadoutEntry &entry : p_snapshot.attachment_loadout) {
		Dictionary entry_dict;
		entry_dict["slot_id"] = String(entry.slot_id.c_str());
		entry_dict["attachment_id"] = String(entry.attachment_id.c_str());
		entry_dict["attachment_version"] = int(entry.attachment_version);
		attachment_loadout.append(entry_dict);
	}
	result["attachment_loadout"] = attachment_loadout;

	return result;
}

Dictionary WeaponAuthority::completion_dict(const wpn::ReloadCompletion &p_completion) {
	Dictionary result;
	result["instance_id"] = String(p_completion.instance_id.c_str());
	result["reservation_id"] = String(p_completion.reservation_id.c_str());
	result["added_rounds"] = int(p_completion.added_rounds);
	result["revision"] = int64_t(p_completion.revision);
	result["loaded_rounds"] = int(p_completion.loaded_rounds);
	result["profile"] = profile_dict(p_completion.profile);
	return result;
}

Dictionary WeaponAuthority::tombstone_dict(const wpn::WeaponTombstone &p_tombstone) {
	Dictionary result;
	result["found"] = true;
	result["instance_id"] = String(p_tombstone.instance_id.c_str());
	result["authority_scope"] = String(p_tombstone.authority_scope.c_str());
	result["authority_epoch"] = int64_t(p_tombstone.authority_epoch);
	result["revision"] = int64_t(p_tombstone.revision);
	return result;
}

Dictionary WeaponAuthority::outcome_dict(const wpn::CommandOutcome &p_outcome) {
	Dictionary result;
	result["accepted"] = p_outcome.accepted;
	result["replayed"] = p_outcome.replayed;
	// `rejection == DUPLICATE_OUTCOME_EVICTED` (weapon-runtime spec, "Canonical
	// Revision and Authority-Tick Semantics") surfaces here exactly like every
	// other rejection reason -- both this int and `status.diagnostic` (also
	// DUPLICATE_OUTCOME_EVICTED) identify it; no separate façade plumbing is
	// needed beyond exposing the outcome faithfully.
	result["rejection"] = int(p_outcome.rejection);
	result["status"] = status_dict(p_outcome.status);
	result["revision"] = int64_t(p_outcome.revision);
	result["loaded_rounds"] = int(p_outcome.loaded_rounds);
	result["reservation_to_release"] = p_outcome.reservation_to_release.has_value() ?
			String(p_outcome.reservation_to_release->c_str()) :
			String();
	if (p_outcome.shot.has_value()) {
		const wpn::CommittedShot &shot = *p_outcome.shot;
		Dictionary value;
		value["consequence_id"] = String(shot.consequence_id.c_str());
		value["instance_id"] = String(shot.instance_id.c_str());
		value["weapon_id"] = String(shot.weapon_id.c_str());
		value["weapon_version"] = int(shot.weapon_version);
		value["tick"] = int64_t(shot.tick);
		Dictionary origin;
		origin["x"] = int64_t(shot.origin.x);
		origin["y"] = int64_t(shot.origin.y);
		Dictionary direction;
		direction["x"] = int64_t(shot.direction.x);
		direction["y"] = int64_t(shot.direction.y);
		value["origin"] = origin;
		value["direction"] = direction;
		value["damage_milliunits"] = int64_t(shot.damage_milliunits);
		value["range_milliunits"] = int64_t(shot.range_milliunits);
		value["noise_radius_milliunits"] = int64_t(shot.noise_radius_milliunits);
		value["consumed_profile"] = profile_dict(std::optional<wpn::BallisticProfileIdentity>(shot.consumed_profile));
		result["shot"] = value;
	} else {
		result["shot"] = Dictionary();
	}
	return result;
}

Dictionary WeaponAuthority::configure(
		const Array &p_shot_profiles,
		const Array &p_weapons,
		const Array &p_recoil_profiles,
		const Array &p_attachments,
		const Array &p_ammo_profiles) {
	std::unique_ptr<wpn::WeaponCatalog> candidate = std::make_unique<wpn::WeaponCatalog>();
	wpn::Status status;

	for (int i = 0; i < p_shot_profiles.size(); ++i) {
		const Dictionary value = p_shot_profiles[i];
		wpn::HitscanShotProfile profile;
		profile.id = to_std(String(value.get("id", String())));
		profile.version = std::uint16_t(int(value.get("version", 1)));
		profile.damage_milliunits = int64_t(value.get("damage_milliunits", int64_t(0)));
		profile.range_milliunits = int64_t(value.get("range_milliunits", int64_t(0)));
		profile.spread_microradians = int64_t(value.get("spread_microradians", int64_t(0)));
		profile.aim_tolerance_microradians = int64_t(value.get("aim_tolerance_microradians", int64_t(0)));
		profile.origin_tolerance_milliunits = int64_t(value.get("origin_tolerance_milliunits", int64_t(0)));
		status = candidate->add_shot_profile(profile);
		if (!status.ok()) {
			Dictionary err = error_dictionary(status);
			err["field"] = vformat("shot_profiles[%d]", i);
			return err;
		}
	}

	for (int i = 0; i < p_recoil_profiles.size(); ++i) {
		const Dictionary value = p_recoil_profiles[i];
		String unknown_key;
		if (find_unknown_key(value, { "id", "version", "vertical_kick_nrad", "horizontal_kick_min_nrad",
									 "horizontal_kick_max_nrad", "recovery_per_tick_nrad", "max_vertical_offset_nrad",
									 "max_horizontal_offset_nrad" },
					unknown_key)) {
			Dictionary err = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM));
			err["field"] = vformat("recoil_profiles[%d].%s", i, unknown_key);
			err["message"] = vformat("recoil_profiles[%d] has unknown key '%s'.", i, unknown_key);
			return err;
		}
		wpn::RecoilProfile profile;
		profile.id = to_std(String(value.get("id", String())));
		profile.version = std::uint16_t(int(value.get("version", 1)));
		profile.vertical_kick_nrad = int64_t(value.get("vertical_kick_nrad", int64_t(0)));
		profile.horizontal_kick_min_nrad = int64_t(value.get("horizontal_kick_min_nrad", int64_t(0)));
		profile.horizontal_kick_max_nrad = int64_t(value.get("horizontal_kick_max_nrad", int64_t(0)));
		profile.recovery_per_tick_nrad = int64_t(value.get("recovery_per_tick_nrad", int64_t(0)));
		profile.max_vertical_offset_nrad = int64_t(value.get("max_vertical_offset_nrad", int64_t(0)));
		profile.max_horizontal_offset_nrad = int64_t(value.get("max_horizontal_offset_nrad", int64_t(0)));
		status = candidate->add_recoil_profile(profile);
		if (!status.ok()) {
			Dictionary err = error_dictionary(status);
			err["field"] = vformat("recoil_profiles[%d]", i);
			return err;
		}
	}

	for (int i = 0; i < p_attachments.size(); ++i) {
		const Dictionary value = p_attachments[i];
		String unknown_key;
		if (find_unknown_key(value, { "id", "version", "compatible_slot_kinds_mask", "compatible_tags",
									 "accuracy_modifier_ppm", "recoil_modifier_ppm", "noise_modifier_ppm",
									 "reload_duration_modifier_ppm", "cadence_modifier_ppm", "provided_slot_count" },
					unknown_key)) {
			Dictionary err = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM));
			err["field"] = vformat("attachments[%d].%s", i, unknown_key);
			err["message"] = vformat("attachments[%d] has unknown key '%s'.", i, unknown_key);
			return err;
		}
		wpn::AttachmentDefinition attachment;
		attachment.id = to_std(String(value.get("id", String())));
		attachment.version = std::uint16_t(int(value.get("version", 1)));
		attachment.compatible_slot_kinds_mask = std::uint32_t(int64_t(value.get("compatible_slot_kinds_mask", int64_t(0))));
		const PackedStringArray tags = value.get("compatible_tags", PackedStringArray());
		attachment.compatible_tags.reserve(tags.size());
		for (int t = 0; t < tags.size(); ++t) {
			attachment.compatible_tags.push_back(to_std(tags[t]));
		}
		attachment.accuracy_modifier_ppm = int64_t(value.get("accuracy_modifier_ppm", int64_t(0)));
		attachment.recoil_modifier_ppm = int64_t(value.get("recoil_modifier_ppm", int64_t(0)));
		attachment.noise_modifier_ppm = int64_t(value.get("noise_modifier_ppm", int64_t(0)));
		attachment.reload_duration_modifier_ppm = int64_t(value.get("reload_duration_modifier_ppm", int64_t(0)));
		attachment.cadence_modifier_ppm = int64_t(value.get("cadence_modifier_ppm", int64_t(0)));
		attachment.provided_slot_count = std::uint32_t(int64_t(value.get("provided_slot_count", int64_t(0))));
		status = candidate->add_attachment(attachment);
		if (!status.ok()) {
			Dictionary err = error_dictionary(status);
			err["field"] = vformat("attachments[%d]", i);
			return err;
		}
	}

	for (int i = 0; i < p_ammo_profiles.size(); ++i) {
		const Dictionary value = p_ammo_profiles[i];
		String unknown_key;
		if (find_unknown_key(value, { "id", "version", "ammunition_trait" }, unknown_key)) {
			Dictionary err = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM));
			err["field"] = vformat("ammo_profiles[%d].%s", i, unknown_key);
			err["message"] = vformat("ammo_profiles[%d] has unknown key '%s'.", i, unknown_key);
			return err;
		}
		wpn::AmmunitionBallisticProfile profile;
		profile.id = to_std(String(value.get("id", String())));
		profile.version = std::uint16_t(int(value.get("version", 1)));
		profile.ammunition_trait = to_std(String(value.get("ammunition_trait", String())));
		status = candidate->add_ammo_profile(profile);
		if (!status.ok()) {
			Dictionary err = error_dictionary(status);
			err["field"] = vformat("ammo_profiles[%d]", i);
			return err;
		}
	}

	for (int i = 0; i < p_weapons.size(); ++i) {
		const Dictionary value = p_weapons[i];
		String unknown_key;
		if (find_unknown_key(value, { "id", "version", "shot_profile_id", "shot_profile_version", "ammunition_trait",
									 "capacity", "cadence_ticks", "reload_ticks", "noise_radius_milliunits",
									 "accuracy_moa_milli", "recoil_profile_id", "recoil_profile_version", "attachment_slots" },
					unknown_key)) {
			Dictionary err = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM));
			err["field"] = vformat("weapons[%d].%s", i, unknown_key);
			err["message"] = vformat("weapons[%d] has unknown key '%s'.", i, unknown_key);
			return err;
		}
		wpn::WeaponDefinition weapon;
		weapon.id = to_std(String(value.get("id", String())));
		weapon.version = std::uint16_t(int(value.get("version", 1)));
		weapon.shot_profile_id = to_std(String(value.get("shot_profile_id", String())));
		weapon.shot_profile_version = std::uint16_t(int(value.get("shot_profile_version", 1)));
		weapon.ammunition_trait = to_std(String(value.get("ammunition_trait", String())));
		weapon.capacity = std::uint32_t(int64_t(value.get("capacity", int64_t(0))));
		weapon.cadence_ticks = std::uint32_t(int64_t(value.get("cadence_ticks", int64_t(0))));
		weapon.reload_ticks = std::uint32_t(int64_t(value.get("reload_ticks", int64_t(0))));
		weapon.noise_radius_milliunits = int64_t(value.get("noise_radius_milliunits", int64_t(0)));
		// Full group diameter in thousandths of one MOA (weapon-authoring
		// spec.md "Unambiguous Integer MOA Authoring"); see
		// WeaponDefinitionResource's header comment for the exact conversion.
		weapon.accuracy_moa_milli = int64_t(value.get("accuracy_moa_milli", int64_t(0)));
		// REQUIRED reference, exactly like shot_profile_id (this is the
		// regression fix: the core now rejects an empty recoil_profile_id).
		weapon.recoil_profile_id = to_std(String(value.get("recoil_profile_id", String())));
		weapon.recoil_profile_version = std::uint16_t(int(value.get("recoil_profile_version", 1)));

		std::vector<wpn::WeaponAttachmentSlot> attachment_slots;
		{
			const Array attachment_slots_value = value.get("attachment_slots", Array());
			String field, message;
			const wpn::Status slot_status = parse_weapon_attachment_slots(attachment_slots_value, attachment_slots, field, message);
			if (!slot_status.ok()) {
				Dictionary err = error_dictionary(slot_status);
				err["field"] = vformat("weapons[%d].%s", i, field);
				err["message"] = message;
				return err;
			}
		}
		weapon.attachment_slots = std::move(attachment_slots);

		status = candidate->add_weapon(weapon);
		if (!status.ok()) {
			Dictionary err = error_dictionary(status);
			err["field"] = vformat("weapons[%d]", i);
			return err;
		}
	}

	status = candidate->seal();
	if (!status.ok()) {
		return error_dictionary(status);
	}
	catalog = std::move(candidate);
	runtime = std::make_unique<wpn::WeaponRuntime>(*catalog);
	Dictionary result;
	result["ok"] = true;
	result["status"] = status_dict(status);
	result["fingerprint"] = int64_t(catalog->fingerprint());
	return result;
}

int64_t WeaponAuthority::content_fingerprint() const {
	return catalog == nullptr ? 0 : int64_t(catalog->fingerprint());
}

Dictionary WeaponAuthority::create_weapon(
		const String &p_instance_id,
		const String &p_definition_id,
		int p_definition_version,
		int p_loaded_rounds,
		const Dictionary &p_profile,
		const String &p_authority_scope,
		int64_t p_authority_epoch) {
	if (runtime == nullptr) {
		Dictionary result;
		result["ok"] = false;
		result["status"] = status_dict(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED));
		return result;
	}
	std::optional<wpn::BallisticProfileIdentity> profile;
	if (!p_profile.is_empty()) {
		String unknown_key;
		if (find_unknown_key(p_profile, { "id", "version" }, unknown_key)) {
			Dictionary result;
			result["ok"] = false;
			result["status"] = status_dict(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM));
			result["field"] = vformat("profile.%s", unknown_key);
			result["message"] = vformat("profile has unknown key '%s'.", unknown_key);
			return result;
		}
		wpn::BallisticProfileIdentity value;
		value.id = to_std(String(p_profile.get("id", String())));
		value.version = std::uint16_t(int(p_profile.get("version", 1)));
		profile = value;
	}
	const wpn::Status status = runtime->create_instance(
			to_std(p_instance_id),
			to_std(p_definition_id),
			std::uint16_t(p_definition_version),
			std::uint32_t(p_loaded_rounds < 0 ? 0 : p_loaded_rounds),
			profile,
			to_std(p_authority_scope),
			nonnegative_u64(p_authority_epoch));
	Dictionary result;
	result["ok"] = status.ok();
	result["status"] = status_dict(status);
	return result;
}

Dictionary WeaponAuthority::remove_weapon(const String &p_instance_id) {
	std::optional<std::string> reservation;
	const wpn::Status status = runtime == nullptr ?
			wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED) :
			runtime->remove_instance(to_std(p_instance_id), reservation);
	Dictionary result;
	result["ok"] = status.ok();
	result["status"] = status_dict(status);
	result["reservation_to_release"] = reservation.has_value() ? String(reservation->c_str()) : String();
	return result;
}

Dictionary WeaponAuthority::snapshot(const String &p_instance_id) const {
	if (runtime == nullptr) {
		return Dictionary();
	}
	const wpn::WeaponSnapshot *value = runtime->find_instance(to_std(p_instance_id));
	return value == nullptr ? Dictionary() : snapshot_dict(*value);
}

Array WeaponAuthority::snapshots() const {
	Array result;
	if (runtime != nullptr) {
		for (const wpn::WeaponSnapshot &value : runtime->snapshots()) {
			result.append(snapshot_dict(value));
		}
	}
	return result;
}

Dictionary WeaponAuthority::replace_snapshots(const Array &p_snapshots) {
	if (runtime == nullptr) {
		return error_dictionary(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED));
	}
	std::vector<wpn::WeaponSnapshot> values;
	values.reserve(p_snapshots.size());
	for (int i = 0; i < p_snapshots.size(); ++i) {
		const Dictionary input = p_snapshots[i];
		wpn::WeaponSnapshot value;
		value.instance_id = to_std(String(input.get("instance_id", String())));
		value.definition_id = to_std(String(input.get("definition_id", String())));
		value.definition_version = std::uint16_t(int(input.get("definition_version", 1)));
		value.revision = nonnegative_u64(int64_t(input.get("revision", int64_t(0))));
		value.loaded_rounds = std::uint32_t(nonnegative_u64(int64_t(input.get("loaded_rounds", int64_t(0)))));
		const Dictionary loaded_profile_value = input.get("loaded_profile", Dictionary());
		if (bool(loaded_profile_value.get("has_profile", false))) {
			wpn::BallisticProfileIdentity profile;
			profile.id = to_std(String(loaded_profile_value.get("id", String())));
			profile.version = std::uint16_t(int(loaded_profile_value.get("version", 1)));
			value.loaded_profile = profile;
		}
		value.has_last_fire_tick = bool(input.get("has_last_fire_tick", false));
		value.last_fire_tick = nonnegative_u64(int64_t(input.get("last_fire_tick", int64_t(0))));
		value.has_last_command_sequence = bool(input.get("has_last_command_sequence", false));
		value.last_command_sequence = nonnegative_u64(int64_t(input.get("last_command_sequence", int64_t(0))));
		const String phase = String(input.get("phase", "ready"));
		value.phase = phase == "reloading" ? wpn::WeaponPhase::RELOADING : wpn::WeaponPhase::READY;
		const Dictionary reload = input.get("reload", Dictionary());
		if (value.phase == wpn::WeaponPhase::RELOADING && !reload.is_empty()) {
			wpn::ReloadState reload_state;
			reload_state.reservation_id = to_std(String(reload.get("reservation_id", String())));
			reload_state.reserved_rounds = std::uint32_t(nonnegative_u64(int64_t(reload.get("reserved_rounds", int64_t(0)))));
			reload_state.start_tick = nonnegative_u64(int64_t(reload.get("start_tick", int64_t(0))));
			reload_state.due_tick = nonnegative_u64(int64_t(reload.get("due_tick", int64_t(0))));
			const Dictionary reserved_profile_value = reload.get("reserved_profile", Dictionary());
			reload_state.reserved_profile.id = to_std(String(reserved_profile_value.get("id", String())));
			reload_state.reserved_profile.version = std::uint16_t(int(reserved_profile_value.get("version", 1)));
			value.reload = reload_state;
		}
		// --- Authority scope/epoch/tick command envelope + recoil anchor +
		// flat attachment loadout (tasks.md 4.10-4.13): round-tripped here so
		// a trusted replacement snapshot can restore every new field this
		// task's snapshot_dict() now publishes, not just the pre-existing
		// mechanical ones. ---
		value.authority_scope = to_std(String(input.get("authority_scope", String())));
		value.authority_epoch = nonnegative_u64(int64_t(input.get("authority_epoch", int64_t(0))));
		value.authority_tick_floor = nonnegative_u64(int64_t(input.get("authority_tick_floor", int64_t(0))));
		value.admitted_sequence_high_watermark = nonnegative_u64(int64_t(input.get("admitted_sequence_high_watermark", int64_t(0))));
		value.tick_unhealthy = bool(input.get("tick_unhealthy", false));
		value.recoil_vertical_offset_nrad = int64_t(input.get("recoil_vertical_offset_nrad", int64_t(0)));
		value.recoil_horizontal_offset_nrad = int64_t(input.get("recoil_horizontal_offset_nrad", int64_t(0)));
		value.recoil_anchor_tick = nonnegative_u64(int64_t(input.get("recoil_anchor_tick", int64_t(0))));
		const Array attachment_loadout = input.get("attachment_loadout", Array());
		value.attachment_loadout.reserve(attachment_loadout.size());
		for (int a = 0; a < attachment_loadout.size(); ++a) {
			const Dictionary entry_value = attachment_loadout[a];
			wpn::AttachmentLoadoutEntry entry;
			entry.slot_id = to_std(String(entry_value.get("slot_id", String())));
			entry.attachment_id = to_std(String(entry_value.get("attachment_id", String())));
			entry.attachment_version = std::uint16_t(int(entry_value.get("attachment_version", 1)));
			value.attachment_loadout.push_back(entry);
		}
		values.push_back(std::move(value));
	}
	const wpn::Status status = runtime->replace_from_snapshots(values);
	Dictionary result;
	result["ok"] = status.ok();
	result["status"] = status_dict(status);
	if (status.ok()) {
		emit_signal("state_corrected", snapshots());
	}
	return result;
}

wpn::CommandOutcome WeaponAuthority::fire_native(const wpn::FireCommand &p_command, const wpn::AuthorityContext &p_authority) {
	if (runtime == nullptr) {
		wpn::CommandOutcome outcome;
		outcome.status = wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED);
		return outcome;
	}
	const wpn::CommandOutcome outcome = runtime->fire(p_command, p_authority);
	if (outcome.accepted) {
		emit_signal("shot_committed", outcome_dict(outcome));
		// New transition the pre-existing signal set lacks (weapon-runtime
		// façade contract: "recoil anchor changed"): a committed shot always
		// re-anchors both recoil axes (native/core/wpn_runtime.cpp's fire()).
		const wpn::WeaponSnapshot *state = runtime->find_instance(p_command.instance_id);
		if (state != nullptr) {
			Dictionary anchor;
			anchor["instance_id"] = String(state->instance_id.c_str());
			anchor["revision"] = int64_t(state->revision);
			anchor["vertical_offset_nrad"] = int64_t(state->recoil_vertical_offset_nrad);
			anchor["horizontal_offset_nrad"] = int64_t(state->recoil_horizontal_offset_nrad);
			anchor["anchor_tick"] = int64_t(state->recoil_anchor_tick);
			emit_signal("recoil_anchor_changed", anchor);
		}
	} else {
		emit_signal("command_rejected", outcome_dict(outcome));
	}
	return outcome;
}

Dictionary WeaponAuthority::fire(const Dictionary &p_command, const Dictionary &p_authority) {
	if (runtime == nullptr) {
		return error_dictionary(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED), true);
	}
	wpn::FireCommand command;
	command.command_id = to_std(String(p_command.get("command_id", String())));
	command.sequence = nonnegative_u64(int64_t(p_command.get("sequence", int64_t(0))));
	command.instance_id = to_std(String(p_command.get("instance_id", String())));
	command.expected_revision = nonnegative_u64(int64_t(p_command.get("expected_revision", int64_t(0))));
	command.tick = nonnegative_u64(int64_t(p_command.get("tick", int64_t(0))));
	command.authority_scope = to_std(String(p_command.get("authority_scope", String())));
	command.authority_epoch = nonnegative_u64(int64_t(p_command.get("authority_epoch", int64_t(0))));
	command.claimed_origin = fixed_vec_from_dict(p_command.get("claimed_origin", Dictionary()));
	command.claimed_aim = fixed_vec_from_dict(p_command.get("claimed_aim", Dictionary()));
	command.spread_seed = nonnegative_u64(int64_t(p_command.get("spread_seed", int64_t(0))));
	return outcome_dict(fire_native(command, authority_from_dict(p_authority)));
}

Dictionary WeaponAuthority::begin_reload(const Dictionary &p_command) {
	if (runtime == nullptr) {
		return error_dictionary(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED), true);
	}
	const Dictionary profile_value = p_command.get("profile", Dictionary());
	String unknown_key;
	if (find_unknown_key(profile_value, { "id", "version" }, unknown_key)) {
		Dictionary result = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM), true);
		result["field"] = vformat("profile.%s", unknown_key);
		result["message"] = vformat("profile has unknown key '%s'.", unknown_key);
		return result;
	}
	wpn::BeginReloadCommand command;
	command.command_id = to_std(String(p_command.get("command_id", String())));
	command.sequence = nonnegative_u64(int64_t(p_command.get("sequence", int64_t(0))));
	command.instance_id = to_std(String(p_command.get("instance_id", String())));
	command.expected_revision = nonnegative_u64(int64_t(p_command.get("expected_revision", int64_t(0))));
	command.tick = nonnegative_u64(int64_t(p_command.get("tick", int64_t(0))));
	command.authority_scope = to_std(String(p_command.get("authority_scope", String())));
	command.authority_epoch = nonnegative_u64(int64_t(p_command.get("authority_epoch", int64_t(0))));
	command.reservation_id = to_std(String(p_command.get("reservation_id", String())));
	command.reserved_rounds = std::uint32_t(nonnegative_u64(int64_t(p_command.get("reserved_rounds", int64_t(0)))));
	// REQUIRED exact ballistic-profile identity this reservation carries
	// (tasks.md 4.12; this is the second half of the "known regression" this
	// task fixes -- begin_reload() with a missing/unknown profile now fails
	// closed with PROFILE_UNKNOWN_REFERENCE rather than defaulting to a
	// meaningless empty id/version 1).
	command.profile.id = to_std(String(profile_value.get("id", String())));
	command.profile.version = std::uint16_t(int(profile_value.get("version", 1)));
	const wpn::CommandOutcome outcome = runtime->begin_reload(command);
	const Dictionary result = outcome_dict(outcome);
	emit_signal(outcome.accepted ? "reload_started" : "command_rejected", result);
	return result;
}

Dictionary WeaponAuthority::cancel_reload(const Dictionary &p_command) {
	if (runtime == nullptr) {
		return error_dictionary(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED), true);
	}
	wpn::CancelReloadCommand command;
	command.command_id = to_std(String(p_command.get("command_id", String())));
	command.sequence = nonnegative_u64(int64_t(p_command.get("sequence", int64_t(0))));
	command.instance_id = to_std(String(p_command.get("instance_id", String())));
	command.expected_revision = nonnegative_u64(int64_t(p_command.get("expected_revision", int64_t(0))));
	command.tick = nonnegative_u64(int64_t(p_command.get("tick", int64_t(0))));
	command.authority_scope = to_std(String(p_command.get("authority_scope", String())));
	command.authority_epoch = nonnegative_u64(int64_t(p_command.get("authority_epoch", int64_t(0))));
	const wpn::CommandOutcome outcome = runtime->cancel_reload(command);
	const Dictionary result = outcome_dict(outcome);
	emit_signal(outcome.accepted ? "reload_cancelled" : "command_rejected", result);
	return result;
}

Dictionary WeaponAuthority::configure_attachments(const Dictionary &p_command) {
	if (runtime == nullptr) {
		return error_dictionary(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED), true);
	}
	String unknown_key;
	if (find_unknown_key(p_command, { "command_id", "sequence", "instance_id", "expected_revision", "tick",
									 "authority_scope", "authority_epoch", "desired_loadout" },
				unknown_key)) {
		Dictionary result = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM), true);
		result["field"] = unknown_key;
		result["message"] = vformat("command has unknown key '%s'.", unknown_key);
		return result;
	}
	wpn::ConfigureAttachmentsCommand command;
	command.command_id = to_std(String(p_command.get("command_id", String())));
	command.sequence = nonnegative_u64(int64_t(p_command.get("sequence", int64_t(0))));
	command.instance_id = to_std(String(p_command.get("instance_id", String())));
	command.expected_revision = nonnegative_u64(int64_t(p_command.get("expected_revision", int64_t(0))));
	command.tick = nonnegative_u64(int64_t(p_command.get("tick", int64_t(0))));
	command.authority_scope = to_std(String(p_command.get("authority_scope", String())));
	command.authority_epoch = nonnegative_u64(int64_t(p_command.get("authority_epoch", int64_t(0))));
	const Array desired_loadout = p_command.get("desired_loadout", Array());
	command.desired_loadout.reserve(desired_loadout.size());
	for (int i = 0; i < desired_loadout.size(); ++i) {
		const Dictionary entry_value = desired_loadout[i];
		String entry_unknown_key;
		if (find_unknown_key(entry_value, { "slot_id", "attachment_id", "attachment_version" }, entry_unknown_key)) {
			Dictionary result = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM), true);
			result["field"] = vformat("desired_loadout[%d].%s", i, entry_unknown_key);
			result["message"] = vformat("desired_loadout[%d] has unknown key '%s'.", i, entry_unknown_key);
			return result;
		}
		wpn::AttachmentLoadoutEntry entry;
		entry.slot_id = to_std(String(entry_value.get("slot_id", String())));
		entry.attachment_id = to_std(String(entry_value.get("attachment_id", String())));
		entry.attachment_version = std::uint16_t(int(entry_value.get("attachment_version", 1)));
		command.desired_loadout.push_back(entry);
	}
	const wpn::CommandOutcome outcome = runtime->configure_attachments(command);
	const Dictionary result = outcome_dict(outcome);
	if (outcome.accepted) {
		// New transition the pre-existing signal set lacks (weapon-runtime
		// façade contract: "attachment loadout changed"), carrying the
		// instance's stable ID + successor revision plus its resulting
		// canonical (slot-ID-ordered) loadout.
		const wpn::WeaponSnapshot *state = runtime->find_instance(command.instance_id);
		Dictionary dto;
		dto["instance_id"] = String(command.instance_id.c_str());
		dto["revision"] = int64_t(outcome.revision);
		Array loadout;
		if (state != nullptr) {
			for (const wpn::AttachmentLoadoutEntry &entry : state->attachment_loadout) {
				Dictionary entry_dict;
				entry_dict["slot_id"] = String(entry.slot_id.c_str());
				entry_dict["attachment_id"] = String(entry.attachment_id.c_str());
				entry_dict["attachment_version"] = int(entry.attachment_version);
				loadout.append(entry_dict);
			}
		}
		dto["attachment_loadout"] = loadout;
		emit_signal("attachment_loadout_changed", dto);
	} else {
		emit_signal("command_rejected", result);
	}
	return result;
}

Dictionary WeaponAuthority::teardown(const Dictionary &p_command) {
	if (runtime == nullptr) {
		return error_dictionary(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED), true);
	}
	String unknown_key;
	if (find_unknown_key(p_command, { "command_id", "sequence", "instance_id", "expected_revision", "tick",
									 "authority_scope", "authority_epoch" },
				unknown_key)) {
		Dictionary result = error_dictionary(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM), true);
		result["field"] = unknown_key;
		result["message"] = vformat("command has unknown key '%s'.", unknown_key);
		return result;
	}
	wpn::TeardownCommand command;
	command.command_id = to_std(String(p_command.get("command_id", String())));
	command.sequence = nonnegative_u64(int64_t(p_command.get("sequence", int64_t(0))));
	command.instance_id = to_std(String(p_command.get("instance_id", String())));
	command.expected_revision = nonnegative_u64(int64_t(p_command.get("expected_revision", int64_t(0))));
	command.tick = nonnegative_u64(int64_t(p_command.get("tick", int64_t(0))));
	command.authority_scope = to_std(String(p_command.get("authority_scope", String())));
	command.authority_epoch = nonnegative_u64(int64_t(p_command.get("authority_epoch", int64_t(0))));
	// Owner teardown (weapon-runtime spec's revision matrix, "teardown/
	// tombstone"): an accepted outcome always carries the released reload
	// reservation (if any) in `reservation_to_release`, exactly like a
	// cancelled reload, deterministically through this same façade outcome
	// shape -- the caller releases it the same way it releases a cancelled
	// reload's reservation.
	const wpn::CommandOutcome outcome = runtime->teardown(command);
	const Dictionary result = outcome_dict(outcome);
	emit_signal(outcome.accepted ? "instance_torn_down" : "command_rejected", result);
	return result;
}

Array WeaponAuthority::due_reloads(int64_t p_tick) const {
	Array result;
	if (runtime == nullptr) {
		return result;
	}
	std::vector<wpn::ReloadCompletion> due;
	if (runtime->due_reloads(nonnegative_u64(p_tick), due).ok()) {
		for (const wpn::ReloadCompletion &value : due) {
			result.append(completion_dict(value));
		}
	}
	return result;
}

Dictionary WeaponAuthority::commit_due_reload(
		int64_t p_tick,
		const String &p_instance_id,
		const String &p_reservation_id) {
	wpn::ReloadCompletion completion;
	const wpn::Status status = runtime == nullptr ?
			wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED) :
			runtime->commit_due_reload(
					nonnegative_u64(p_tick),
					to_std(p_instance_id),
					to_std(p_reservation_id),
					completion);
	Dictionary result = status.ok() ? completion_dict(completion) : Dictionary();
	result["ok"] = status.ok();
	result["status"] = status_dict(status);
	return result;
}

void WeaponAuthority::publish_reload_completion(const Dictionary &p_completion) {
	emit_signal("reload_completed", p_completion);
}

Array WeaponAuthority::advance_tick(int64_t p_tick) {
	Array result;
	if (runtime == nullptr) {
		return result;
	}
	std::vector<wpn::ReloadCompletion> completions;
	if (runtime->advance_tick(nonnegative_u64(p_tick), completions).ok()) {
		for (const wpn::ReloadCompletion &value : completions) {
			const Dictionary completion = completion_dict(value);
			result.append(completion);
			emit_signal("reload_completed", completion);
		}
	}
	return result;
}

Dictionary WeaponAuthority::tombstone(const String &p_instance_id) const {
	Dictionary result;
	const wpn::WeaponTombstone *value = runtime == nullptr ? nullptr : runtime->find_tombstone(to_std(p_instance_id));
	if (value == nullptr) {
		result["found"] = false;
		return result;
	}
	return tombstone_dict(*value);
}

Dictionary WeaponAuthority::effective_recoil(const String &p_instance_id, int64_t p_authority_tick) const {
	Dictionary result;
	if (runtime == nullptr) {
		result["ok"] = false;
		result["status"] = status_dict(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED));
		result["vertical_offset_nrad"] = int64_t(0);
		result["horizontal_offset_nrad"] = int64_t(0);
		return result;
	}
	std::int64_t vertical = 0;
	std::int64_t horizontal = 0;
	const wpn::Status status = runtime->effective_recoil(to_std(p_instance_id), nonnegative_u64(p_authority_tick), vertical, horizontal);
	result["ok"] = status.ok();
	result["status"] = status_dict(status);
	result["vertical_offset_nrad"] = int64_t(vertical);
	result["horizontal_offset_nrad"] = int64_t(horizontal);
	return result;
}

Dictionary WeaponAuthority::effective_modifiers(const String &p_instance_id) const {
	Dictionary result;
	if (runtime == nullptr || catalog == nullptr) {
		result["ok"] = false;
		result["status"] = status_dict(wpn::make_status(wpn::StatusCode::CATALOG_NOT_SEALED));
		return result;
	}
	const wpn::WeaponSnapshot *state = runtime->find_instance(to_std(p_instance_id));
	if (state == nullptr) {
		result["ok"] = false;
		result["status"] = status_dict(wpn::make_status(wpn::StatusCode::NOT_FOUND, wpn::DiagnosticId::INSTANCE_UNKNOWN));
		return result;
	}
	// Aggregates the instance's CURRENT accepted attachment loadout only
	// (weapon-runtime façade contract: "effective-modifier queries"), via the
	// SAME public `wpn::fold_modifier_deltas_ppm()` primitive the core's
	// (private) per-command folding uses -- no authority-supplied delta is
	// folded in here, unlike the fire-time computation, since this is a pure
	// read query independent of any one command's authority context.
	std::vector<wpn::ModifierDelta> accuracy_deltas;
	std::vector<wpn::ModifierDelta> recoil_deltas;
	std::vector<wpn::ModifierDelta> noise_deltas;
	std::vector<wpn::ModifierDelta> reload_duration_deltas;
	std::vector<wpn::ModifierDelta> cadence_deltas;
	for (const wpn::AttachmentLoadoutEntry &entry : state->attachment_loadout) {
		const wpn::AttachmentDefinition *definition = catalog->find_attachment(entry.attachment_id, entry.attachment_version);
		if (definition == nullptr) continue; // Defensive: unreachable for an accepted loadout.
		accuracy_deltas.push_back(wpn::ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->accuracy_modifier_ppm });
		recoil_deltas.push_back(wpn::ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->recoil_modifier_ppm });
		noise_deltas.push_back(wpn::ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->noise_modifier_ppm });
		reload_duration_deltas.push_back(wpn::ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->reload_duration_modifier_ppm });
		cadence_deltas.push_back(wpn::ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->cadence_modifier_ppm });
	}
	std::int64_t accuracy_ppm = 0, recoil_ppm = 0, noise_ppm = 0, reload_ppm = 0, cadence_ppm = 0;
	wpn::Status status = wpn::fold_modifier_deltas_ppm(accuracy_deltas, accuracy_ppm);
	if (status.ok()) status = wpn::fold_modifier_deltas_ppm(recoil_deltas, recoil_ppm);
	if (status.ok()) status = wpn::fold_modifier_deltas_ppm(noise_deltas, noise_ppm);
	if (status.ok()) status = wpn::fold_modifier_deltas_ppm(reload_duration_deltas, reload_ppm);
	if (status.ok()) status = wpn::fold_modifier_deltas_ppm(cadence_deltas, cadence_ppm);
	result["ok"] = status.ok();
	result["status"] = status_dict(status);
	result["accuracy_multiplier_ppm"] = int64_t(accuracy_ppm);
	result["recoil_multiplier_ppm"] = int64_t(recoil_ppm);
	result["noise_multiplier_ppm"] = int64_t(noise_ppm);
	result["reload_duration_multiplier_ppm"] = int64_t(reload_ppm);
	result["cadence_multiplier_ppm"] = int64_t(cadence_ppm);
	return result;
}

Dictionary WeaponAuthority::loaded_profile(const String &p_instance_id) const {
	if (runtime == nullptr) {
		return profile_dict(std::nullopt);
	}
	const wpn::WeaponSnapshot *state = runtime->find_instance(to_std(p_instance_id));
	if (state == nullptr) {
		return profile_dict(std::nullopt);
	}
	return profile_dict(state->loaded_profile);
}

void WeaponAuthority::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_role", "role"), &WeaponAuthority::set_role);
	ClassDB::bind_method(D_METHOD("get_role"), &WeaponAuthority::get_role);
	ClassDB::bind_method(D_METHOD("configure", "shot_profiles", "weapons", "recoil_profiles", "attachments", "ammo_profiles"),
			&WeaponAuthority::configure, DEFVAL(Array()), DEFVAL(Array()), DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("is_ready"), &WeaponAuthority::is_ready);
	ClassDB::bind_method(D_METHOD("content_fingerprint"), &WeaponAuthority::content_fingerprint);
	ClassDB::bind_method(D_METHOD("create_weapon", "instance_id", "definition_id", "definition_version", "loaded_rounds", "profile", "authority_scope", "authority_epoch"),
			&WeaponAuthority::create_weapon, DEFVAL(1), DEFVAL(0), DEFVAL(Dictionary()), DEFVAL(String()), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("remove_weapon", "instance_id"), &WeaponAuthority::remove_weapon);
	ClassDB::bind_method(D_METHOD("snapshot", "instance_id"), &WeaponAuthority::snapshot);
	ClassDB::bind_method(D_METHOD("snapshots"), &WeaponAuthority::snapshots);
	ClassDB::bind_method(D_METHOD("replace_snapshots", "snapshots"), &WeaponAuthority::replace_snapshots);
	ClassDB::bind_method(D_METHOD("fire", "command", "authority"), &WeaponAuthority::fire);
	ClassDB::bind_method(D_METHOD("begin_reload", "command"), &WeaponAuthority::begin_reload);
	ClassDB::bind_method(D_METHOD("cancel_reload", "command"), &WeaponAuthority::cancel_reload);
	ClassDB::bind_method(D_METHOD("configure_attachments", "command"), &WeaponAuthority::configure_attachments);
	ClassDB::bind_method(D_METHOD("teardown", "command"), &WeaponAuthority::teardown);
	ClassDB::bind_method(D_METHOD("due_reloads", "tick"), &WeaponAuthority::due_reloads);
	ClassDB::bind_method(D_METHOD("commit_due_reload", "tick", "instance_id", "reservation_id"), &WeaponAuthority::commit_due_reload);
	ClassDB::bind_method(D_METHOD("publish_reload_completion", "completion"), &WeaponAuthority::publish_reload_completion);
	ClassDB::bind_method(D_METHOD("advance_tick", "tick"), &WeaponAuthority::advance_tick);
	ClassDB::bind_method(D_METHOD("tombstone", "instance_id"), &WeaponAuthority::tombstone);
	ClassDB::bind_method(D_METHOD("effective_recoil", "instance_id", "authority_tick"), &WeaponAuthority::effective_recoil);
	ClassDB::bind_method(D_METHOD("effective_modifiers", "instance_id"), &WeaponAuthority::effective_modifiers);
	ClassDB::bind_method(D_METHOD("loaded_profile", "instance_id"), &WeaponAuthority::loaded_profile);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "role", PROPERTY_HINT_ENUM, "OfflineAuthority,ServerAuthority"), "set_role", "get_role");
	ADD_SIGNAL(MethodInfo("shot_committed", PropertyInfo(Variant::DICTIONARY, "outcome")));
	ADD_SIGNAL(MethodInfo("reload_started", PropertyInfo(Variant::DICTIONARY, "outcome")));
	ADD_SIGNAL(MethodInfo("reload_completed", PropertyInfo(Variant::DICTIONARY, "completion")));
	ADD_SIGNAL(MethodInfo("reload_cancelled", PropertyInfo(Variant::DICTIONARY, "outcome")));
	ADD_SIGNAL(MethodInfo("command_rejected", PropertyInfo(Variant::DICTIONARY, "outcome")));
	ADD_SIGNAL(MethodInfo("state_corrected", PropertyInfo(Variant::ARRAY, "snapshots")));
	// New immutable transition signals (weapon-runtime façade contract:
	// "attachment loadout changed, recoil anchor changed"), each carrying a
	// value DTO keyed by the instance's stable ID + successor revision.
	ADD_SIGNAL(MethodInfo("attachment_loadout_changed", PropertyInfo(Variant::DICTIONARY, "loadout")));
	ADD_SIGNAL(MethodInfo("recoil_anchor_changed", PropertyInfo(Variant::DICTIONARY, "anchor")));
	ADD_SIGNAL(MethodInfo("instance_torn_down", PropertyInfo(Variant::DICTIONARY, "outcome")));
	BIND_ENUM_CONSTANT(ROLE_OFFLINE_AUTHORITY);
	BIND_ENUM_CONSTANT(ROLE_SERVER_AUTHORITY);
}

} // namespace godot
