#include "core/wpn_definitions.h"

#include "core/wpn_hash.h"
#include "core/wpn_identifier.h"
#include "core/wpn_limits.h"

#include <algorithm>
#include <set>

namespace wpn {

Status HitscanShotProfile::validate() const {
	Status status = validate_identifier(id);
	if (!status.ok()) return status;
	if (version == 0) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	if (damage_milliunits <= 0 || damage_milliunits > MAX_DAMAGE_MILLIUNITS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, static_cast<std::uint64_t>(damage_milliunits));
	}
	if (range_milliunits <= 0 || range_milliunits > MAX_WORLD_MILLIUNITS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, static_cast<std::uint64_t>(range_milliunits));
	}
	if (spread_microradians < 0 || spread_microradians > MAX_ANGLE_MICRORADIANS ||
			aim_tolerance_microradians < 0 || aim_tolerance_microradians > MAX_ANGLE_MICRORADIANS ||
			origin_tolerance_milliunits < 0 || origin_tolerance_milliunits > MAX_WORLD_MILLIUNITS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	return ok_status();
}

std::uint64_t HitscanShotProfile::fingerprint() const {
	Hasher h;
	h.write_string(id);
	h.write_u16(version);
	h.write_i64(damage_milliunits);
	h.write_i64(range_milliunits);
	h.write_i64(spread_microradians);
	h.write_i64(aim_tolerance_microradians);
	h.write_i64(origin_tolerance_milliunits);
	return h.digest();
}

Status RecoilProfile::validate() const {
	Status status = validate_identifier(id);
	if (!status.ok()) return status;
	if (version == 0) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	if (vertical_kick_nrad < 0 || vertical_kick_nrad > MAX_RECOIL_KICK_NRAD) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(vertical_kick_nrad));
	}
	if (horizontal_kick_min_nrad < -MAX_RECOIL_KICK_NRAD || horizontal_kick_max_nrad > MAX_RECOIL_KICK_NRAD ||
			horizontal_kick_min_nrad > horizontal_kick_max_nrad) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (recovery_per_tick_nrad <= 0 || recovery_per_tick_nrad > MAX_RECOVERY_PER_TICK_NRAD) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(recovery_per_tick_nrad));
	}
	const std::int64_t max_abs_horizontal_kick = std::max(std::llabs(horizontal_kick_min_nrad), std::llabs(horizontal_kick_max_nrad));
	if (max_vertical_offset_nrad < vertical_kick_nrad || max_vertical_offset_nrad > MAX_RECOIL_OFFSET_NRAD ||
			max_horizontal_offset_nrad < max_abs_horizontal_kick || max_horizontal_offset_nrad > MAX_RECOIL_OFFSET_NRAD) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	return ok_status();
}

std::uint64_t RecoilProfile::fingerprint() const {
	Hasher h;
	h.write_string(id);
	h.write_u16(version);
	h.write_i64(vertical_kick_nrad);
	h.write_i64(horizontal_kick_min_nrad);
	h.write_i64(horizontal_kick_max_nrad);
	h.write_i64(recovery_per_tick_nrad);
	h.write_i64(max_vertical_offset_nrad);
	h.write_i64(max_horizontal_offset_nrad);
	return h.digest();
}

Status AttachmentDefinition::validate() const {
	Status status = validate_identifier(id);
	if (!status.ok()) return status;
	if (version == 0) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	if (provided_slot_count != 0) {
		return make_status(StatusCode::NOT_SUPPORTED, DiagnosticId::NESTED_ATTACHMENT_REJECTED, provided_slot_count);
	}
	if (compatible_slot_kinds_mask == 0 || (compatible_slot_kinds_mask & ~ALL_ATTACHMENT_SLOT_KINDS) != 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, compatible_slot_kinds_mask);
	}
	if (compatible_tags.size() > MAX_ATTACHMENT_COMPATIBLE_TAGS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, compatible_tags.size());
	}
	std::set<std::string> unique_tags;
	for (const std::string &tag : compatible_tags) {
		status = validate_identifier(tag);
		if (!status.ok()) return status;
		if (!unique_tags.insert(tag).second) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
		}
	}
	const std::int64_t deltas[] = {
		accuracy_modifier_ppm,
		recoil_modifier_ppm,
		noise_modifier_ppm,
		reload_duration_modifier_ppm,
		cadence_modifier_ppm,
	};
	for (std::int64_t delta : deltas) {
		if (delta < -MAX_MODIFIER_DELTA_PPM || delta > MAX_MODIFIER_DELTA_PPM) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, static_cast<std::uint64_t>(delta));
		}
	}
	return ok_status();
}

