#include "godot/weapon_definition_catalog.h"

#include "core/wpn_definitions.h"
#include "core/wpn_identifier.h"
#include "core/wpn_limits.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <set>
#include <string>
#include <utility>

namespace godot {

namespace {

std::string to_std(const String &p_value) {
	return p_value.utf8().get_data();
}

// Resource path if saved, else an addressable "<anonymous Kind>" fallback --
// matches inventory_system's InventoryCatalog "stable-path diagnostics"
// precedent even for an unsaved/in-memory Resource.
String source_label_of(const Ref<Resource> &p_resource, const char *p_kind) {
	if (p_resource.is_valid() && !p_resource->get_path().is_empty()) {
		return p_resource->get_path();
	}
	return vformat("<anonymous %s>", p_kind);
}

String slot_label(const char *p_collection, int p_index) {
	return vformat("<%s[%d]>", p_collection, p_index);
}

Dictionary make_finding(const String &p_severity, const String &p_resource_path, const String &p_field,
		const String &p_code, const String &p_message) {
	Dictionary finding;
	finding["severity"] = p_severity;
	finding["resource_path"] = p_resource_path;
	finding["field"] = p_field;
	finding["code"] = p_code;
	finding["message"] = p_message;
	return finding;
}

// Lowercase snake_case name for a `wpn::DiagnosticId`. Diagnostics are the
// core's most specific available signal, so they take priority over the
// coarser `StatusCode` name below whenever a `Status` carries one (mirrors
// gameplay_abilities' GameplayDefinitionValidator::diagnostic_code()).
String diagnostic_code(wpn::DiagnosticId p_diagnostic) {
	switch (p_diagnostic) {
		case wpn::DiagnosticId::IDENTIFIER_INVALID:
			return "identifier_invalid";
		case wpn::DiagnosticId::IDENTIFIER_TOO_LONG:
			return "identifier_too_long";
		case wpn::DiagnosticId::SOURCE_LABEL_TOO_LONG:
			return "source_label_too_long";
		case wpn::DiagnosticId::COUNT_LIMIT_EXCEEDED:
			return "count_limit_exceeded";
		case wpn::DiagnosticId::BYTE_LIMIT_EXCEEDED:
			return "byte_limit_exceeded";
		case wpn::DiagnosticId::INVALID_ENUM:
			return "invalid_enum";
		case wpn::DiagnosticId::VALUE_OUT_OF_RANGE:
			return "value_out_of_range";
		case wpn::DiagnosticId::NON_FINITE_VALUE:
			return "non_finite_value";
		case wpn::DiagnosticId::NESTED_ATTACHMENT_REJECTED:
			return "nested_attachment_rejected";
		case wpn::DiagnosticId::DEFINITION_DUPLICATE:
			return "duplicate_definition";
		case wpn::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE:
			return "unknown_reference";
		case wpn::DiagnosticId::CATALOG_ALREADY_SEALED:
			return "catalog_already_sealed";
		case wpn::DiagnosticId::CATALOG_REQUIRES_SEAL:
			return "catalog_requires_seal";
		default:
			return vformat("diagnostic_%d", static_cast<int>(p_diagnostic));
	}
}

String status_code_name(wpn::StatusCode p_code) {
	switch (p_code) {
		case wpn::StatusCode::OK:
			return "ok";
		case wpn::StatusCode::INVALID_ARGUMENT:
			return "invalid_argument";
		case wpn::StatusCode::NOT_FOUND:
			return "not_found";
		case wpn::StatusCode::ALREADY_EXISTS:
			return "already_exists";
		case wpn::StatusCode::LIMIT_EXCEEDED:
			return "limit_exceeded";
		case wpn::StatusCode::NOT_SUPPORTED:
			return "not_supported";
		case wpn::StatusCode::INTERNAL_ERROR:
			return "internal_error";
		case wpn::StatusCode::INVALID_IDENTIFIER:
			return "invalid_identifier";
		case wpn::StatusCode::DUPLICATE_DEFINITION:
			return "duplicate_definition";
		case wpn::StatusCode::UNKNOWN_DEFINITION:
			return "unknown_definition";
		case wpn::StatusCode::INVALID_REFERENCE:
			return "invalid_reference";
		case wpn::StatusCode::CATALOG_SEALED:
			return "catalog_sealed";
		case wpn::StatusCode::CATALOG_NOT_SEALED:
			return "catalog_not_sealed";
		default:
			return vformat("status_%d", static_cast<int>(p_code));
	}
}

String status_code(const wpn::Status &p_status) {
	if (p_status.diagnostic != wpn::DiagnosticId::NONE) {
		return diagnostic_code(p_status.diagnostic);
	}
	return status_code_name(p_status.code);
}

Dictionary diagnostic_dict(const wpn::Status &p_status, const String &p_field, const String &p_identifier,
		const String &p_source, const String &p_message = String()) {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["status_code"] = int(p_status.code);
	result["diagnostic"] = int(p_status.diagnostic);
	result["detail"] = int64_t(p_status.detail);
	result["field"] = p_field;
	result["identifier"] = p_identifier;
	result["source"] = p_source;
	result["message"] = !p_message.is_empty() ? p_message : (p_status.ok() ? String("ok") : status_code(p_status));
	return result;
}

// Human-readable label for a WeaponDefinitionResource::FireMode/Mechanism
// value, used only inside diagnostic messages -- never authority.
String fire_mode_label(int p_value) {
	switch (p_value) {
		case WeaponDefinitionResource::FIRE_MODE_SEMI_AUTO:
			return "SemiAuto";
		case WeaponDefinitionResource::FIRE_MODE_AUTOMATIC:
			return "Automatic";
		case WeaponDefinitionResource::FIRE_MODE_BURST:
			return "Burst";
		default:
			return vformat("<unknown fire_mode %d>", p_value);
	}
}

String mechanism_label(int p_value) {
	switch (p_value) {
		case WeaponDefinitionResource::MECHANISM_HITSCAN_2D:
			return "Hitscan2D";
		case WeaponDefinitionResource::MECHANISM_PROJECTILE_2D:
			return "Projectile2D";
		default:
			return vformat("<unknown mechanism %d>", p_value);
	}
}

wpn::HitscanShotProfile to_shot_profile(const Ref<HitscanShotProfileResource> &p_resource) {
	wpn::HitscanShotProfile desc;
	desc.id = to_std(String(p_resource->get_identifier()));
	desc.version = std::uint16_t(p_resource->get_version());
	desc.damage_milliunits = p_resource->get_damage_milliunits();
	desc.range_milliunits = p_resource->get_range_milliunits();
	desc.spread_microradians = p_resource->get_spread_microradians();
	desc.aim_tolerance_microradians = p_resource->get_aim_tolerance_microradians();
	desc.origin_tolerance_milliunits = p_resource->get_origin_tolerance_milliunits();
	return desc;
}

wpn::RecoilProfile to_recoil_profile(const Ref<RecoilProfileResource> &p_resource) {
	wpn::RecoilProfile desc;
	desc.id = to_std(String(p_resource->get_identifier()));
	desc.version = std::uint16_t(p_resource->get_version());
	desc.vertical_kick_nrad = p_resource->get_vertical_kick_nrad();
	desc.horizontal_kick_min_nrad = p_resource->get_horizontal_kick_min_nrad();
	desc.horizontal_kick_max_nrad = p_resource->get_horizontal_kick_max_nrad();
	desc.recovery_per_tick_nrad = p_resource->get_recovery_per_tick_nrad();
	desc.max_vertical_offset_nrad = p_resource->get_max_vertical_offset_nrad();
	desc.max_horizontal_offset_nrad = p_resource->get_max_horizontal_offset_nrad();
	return desc;
}

// `compatible_slot_kinds_mask` is copied verbatim (no translation): both
// `AttachmentDefinitionResource`'s `PROPERTY_HINT_FLAGS` and
// `wpn::AttachmentSlotKind` assign bit 1/2/4/8 to Optic/Muzzle/Stock/Grip in
// the same order, so the Resource's raw bitmask int already IS the core
// bitmask.
wpn::AttachmentDefinition to_attachment_definition(const Ref<AttachmentDefinitionResource> &p_resource) {
	wpn::AttachmentDefinition desc;
	desc.id = to_std(String(p_resource->get_identifier()));
	desc.version = std::uint16_t(p_resource->get_version());
	desc.compatible_slot_kinds_mask = std::uint32_t(p_resource->get_compatible_slot_kinds_mask());
	const PackedStringArray tags = p_resource->get_compatible_tags();
	desc.compatible_tags.reserve(tags.size());
	for (int i = 0; i < tags.size(); ++i) {
		desc.compatible_tags.push_back(to_std(tags[i]));
	}
	desc.accuracy_modifier_ppm = p_resource->get_accuracy_modifier_ppm();
	desc.recoil_modifier_ppm = p_resource->get_recoil_modifier_ppm();
	desc.noise_modifier_ppm = p_resource->get_noise_modifier_ppm();
	desc.reload_duration_modifier_ppm = p_resource->get_reload_duration_modifier_ppm();
	desc.cadence_modifier_ppm = p_resource->get_cadence_modifier_ppm();
	desc.provided_slot_count = std::uint32_t(p_resource->get_provided_slot_count());
	return desc;
}

wpn::AmmunitionBallisticProfile to_ammo_profile(const Ref<AmmunitionBallisticProfileResource> &p_resource) {
	wpn::AmmunitionBallisticProfile desc;
	desc.id = to_std(String(p_resource->get_identifier()));
	desc.version = std::uint16_t(p_resource->get_version());
	desc.ammunition_trait = to_std(String(p_resource->get_ammunition_trait()));
	return desc;
}

// Explicit ordinal -> sealed-bit translation for the SINGLE slot kind a
// `WeaponAttachmentSlotResource` names (unlike the attachment definition's
// mask above, which already aligns numerically). Returns 0 -- not a valid
// `wpn::AttachmentSlotKind` bit -- for any value outside the closed V1 enum,
// so callers can detect an invalid/unrecognized `slot_kind` the same way
// `wpn::WeaponDefinition::validate()`'s own bit check would.
std::uint32_t to_attachment_slot_kind_bit(int p_slot_kind) {
	switch (p_slot_kind) {
		case WeaponAttachmentSlotResource::SLOT_KIND_OPTIC:
			return static_cast<std::uint32_t>(wpn::AttachmentSlotKind::OPTIC);
		case WeaponAttachmentSlotResource::SLOT_KIND_MUZZLE:
			return static_cast<std::uint32_t>(wpn::AttachmentSlotKind::MUZZLE);
		case WeaponAttachmentSlotResource::SLOT_KIND_STOCK:
			return static_cast<std::uint32_t>(wpn::AttachmentSlotKind::STOCK);
		case WeaponAttachmentSlotResource::SLOT_KIND_GRIP:
			return static_cast<std::uint32_t>(wpn::AttachmentSlotKind::GRIP);
		default:
			return 0;
	}
}

// Only called once `precheck_weapon()` below has already accepted
// p_resource's `mechanism`/`fire_mode`/`attachment_slots`, so the sealed
// values are always legal V1 values regardless of the authored raw ints.
wpn::WeaponDefinition to_weapon_definition(const Ref<WeaponDefinitionResource> &p_resource) {
	wpn::WeaponDefinition desc;
	desc.id = to_std(String(p_resource->get_identifier()));
	desc.version = std::uint16_t(p_resource->get_version());
	desc.mechanism = wpn::WeaponMechanism::HITSCAN_2D;
	desc.fire_mode = wpn::FireMode::SEMI_AUTO;
	desc.shot_profile_id = to_std(String(p_resource->get_shot_profile_id()));
	desc.shot_profile_version = std::uint16_t(p_resource->get_shot_profile_version());
	desc.ammunition_trait = to_std(String(p_resource->get_ammunition_trait()));
	desc.capacity = std::uint32_t(p_resource->get_capacity());
	desc.cadence_ticks = std::uint32_t(p_resource->get_cadence_ticks());
	desc.reload_ticks = std::uint32_t(p_resource->get_reload_ticks());
	desc.noise_radius_milliunits = p_resource->get_noise_radius_milliunits();
	desc.accuracy_moa_milli = p_resource->get_accuracy_moa_milli();
	desc.recoil_profile_id = to_std(String(p_resource->get_recoil_profile_id()));
	desc.recoil_profile_version = std::uint16_t(p_resource->get_recoil_profile_version());
	const TypedArray<WeaponAttachmentSlotResource> slots = p_resource->get_attachment_slots();
	desc.attachment_slots.reserve(slots.size());
	for (int i = 0; i < slots.size(); ++i) {
		const Ref<WeaponAttachmentSlotResource> slot = slots[i];
		if (slot.is_null()) continue; // already rejected by precheck_weapon
		wpn::WeaponAttachmentSlot core_slot;
		core_slot.slot_id = to_std(String(slot->get_slot_id()));
		core_slot.slot_kind = static_cast<wpn::AttachmentSlotKind>(to_attachment_slot_kind_bit(int(slot->get_slot_kind())));
		desc.attachment_slots.push_back(core_slot);
	}
	return desc;
}

wpn::Status field_status(std::int64_t p_detail) {
	return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::VALUE_OUT_OF_RANGE,
			std::uint64_t(p_detail < 0 ? 0 : p_detail));
}

// Field-level pre-checks that run BEFORE `wpn::WeaponCatalog::add_shot_profile()`.
// `wpn::HitscanShotProfile::validate()` (native/core/wpn_definitions.cpp)
// already rejects every one of these; this duplicates its bounds using the
// SAME `wpn::MAX_*` limits purely to identify which authored field/value is
// responsible (weapon-authoring spec.md "Checked Numeric and Reference
// Validation") -- it never loosens or replaces the core's own check, which
// still runs afterward via add_shot_profile().
wpn::Status precheck_shot_profile(const Ref<HitscanShotProfileResource> &p_resource, String &r_field, String &r_message) {
	const String identifier = String(p_resource->get_identifier());
	wpn::Status status = wpn::validate_identifier(to_std(identifier));
	if (!status.ok()) {
		r_field = "identifier";
		r_message = vformat("identifier '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", identifier);
		return status;
	}
	const int version = p_resource->get_version();
	if (version < 1 || version > 65535) {
		r_field = "version";
		r_message = vformat("version %d must be between 1 and 65535.", version);
		return field_status(version);
	}
	const int64_t damage = p_resource->get_damage_milliunits();
	if (damage <= 0 || damage > wpn::MAX_DAMAGE_MILLIUNITS) {
		r_field = "damage_milliunits";
		r_message = vformat("damage_milliunits %d must be positive and at most %d.", damage, int64_t(wpn::MAX_DAMAGE_MILLIUNITS));
		return field_status(damage);
	}
	const int64_t range = p_resource->get_range_milliunits();
	if (range <= 0 || range > wpn::MAX_WORLD_MILLIUNITS) {
		r_field = "range_milliunits";
		r_message = vformat("range_milliunits %d must be positive and at most %d.", range, int64_t(wpn::MAX_WORLD_MILLIUNITS));
		return field_status(range);
	}
	const int64_t spread = p_resource->get_spread_microradians();
	if (spread < 0 || spread > wpn::MAX_ANGLE_MICRORADIANS) {
		r_field = "spread_microradians";
		r_message = vformat("spread_microradians %d must be within [0, %d].", spread, int64_t(wpn::MAX_ANGLE_MICRORADIANS));
		return field_status(spread);
	}
	const int64_t aim_tolerance = p_resource->get_aim_tolerance_microradians();
	if (aim_tolerance < 0 || aim_tolerance > wpn::MAX_ANGLE_MICRORADIANS) {
		r_field = "aim_tolerance_microradians";
		r_message = vformat("aim_tolerance_microradians %d must be within [0, %d].", aim_tolerance, int64_t(wpn::MAX_ANGLE_MICRORADIANS));
		return field_status(aim_tolerance);
	}
	const int64_t origin_tolerance = p_resource->get_origin_tolerance_milliunits();
	if (origin_tolerance < 0 || origin_tolerance > wpn::MAX_WORLD_MILLIUNITS) {
		r_field = "origin_tolerance_milliunits";
		r_message = vformat("origin_tolerance_milliunits %d must be within [0, %d].", origin_tolerance, int64_t(wpn::MAX_WORLD_MILLIUNITS));
		return field_status(origin_tolerance);
	}
	return wpn::ok_status();
}

// Field-level pre-checks that run BEFORE `wpn::WeaponCatalog::add_recoil_profile()`.
// Mirrors `wpn::RecoilProfile::validate()` (native/core/wpn_definitions.cpp)
// per field, same rationale as `precheck_shot_profile()` above.
wpn::Status precheck_recoil_profile(const Ref<RecoilProfileResource> &p_resource, String &r_field, String &r_message) {
	const String identifier = String(p_resource->get_identifier());
	wpn::Status status = wpn::validate_identifier(to_std(identifier));
	if (!status.ok()) {
		r_field = "identifier";
		r_message = vformat("identifier '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", identifier);
		return status;
	}
	const int version = p_resource->get_version();
	if (version < 1 || version > 65535) {
		r_field = "version";
		r_message = vformat("version %d must be between 1 and 65535.", version);
		return field_status(version);
	}
	const int64_t vertical_kick = p_resource->get_vertical_kick_nrad();
	if (vertical_kick < 0 || vertical_kick > wpn::MAX_RECOIL_KICK_NRAD) {
		r_field = "vertical_kick_nrad";
		r_message = vformat("vertical_kick_nrad %d must be within [0, %d].", vertical_kick, int64_t(wpn::MAX_RECOIL_KICK_NRAD));
		return field_status(vertical_kick);
	}
	const int64_t horizontal_min = p_resource->get_horizontal_kick_min_nrad();
	const int64_t horizontal_max = p_resource->get_horizontal_kick_max_nrad();
	if (horizontal_min < -wpn::MAX_RECOIL_KICK_NRAD || horizontal_max > wpn::MAX_RECOIL_KICK_NRAD || horizontal_min > horizontal_max) {
		r_field = horizontal_min > horizontal_max ? "horizontal_kick_min_nrad/horizontal_kick_max_nrad" :
				(horizontal_min < -wpn::MAX_RECOIL_KICK_NRAD ? "horizontal_kick_min_nrad" : "horizontal_kick_max_nrad");
		r_message = vformat(
				"horizontal_kick_min_nrad %d and horizontal_kick_max_nrad %d must both be within [%d, %d] and min <= max.",
				horizontal_min, horizontal_max, int64_t(-wpn::MAX_RECOIL_KICK_NRAD), int64_t(wpn::MAX_RECOIL_KICK_NRAD));
		return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	const int64_t recovery = p_resource->get_recovery_per_tick_nrad();
	if (recovery <= 0 || recovery > wpn::MAX_RECOVERY_PER_TICK_NRAD) {
		r_field = "recovery_per_tick_nrad";
		r_message = vformat("recovery_per_tick_nrad %d must be positive and at most %d.", recovery, int64_t(wpn::MAX_RECOVERY_PER_TICK_NRAD));
		return field_status(recovery);
	}
	const int64_t max_vertical_offset = p_resource->get_max_vertical_offset_nrad();
	if (max_vertical_offset < vertical_kick || max_vertical_offset > wpn::MAX_RECOIL_OFFSET_NRAD) {
		r_field = "max_vertical_offset_nrad";
		r_message = vformat("max_vertical_offset_nrad %d must be at least vertical_kick_nrad (%d) and at most %d.",
				max_vertical_offset, vertical_kick, int64_t(wpn::MAX_RECOIL_OFFSET_NRAD));
		return field_status(max_vertical_offset);
	}
	const int64_t max_abs_horizontal_kick = std::max(std::llabs(horizontal_min), std::llabs(horizontal_max));
	const int64_t max_horizontal_offset = p_resource->get_max_horizontal_offset_nrad();
	if (max_horizontal_offset < max_abs_horizontal_kick || max_horizontal_offset > wpn::MAX_RECOIL_OFFSET_NRAD) {
		r_field = "max_horizontal_offset_nrad";
		r_message = vformat("max_horizontal_offset_nrad %d must be at least the largest horizontal kick magnitude (%d) and at most %d.",
				max_horizontal_offset, max_abs_horizontal_kick, int64_t(wpn::MAX_RECOIL_OFFSET_NRAD));
		return field_status(max_horizontal_offset);
	}
	return wpn::ok_status();
}

// Field-level pre-checks that run BEFORE `wpn::WeaponCatalog::add_attachment()`.
// Mirrors `wpn::AttachmentDefinition::validate()` per field. Checks
// `provided_slot_count` FIRST, same order as the core (weapon-authoring
// spec.md "Versioned Recoil and Flat Attachment Definitions": "Attachment
// recursively provides another slot" -> "V1 validation rejects the nested
// graph explicitly").
wpn::Status precheck_attachment(const Ref<AttachmentDefinitionResource> &p_resource, String &r_field, String &r_message) {
	const String identifier = String(p_resource->get_identifier());
	wpn::Status status = wpn::validate_identifier(to_std(identifier));
	if (!status.ok()) {
		r_field = "identifier";
		r_message = vformat("identifier '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", identifier);
		return status;
	}
	const int version = p_resource->get_version();
	if (version < 1 || version > 65535) {
		r_field = "version";
		r_message = vformat("version %d must be between 1 and 65535.", version);
		return field_status(version);
	}
	const int provided_slot_count = p_resource->get_provided_slot_count();
	if (provided_slot_count != 0) {
		r_field = "provided_slot_count";
		r_message = vformat(
				"provided_slot_count %d is not supported in V1: an attachment cannot itself provide attachment slots (design.md Non-Goals: nested attachment graphs).",
				provided_slot_count);
		return wpn::make_status(wpn::StatusCode::NOT_SUPPORTED, wpn::DiagnosticId::NESTED_ATTACHMENT_REJECTED,
				std::uint64_t(provided_slot_count));
	}
	const int mask = p_resource->get_compatible_slot_kinds_mask();
	if (mask == 0 || (std::uint32_t(mask) & ~wpn::ALL_ATTACHMENT_SLOT_KINDS) != 0) {
		r_field = "compatible_slot_kinds_mask";
		r_message = vformat("compatible_slot_kinds_mask %d must be a nonzero combination of the known V1 slot kinds (bits 1,2,4,8).", mask);
		return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM, std::uint64_t(mask));
	}
	const PackedStringArray tags = p_resource->get_compatible_tags();
	if (tags.size() > int(wpn::MAX_ATTACHMENT_COMPATIBLE_TAGS)) {
		r_field = "compatible_tags";
		r_message = vformat("compatible_tags has %d entries, at most %d are allowed.", tags.size(), int(wpn::MAX_ATTACHMENT_COMPATIBLE_TAGS));
		return wpn::make_status(wpn::StatusCode::LIMIT_EXCEEDED, wpn::DiagnosticId::COUNT_LIMIT_EXCEEDED, std::uint64_t(tags.size()));
	}
	std::set<std::string> seen_tags;
	for (int i = 0; i < tags.size(); ++i) {
		const std::string tag = to_std(tags[i]);
		status = wpn::validate_identifier(tag);
		if (!status.ok()) {
			r_field = vformat("compatible_tags[%d]", i);
			r_message = vformat("compatible_tags[%d] '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", i, String(tags[i]));
			return status;
		}
		if (!seen_tags.insert(tag).second) {
			r_field = vformat("compatible_tags[%d]", i);
			r_message = vformat("compatible_tags[%d] '%s' duplicates an earlier tag.", i, String(tags[i]));
			return wpn::make_status(wpn::StatusCode::DUPLICATE_DEFINITION, wpn::DiagnosticId::DEFINITION_DUPLICATE);
		}
	}
	const struct { const char *name; int64_t value; } modifiers[] = {
		{ "accuracy_modifier_ppm", p_resource->get_accuracy_modifier_ppm() },
		{ "recoil_modifier_ppm", p_resource->get_recoil_modifier_ppm() },
		{ "noise_modifier_ppm", p_resource->get_noise_modifier_ppm() },
		{ "reload_duration_modifier_ppm", p_resource->get_reload_duration_modifier_ppm() },
		{ "cadence_modifier_ppm", p_resource->get_cadence_modifier_ppm() },
	};
	for (const auto &modifier : modifiers) {
		if (modifier.value < -wpn::MAX_MODIFIER_DELTA_PPM || modifier.value > wpn::MAX_MODIFIER_DELTA_PPM) {
			r_field = modifier.name;
			r_message = vformat("%s %d must be within [%d, %d].", modifier.name, modifier.value,
					int64_t(-wpn::MAX_MODIFIER_DELTA_PPM), int64_t(wpn::MAX_MODIFIER_DELTA_PPM));
			return field_status(modifier.value);
		}
	}
	return wpn::ok_status();
}

// Field-level pre-checks that run BEFORE `wpn::WeaponCatalog::add_ammo_profile()`.
// Mirrors `wpn::AmmunitionBallisticProfile::validate()` per field.
wpn::Status precheck_ballistic_profile(const Ref<AmmunitionBallisticProfileResource> &p_resource, String &r_field, String &r_message) {
	const String identifier = String(p_resource->get_identifier());
	wpn::Status status = wpn::validate_identifier(to_std(identifier));
	if (!status.ok()) {
		r_field = "identifier";
		r_message = vformat("identifier '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", identifier);
		return status;
	}
	const int version = p_resource->get_version();
	if (version < 1 || version > 65535) {
		r_field = "version";
		r_message = vformat("version %d must be between 1 and 65535.", version);
		return field_status(version);
	}
	const String ammunition_trait = String(p_resource->get_ammunition_trait());
	status = wpn::validate_identifier(to_std(ammunition_trait));
	if (!status.ok()) {
		r_field = "ammunition_trait";
		r_message = vformat("ammunition_trait '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", ammunition_trait);
		return status;
	}
	return wpn::ok_status();
}

// Field-level pre-checks that run BEFORE `wpn::WeaponCatalog::add_weapon()`.
// Beyond duplicating `wpn::WeaponDefinition::validate()`'s bounds per field
// (same rationale as `precheck_shot_profile()` above), this is the ONLY
// place that explicitly rejects a deferred `mechanism`/`fire_mode` value
// with a diagnostic identifying the exact field and requested value
// (weapon-authoring spec.md "Small Explicit V1 Firearm Schema": "Deferred
// mechanism is authored" -- "the runtime does not approximate it as
// semi-auto hitscan"). It also enforces `cadence_ticks`/`reload_ticks` > 0:
// the core's own combined range check
// (`wpn::WeaponDefinition::validate()`) currently only bounds their upper
// limit, so a zero value would otherwise pass core validation despite
// weapon-authoring spec.md's "Checked Numeric and Reference Validation"
// requiring "zero/negative cadence or reload duration" to be rejected; this
// pre-check closes that gap at the authoring boundary without editing core
// semantics (see this task's final report for the full note).
wpn::Status precheck_weapon(const Ref<WeaponDefinitionResource> &p_resource, String &r_field, String &r_message) {
	const String identifier = String(p_resource->get_identifier());
	wpn::Status status = wpn::validate_identifier(to_std(identifier));
	if (!status.ok()) {
		r_field = "identifier";
		r_message = vformat("identifier '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", identifier);
		return status;
	}
	const int version = p_resource->get_version();
	if (version < 1 || version > 65535) {
		r_field = "version";
		r_message = vformat("version %d must be between 1 and 65535.", version);
		return field_status(version);
	}
	const String shot_profile_id = String(p_resource->get_shot_profile_id());
	status = wpn::validate_identifier(to_std(shot_profile_id));
	if (!status.ok()) {
		r_field = "shot_profile_id";
		r_message = vformat("shot_profile_id '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", shot_profile_id);
		return status;
	}
	const int shot_profile_version = p_resource->get_shot_profile_version();
	if (shot_profile_version < 1 || shot_profile_version > 65535) {
		r_field = "shot_profile_version";
		r_message = vformat("shot_profile_version %d must be between 1 and 65535.", shot_profile_version);
		return field_status(shot_profile_version);
	}
	const String ammunition_trait = String(p_resource->get_ammunition_trait());
	status = wpn::validate_identifier(to_std(ammunition_trait));
	if (!status.ok()) {
		r_field = "ammunition_trait";
		r_message = vformat("ammunition_trait '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", ammunition_trait);
		return status;
	}
	// `recoil_profile_id` is a REQUIRED reference, exactly like
	// `shot_profile_id`: `wpn::WeaponDefinition::validate()` rejects an empty
	// one (weapon-authoring spec.md "Small Explicit V1 Firearm Schema": "one
	// referenced recoil profile").
	const String recoil_profile_id = String(p_resource->get_recoil_profile_id());
	status = wpn::validate_identifier(to_std(recoil_profile_id));
	if (!status.ok()) {
		r_field = "recoil_profile_id";
		r_message = vformat("recoil_profile_id '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", recoil_profile_id);
		return status;
	}
	const int recoil_profile_version = p_resource->get_recoil_profile_version();
	if (recoil_profile_version < 1 || recoil_profile_version > 65535) {
		r_field = "recoil_profile_version";
		r_message = vformat("recoil_profile_version %d must be between 1 and 65535.", recoil_profile_version);
		return field_status(recoil_profile_version);
	}
	if (p_resource->get_mechanism() != WeaponDefinitionResource::MECHANISM_HITSCAN_2D) {
		r_field = "mechanism";
		r_message = vformat(
				"mechanism '%s' is deferred in V1; only 'Hitscan2D' is supported (design.md Non-Goals). The runtime will not approximate this as semi-auto hitscan.",
				mechanism_label(int(p_resource->get_mechanism())));
		return wpn::make_status(wpn::StatusCode::NOT_SUPPORTED, wpn::DiagnosticId::INVALID_ENUM,
				std::uint64_t(p_resource->get_mechanism()));
	}
	if (p_resource->get_fire_mode() != WeaponDefinitionResource::FIRE_MODE_SEMI_AUTO) {
		r_field = "fire_mode";
		r_message = vformat(
				"fire_mode '%s' is deferred in V1; only 'SemiAuto' is supported (design.md Non-Goals). The runtime will not approximate this as semi-auto hitscan.",
				fire_mode_label(int(p_resource->get_fire_mode())));
		return wpn::make_status(wpn::StatusCode::NOT_SUPPORTED, wpn::DiagnosticId::INVALID_ENUM,
				std::uint64_t(p_resource->get_fire_mode()));
	}
	const int capacity = p_resource->get_capacity();
	if (capacity < 1 || capacity > int(wpn::MAX_CAPACITY)) {
		r_field = "capacity";
		r_message = vformat("capacity %d must be between 1 and %d.", capacity, int(wpn::MAX_CAPACITY));
		return field_status(capacity);
	}
	const int cadence_ticks = p_resource->get_cadence_ticks();
	if (cadence_ticks < 1 || cadence_ticks > int(wpn::MAX_TICK_DURATION)) {
		r_field = "cadence_ticks";
		r_message = vformat("cadence_ticks %d must be a positive minimum-ticks-between-shots value, at most %d.", cadence_ticks, int(wpn::MAX_TICK_DURATION));
		return field_status(cadence_ticks);
	}
	const int reload_ticks = p_resource->get_reload_ticks();
	if (reload_ticks < 1 || reload_ticks > int(wpn::MAX_TICK_DURATION)) {
		r_field = "reload_ticks";
		r_message = vformat("reload_ticks %d must be a positive reload duration, at most %d.", reload_ticks, int(wpn::MAX_TICK_DURATION));
		return field_status(reload_ticks);
	}
	const int64_t noise = p_resource->get_noise_radius_milliunits();
	if (noise < 0 || noise > wpn::MAX_NOISE_MILLIUNITS) {
		r_field = "noise_radius_milliunits";
		r_message = vformat("noise_radius_milliunits %d must be within [0, %d].", noise, int64_t(wpn::MAX_NOISE_MILLIUNITS));
		return field_status(noise);
	}
	const int64_t accuracy_moa_milli = p_resource->get_accuracy_moa_milli();
	if (accuracy_moa_milli < 0 || accuracy_moa_milli > wpn::MAX_ACCURACY_MOA_MILLI) {
		r_field = "accuracy_moa_milli";
		r_message = vformat("accuracy_moa_milli %d must be within [0, %d] (1000 = one MOA full group diameter).",
				accuracy_moa_milli, int64_t(wpn::MAX_ACCURACY_MOA_MILLI));
		return field_status(accuracy_moa_milli);
	}
	const TypedArray<WeaponAttachmentSlotResource> attachment_slots = p_resource->get_attachment_slots();
	if (attachment_slots.size() > int(wpn::MAX_ATTACHMENT_SLOTS_PER_WEAPON)) {
		r_field = "attachment_slots";
		r_message = vformat("attachment_slots has %d entries, at most %d are allowed.", attachment_slots.size(), int(wpn::MAX_ATTACHMENT_SLOTS_PER_WEAPON));
		return wpn::make_status(wpn::StatusCode::LIMIT_EXCEEDED, wpn::DiagnosticId::COUNT_LIMIT_EXCEEDED,
				std::uint64_t(attachment_slots.size()));
	}
	std::set<std::string> seen_slot_ids;
	for (int i = 0; i < attachment_slots.size(); ++i) {
		const Ref<WeaponAttachmentSlotResource> slot = attachment_slots[i];
		if (slot.is_null()) {
			r_field = vformat("attachment_slots[%d]", i);
			r_message = vformat("attachment_slots[%d] is empty.", i);
			return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT);
		}
		const String slot_id = String(slot->get_slot_id());
		status = wpn::validate_identifier(to_std(slot_id));
		if (!status.ok()) {
			r_field = vformat("attachment_slots[%d].slot_id", i);
			r_message = vformat("attachment_slots[%d].slot_id '%s' is invalid (needs >= 2 dotted/dashed/colon segments, [a-z][a-z0-9_]*).", i, slot_id);
			return status;
		}
		if (!seen_slot_ids.insert(to_std(slot_id)).second) {
			r_field = vformat("attachment_slots[%d].slot_id", i);
			r_message = vformat("attachment_slots[%d].slot_id '%s' duplicates an earlier slot in this weapon.", i, slot_id);
			return wpn::make_status(wpn::StatusCode::DUPLICATE_DEFINITION, wpn::DiagnosticId::DEFINITION_DUPLICATE);
		}
		if (to_attachment_slot_kind_bit(int(slot->get_slot_kind())) == 0) {
			r_field = vformat("attachment_slots[%d].slot_kind", i);
			r_message = vformat("attachment_slots[%d].slot_kind %d is not a known V1 slot kind.", i, int(slot->get_slot_kind()));
			return wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT, wpn::DiagnosticId::INVALID_ENUM,
					std::uint64_t(slot->get_slot_kind()));
		}
	}
	return wpn::ok_status();
}

} // namespace

Dictionary WeaponDefinitionCatalog::register_shot_profile(const Ref<HitscanShotProfileResource> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT), String(), String(), String("<null>"),
				"HitscanShotProfileResource is null.");
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "HitscanShotProfileResource");
	String field, message;
	wpn::Status status = precheck_shot_profile(p_resource, field, message);
	if (status.ok()) {
		status = catalog.add_shot_profile(to_shot_profile(p_resource));
		if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
			field = "identifier/version";
		}
	}
	return diagnostic_dict(status, field, identifier, source, message);
}

Dictionary WeaponDefinitionCatalog::register_recoil_profile(const Ref<RecoilProfileResource> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT), String(), String(), String("<null>"),
				"RecoilProfileResource is null.");
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "RecoilProfileResource");
	String field, message;
	wpn::Status status = precheck_recoil_profile(p_resource, field, message);
	if (status.ok()) {
		status = catalog.add_recoil_profile(to_recoil_profile(p_resource));
		if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
			field = "identifier/version";
		}
	}
	return diagnostic_dict(status, field, identifier, source, message);
}

Dictionary WeaponDefinitionCatalog::register_attachment(const Ref<AttachmentDefinitionResource> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT), String(), String(), String("<null>"),
				"AttachmentDefinitionResource is null.");
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "AttachmentDefinitionResource");
	String field, message;
	wpn::Status status = precheck_attachment(p_resource, field, message);
	if (status.ok()) {
		status = catalog.add_attachment(to_attachment_definition(p_resource));
		if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
			field = "identifier/version";
		}
	}
	return diagnostic_dict(status, field, identifier, source, message);
}