std::uint64_t AttachmentDefinition::fingerprint() const {
	Hasher h;
	h.write_string(id);
	h.write_u16(version);
	h.write_u32(compatible_slot_kinds_mask);
	std::vector<std::string> sorted_tags = compatible_tags;
	std::sort(sorted_tags.begin(), sorted_tags.end());
	h.write_u32(static_cast<std::uint32_t>(sorted_tags.size()));
	for (const std::string &tag : sorted_tags) h.write_string(tag);
	h.write_i64(accuracy_modifier_ppm);
	h.write_i64(recoil_modifier_ppm);
	h.write_i64(noise_modifier_ppm);
	h.write_i64(reload_duration_modifier_ppm);
	h.write_i64(cadence_modifier_ppm);
	h.write_u32(provided_slot_count);
	return h.digest();
}

Status AmmunitionBallisticProfile::validate() const {
	Status status = validate_identifier(id);
	if (!status.ok()) return status;
	if (version == 0) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	return validate_identifier(ammunition_trait);
}

std::uint64_t AmmunitionBallisticProfile::fingerprint() const {
	Hasher h;
	h.write_string(id);
	h.write_u16(version);
	h.write_string(ammunition_trait);
	return h.digest();
}

Status WeaponDefinition::validate() const {
	Status status = validate_identifier(id);
	if (!status.ok()) return status;
	status = validate_identifier(shot_profile_id);
	if (!status.ok()) return status;
	status = validate_identifier(ammunition_trait);
	if (!status.ok()) return status;
	status = validate_identifier(recoil_profile_id);
	if (!status.ok()) return status;
	if (version == 0 || shot_profile_version == 0 || recoil_profile_version == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (mechanism != WeaponMechanism::HITSCAN_2D || fire_mode != FireMode::SEMI_AUTO) {
		return make_status(StatusCode::NOT_SUPPORTED, DiagnosticId::INVALID_ENUM);
	}
	if (capacity == 0 || capacity > MAX_CAPACITY ||
			cadence_ticks == 0 || cadence_ticks > MAX_TICK_DURATION ||
			reload_ticks == 0 || reload_ticks > MAX_TICK_DURATION || noise_radius_milliunits < 0 ||
			noise_radius_milliunits > MAX_NOISE_MILLIUNITS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (accuracy_moa_milli < 0 || accuracy_moa_milli > MAX_ACCURACY_MOA_MILLI) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(accuracy_moa_milli));
	}
	if (attachment_slots.size() > MAX_ATTACHMENT_SLOTS_PER_WEAPON) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, attachment_slots.size());
	}
	std::set<std::string> unique_slot_ids;
	for (const WeaponAttachmentSlot &slot : attachment_slots) {
		status = validate_identifier(slot.slot_id);
		if (!status.ok()) return status;
		if (!unique_slot_ids.insert(slot.slot_id).second) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
		}
		const std::uint32_t kind_bit = static_cast<std::uint32_t>(slot.slot_kind);
		if ((kind_bit & ALL_ATTACHMENT_SLOT_KINDS) == 0 || (kind_bit & (kind_bit - 1)) != 0) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, kind_bit);
		}
	}
	return ok_status();
}

std::uint64_t WeaponDefinition::fingerprint() const {
	Hasher h;
	h.write_string(id);
	h.write_u16(version);
	h.write_u8(static_cast<std::uint8_t>(mechanism));
	h.write_u8(static_cast<std::uint8_t>(fire_mode));
	h.write_string(shot_profile_id);
	h.write_u16(shot_profile_version);
	h.write_string(ammunition_trait);
	h.write_u32(capacity);
	h.write_u32(cadence_ticks);
	h.write_u32(reload_ticks);
	h.write_i64(noise_radius_milliunits);
	h.write_i64(accuracy_moa_milli);
	h.write_string(recoil_profile_id);
	h.write_u16(recoil_profile_version);
	// Attachment slots are order-sensitive by design (design.md, "Flat
	// attachment loadout" declares a *bounded ordered set* of stable slot
	// IDs), so they are hashed in authored order rather than re-sorted.
	h.write_u32(static_cast<std::uint32_t>(attachment_slots.size()));
	for (const WeaponAttachmentSlot &slot : attachment_slots) {
		h.write_string(slot.slot_id);
		h.write_u32(static_cast<std::uint32_t>(slot.slot_kind));
	}
	return h.digest();
}

} // namespace wpn