Dictionary WeaponDefinitionCatalog::register_ballistic_profile(const Ref<AmmunitionBallisticProfileResource> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT), String(), String(), String("<null>"),
				"AmmunitionBallisticProfileResource is null.");
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "AmmunitionBallisticProfileResource");
	String field, message;
	wpn::Status status = precheck_ballistic_profile(p_resource, field, message);
	if (status.ok()) {
		status = catalog.add_ammo_profile(to_ammo_profile(p_resource));
		if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
			field = "identifier/version";
		}
	}
	return diagnostic_dict(status, field, identifier, source, message);
}

Dictionary WeaponDefinitionCatalog::register_weapon(const Ref<WeaponDefinitionResource> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(wpn::make_status(wpn::StatusCode::INVALID_ARGUMENT), String(), String(), String("<null>"),
				"WeaponDefinitionResource is null.");
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "WeaponDefinitionResource");
	String field, message;
	wpn::Status status = precheck_weapon(p_resource, field, message);
	if (status.ok()) {
		status = catalog.add_weapon(to_weapon_definition(p_resource));
		if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
			field = "identifier/version";
		}
	}
	return diagnostic_dict(status, field, identifier, source, message);
}

Dictionary WeaponDefinitionCatalog::seal() {
	const wpn::Status status = catalog.seal();
	// `wpn::WeaponCatalog::seal()` (native/core/wpn_catalog.cpp) reports
	// DEFINITION_UNKNOWN_REFERENCE for EITHER an unknown shot_profile_id OR an
	// unknown recoil_profile_id on some registered weapon, without
	// identifying which reference or which weapon. This incremental
	// register()+seal() pair never retains registered Resources (see this
	// class's own doc comment), so -- unlike validate_catalog() below, which
	// still has every input array in hand -- it has no way to re-derive the
	// offending field. Naming a single hardcoded field here would misattribute
	// the failure roughly half the time now that BOTH references are
	// cross-checked, so `field` is intentionally left empty and `message`
	// names both candidates instead of guessing.
	const bool unknown_reference = status.diagnostic == wpn::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE;
	const String message = status.ok() ? String("Catalog sealed.") :
			(unknown_reference ?
							String("A weapon references a shot_profile_id or recoil_profile_id absent from this catalog; use validate_catalog() for per-field precision.") :
							String());
	return diagnostic_dict(status, String(), String(), String("<seal>"), message);
}

Dictionary WeaponDefinitionCatalog::validate_catalog(
		const TypedArray<HitscanShotProfileResource> &p_shot_profiles,
		const TypedArray<RecoilProfileResource> &p_recoil_profiles,
		const TypedArray<AttachmentDefinitionResource> &p_attachments,
		const TypedArray<AmmunitionBallisticProfileResource> &p_ammo_profiles,
		const TypedArray<WeaponDefinitionResource> &p_weapons,
		int p_max_findings) {
	Array findings;
	int total_findings = 0;
	const int max_findings = p_max_findings < 0 ? 0 : p_max_findings;

	auto record = [&](const Dictionary &p_finding) {
		++total_findings;
		if (findings.size() < max_findings) {
			findings.append(p_finding);
		}
	};

	// A fresh scratch catalog: never `this->catalog` (this is a static
	// method so there is no `this` catalog anyway) -- none of the input
	// arrays is ever registered into a live catalog by this call.
	wpn::WeaponCatalog scratch;

	// Accepted (id, version) pairs, tracked here (rather than re-derived from
	// `scratch`, whose find_*() accessors refuse to answer before seal())
	// so the weapon cross-reference check below can name the EXACT missing
	// field -- something the core's own `Status` cannot do (see seal()'s
	// comment above).
	using Key = std::pair<std::string, std::uint16_t>;
	std::set<Key> known_shot_profiles;
	std::set<Key> known_recoil_profiles;

	for (int i = 0; i < p_shot_profiles.size(); ++i) {
		const Ref<HitscanShotProfileResource> resource = p_shot_profiles[i];
		if (resource.is_null()) {
			record(make_finding("error", slot_label("shot_profiles", i), "", "null_resource",
					vformat("shot_profiles[%d] is empty.", i)));
			continue;
		}
		const String path = source_label_of(resource, "HitscanShotProfileResource");
		String field, message;
		wpn::Status status = precheck_shot_profile(resource, field, message);
		if (status.ok()) {
			status = scratch.add_shot_profile(to_shot_profile(resource));
			if (status.ok()) {
				known_shot_profiles.insert({ to_std(String(resource->get_identifier())), std::uint16_t(resource->get_version()) });
			} else if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
				field = "identifier/version";
			}
		}
		if (!status.ok()) {
			record(make_finding("error", path, field, status_code(status),
					!message.is_empty() ? message : status_code(status)));
		}
	}

	for (int i = 0; i < p_recoil_profiles.size(); ++i) {
		const Ref<RecoilProfileResource> resource = p_recoil_profiles[i];
		if (resource.is_null()) {
			record(make_finding("error", slot_label("recoil_profiles", i), "", "null_resource",
					vformat("recoil_profiles[%d] is empty.", i)));
			continue;
		}
		const String path = source_label_of(resource, "RecoilProfileResource");
		String field, message;
		wpn::Status status = precheck_recoil_profile(resource, field, message);
		if (status.ok()) {
			status = scratch.add_recoil_profile(to_recoil_profile(resource));
			if (status.ok()) {
				known_recoil_profiles.insert({ to_std(String(resource->get_identifier())), std::uint16_t(resource->get_version()) });
			} else if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
				field = "identifier/version";
			}
		}
		if (!status.ok()) {
			record(make_finding("error", path, field, status_code(status),
					!message.is_empty() ? message : status_code(status)));
		}
	}

	for (int i = 0; i < p_attachments.size(); ++i) {
		const Ref<AttachmentDefinitionResource> resource = p_attachments[i];
		if (resource.is_null()) {
			record(make_finding("error", slot_label("attachments", i), "", "null_resource",
					vformat("attachments[%d] is empty.", i)));
			continue;
		}
		const String path = source_label_of(resource, "AttachmentDefinitionResource");
		String field, message;
		wpn::Status status = precheck_attachment(resource, field, message);
		if (status.ok()) {
			status = scratch.add_attachment(to_attachment_definition(resource));
			if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
				field = "identifier/version";
			}
		}
		if (!status.ok()) {
			record(make_finding("error", path, field, status_code(status),
					!message.is_empty() ? message : status_code(status)));
		}
	}

	for (int i = 0; i < p_ammo_profiles.size(); ++i) {
		const Ref<AmmunitionBallisticProfileResource> resource = p_ammo_profiles[i];
		if (resource.is_null()) {
			record(make_finding("error", slot_label("ammo_profiles", i), "", "null_resource",
					vformat("ammo_profiles[%d] is empty.", i)));
			continue;
		}
		const String path = source_label_of(resource, "AmmunitionBallisticProfileResource");
		String field, message;
		wpn::Status status = precheck_ballistic_profile(resource, field, message);
		if (status.ok()) {
			status = scratch.add_ammo_profile(to_ammo_profile(resource));
			if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
				field = "identifier/version";
			}
		}
		if (!status.ok()) {
			record(make_finding("error", path, field, status_code(status),
					!message.is_empty() ? message : status_code(status)));
		}
	}

	// Whenever a weapon is individually valid but references a shot/recoil
	// profile absent from THIS batch, record it here (mirrors
	// `wpn::validate_catalog_batch()`'s own cross-reference lambdas in
	// native/core/wpn_catalog.cpp) so `scratch.add_weapon()` -- which, like
	// the core's `add_weapon()`, only checks per-definition fields -- is
	// followed by a precise, field-identifying finding instead of the
	// ambiguous generic one `seal()` alone could produce.
	bool any_missing_reference = false;
	for (int i = 0; i < p_weapons.size(); ++i) {
		const Ref<WeaponDefinitionResource> resource = p_weapons[i];
		if (resource.is_null()) {
			record(make_finding("error", slot_label("weapons", i), "", "null_resource",
					vformat("weapons[%d] is empty.", i)));
			continue;
		}
		const String path = source_label_of(resource, "WeaponDefinitionResource");
		String field, message;
		wpn::Status status = precheck_weapon(resource, field, message);
		if (status.ok()) {
			status = scratch.add_weapon(to_weapon_definition(resource));
			if (status.code == wpn::StatusCode::DUPLICATE_DEFINITION) {
				field = "identifier/version";
			}
		}
		if (!status.ok()) {
			record(make_finding("error", path, field, status_code(status),
					!message.is_empty() ? message : status_code(status)));
			continue;
		}
		const Key shot_key = { to_std(String(resource->get_shot_profile_id())), std::uint16_t(resource->get_shot_profile_version()) };
		if (known_shot_profiles.find(shot_key) == known_shot_profiles.end()) {
			any_missing_reference = true;
			record(make_finding("error", path, "shot_profile_id", "unknown_reference",
					vformat("shot_profile_id '%s' (version %d) is absent from this batch.", String(resource->get_shot_profile_id()), resource->get_shot_profile_version())));
		}
		const Key recoil_key = { to_std(String(resource->get_recoil_profile_id())), std::uint16_t(resource->get_recoil_profile_version()) };
		if (known_recoil_profiles.find(recoil_key) == known_recoil_profiles.end()) {
			any_missing_reference = true;
			record(make_finding("error", path, "recoil_profile_id", "unknown_reference",
					vformat("recoil_profile_id '%s' (version %d) is absent from this batch.", String(resource->get_recoil_profile_id()), resource->get_recoil_profile_version())));
		}
	}

	const wpn::Status seal_status = scratch.seal();
	if (!seal_status.ok() && !any_missing_reference) {
		// Defensive fallback: every current seal() failure mode is the
		// unknown-reference check already covered above, but this stays
		// correct if the core ever adds another seal()-time check.
		record(make_finding("error", String("<seal>"), String(), status_code(seal_status), String("Catalog failed to seal.")));
	}

	Dictionary result;
	result["findings"] = findings;
	result["ok"] = total_findings == 0;
	result["truncated"] = total_findings > findings.size();
	result["truncated_count"] = total_findings > findings.size() ? total_findings - findings.size() : 0;
	result["fingerprint"] = seal_status.ok() ? int64_t(scratch.fingerprint()) : int64_t(0);
	return result;
}

void WeaponDefinitionCatalog::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_shot_profile", "resource"), &WeaponDefinitionCatalog::register_shot_profile);
	ClassDB::bind_method(D_METHOD("register_recoil_profile", "resource"), &WeaponDefinitionCatalog::register_recoil_profile);
	ClassDB::bind_method(D_METHOD("register_attachment", "resource"), &WeaponDefinitionCatalog::register_attachment);
	ClassDB::bind_method(D_METHOD("register_ballistic_profile", "resource"), &WeaponDefinitionCatalog::register_ballistic_profile);
	ClassDB::bind_method(D_METHOD("register_weapon", "resource"), &WeaponDefinitionCatalog::register_weapon);
	ClassDB::bind_method(D_METHOD("seal"), &WeaponDefinitionCatalog::seal);
	ClassDB::bind_method(D_METHOD("is_sealed"), &WeaponDefinitionCatalog::is_sealed);
	ClassDB::bind_method(D_METHOD("fingerprint"), &WeaponDefinitionCatalog::fingerprint);
	ClassDB::bind_method(D_METHOD("shot_profile_count"), &WeaponDefinitionCatalog::shot_profile_count);
	ClassDB::bind_method(D_METHOD("recoil_profile_count"), &WeaponDefinitionCatalog::recoil_profile_count);
	ClassDB::bind_method(D_METHOD("attachment_count"), &WeaponDefinitionCatalog::attachment_count);
	ClassDB::bind_method(D_METHOD("ammo_profile_count"), &WeaponDefinitionCatalog::ammo_profile_count);
	ClassDB::bind_method(D_METHOD("weapon_count"), &WeaponDefinitionCatalog::weapon_count);
	ClassDB::bind_static_method("WeaponDefinitionCatalog",
			D_METHOD("validate_catalog", "shot_profiles", "recoil_profiles", "attachments", "ammo_profiles", "weapons", "max_findings"),
			&WeaponDefinitionCatalog::validate_catalog, DEFVAL(DEFAULT_MAX_FINDINGS));

	BIND_ENUM_CONSTANT(STATUS_OK);
	BIND_ENUM_CONSTANT(STATUS_INVALID_ARGUMENT);
	BIND_ENUM_CONSTANT(STATUS_NOT_FOUND);
	BIND_ENUM_CONSTANT(STATUS_ALREADY_EXISTS);
	BIND_ENUM_CONSTANT(STATUS_LIMIT_EXCEEDED);
	BIND_ENUM_CONSTANT(STATUS_NOT_SUPPORTED);
	BIND_ENUM_CONSTANT(STATUS_INTERNAL_ERROR);
	BIND_ENUM_CONSTANT(STATUS_INVALID_IDENTIFIER);
	BIND_ENUM_CONSTANT(STATUS_DUPLICATE_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_INVALID_REFERENCE);
	BIND_ENUM_CONSTANT(STATUS_CATALOG_SEALED);
	BIND_ENUM_CONSTANT(STATUS_CATALOG_NOT_SEALED);
	BIND_ENUM_CONSTANT(STATUS_MANIFEST_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_PROTOCOL_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_SCHEMA_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_FEATURE_UNSUPPORTED);
	BIND_ENUM_CONSTANT(STATUS_API_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_REVISION_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_DUPLICATE_CONFLICT);
	BIND_ENUM_CONSTANT(STATUS_COMMAND_REJECTED);
	BIND_ENUM_CONSTANT(STATUS_SNAPSHOT_REQUIRED);
}

} // namespace godot
