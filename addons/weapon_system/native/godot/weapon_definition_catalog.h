#ifndef WEAPON_SYSTEM_GODOT_DEFINITION_CATALOG_H
#define WEAPON_SYSTEM_GODOT_DEFINITION_CATALOG_H

#include "core/wpn_catalog.h"

#include "resources/ammunition_ballistic_profile_resource.h"
#include "resources/attachment_definition_resource.h"
#include "resources/hitscan_shot_profile_resource.h"
#include "resources/recoil_profile_resource.h"
#include "resources/weapon_attachment_slot_resource.h"
#include "resources/weapon_definition_resource.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>

// One of the few files in native/godot/ that includes core/wpn_catalog.h and
// core/wpn_definitions.h directly (matching inventory_system's
// InventoryCatalog / gameplay_abilities' GameplayDefinitionValidator
// precedent) -- it is the copy-and-seal adapter between mutable authoring
// Resources (native/resources/) and the engine-independent, immutable
// `wpn::WeaponCatalog`.
namespace godot {

// Owns one `wpn::WeaponCatalog` and exposes it only through
// validate/register/seal/query methods -- there is no accessor that returns
// a mutable reference to it. Every register_*() method VALIDATES and COPIES
// its input Resource's CURRENT field values into the sealed native catalog
// via the core's own `wpn::HitscanShotProfile::validate()` /
// `wpn::WeaponDefinition::validate()` / `wpn::WeaponCatalog::add_*()`/`seal()`
// calls (native/core/wpn_catalog.h, wpn_definitions.h): p_resource itself is
// never retained or mutated, so later mutation of an authoring Resource can
// never reach an already-sealed catalog (weapon-authoring spec.md
// "Immutable Versioned Weapon Definitions").
//
// Recoil profiles, attachment definitions, and ammunition-ballistic profiles
// (design.md "Definition model") follow this exact same validate-then-copy
// shape via `register_recoil_profile()`/`register_attachment()`/
// `register_ballistic_profile()` below.
class WeaponDefinitionCatalog : public RefCounted {
	GDCLASS(WeaponDefinitionCatalog, RefCounted)

public:
	// Mirrors `wpn::StatusCode` exactly (native/core/wpn_status.h).
	enum StatusCode {
		STATUS_OK = 0,
		STATUS_INVALID_ARGUMENT = 1,
		STATUS_NOT_FOUND = 2,
		STATUS_ALREADY_EXISTS = 3,
		STATUS_LIMIT_EXCEEDED = 4,
		STATUS_NOT_SUPPORTED = 5,
		STATUS_INTERNAL_ERROR = 6,
		STATUS_INVALID_IDENTIFIER = 20,
		STATUS_DUPLICATE_DEFINITION = 21,
		STATUS_UNKNOWN_DEFINITION = 22,
		STATUS_INVALID_REFERENCE = 23,
		STATUS_CATALOG_SEALED = 24,
		STATUS_CATALOG_NOT_SEALED = 25,
		STATUS_MANIFEST_MISMATCH = 40,
		STATUS_PROTOCOL_MISMATCH = 41,
		STATUS_SCHEMA_MISMATCH = 42,
		STATUS_FEATURE_UNSUPPORTED = 43,
		STATUS_API_MISMATCH = 44,
		STATUS_REVISION_MISMATCH = 60,
		STATUS_DUPLICATE_CONFLICT = 61,
		STATUS_COMMAND_REJECTED = 62,
		STATUS_SNAPSHOT_REQUIRED = 63,
	};

	// Default cap for validate_catalog()'s bounded findings array
	// (weapon-authoring spec.md "Bounded Catalog Diagnostics"). A plain
	// compile-time constant (not a ClassDB-bound property) -- callers that
	// need a different bound pass it explicitly.
	static constexpr int DEFAULT_MAX_FINDINGS = 64;

	// Each VALIDATES p_resource's current field values (both this addon's
	// own field-level pre-checks -- see weapon_definition_catalog.cpp's
	// `precheck_*` -- and the core's own `validate()`/`add_*()`) and, only on
	// success, COPIES the canonicalized value into this catalog. p_resource
	// is never retained. Returns one stable-shape diagnostic Dictionary
	// {status_code, diagnostic, detail, field, identifier, source, message};
	// "field" names the offending authored property when this catalog can
	// identify it (empty for a catalog-level failure such as
	// STATUS_LIMIT_EXCEEDED).
	Dictionary register_shot_profile(const Ref<HitscanShotProfileResource> &p_resource);
	Dictionary register_recoil_profile(const Ref<RecoilProfileResource> &p_resource);
	// Rejects a nonzero `AttachmentDefinitionResource.provided_slot_count`
	// (field "provided_slot_count") before it ever reaches the core:
	// nested/attachment-provided slots are unsupported in V1
	// (weapon-authoring spec.md "Versioned Recoil and Flat Attachment
	// Definitions": "Attachment recursively provides another slot").
	Dictionary register_attachment(const Ref<AttachmentDefinitionResource> &p_resource);
	Dictionary register_ballistic_profile(const Ref<AmmunitionBallisticProfileResource> &p_resource);
	Dictionary register_weapon(const Ref<WeaponDefinitionResource> &p_resource);

	// Seals the catalog: no further register_*() call succeeds afterward.
	// Fails closed (STATUS_INVALID_REFERENCE) when a registered weapon names
	// a shot profile or recoil profile absent from this catalog. The core's
	// `Status` does not distinguish which of the two references failed (see
	// weapon_definition_catalog.cpp), so `field` is left empty here and
	// `message` names both candidates; use `validate_catalog()` below before
	// registering when per-field precision is needed.
	Dictionary seal();
	bool is_sealed() const { return catalog.sealed(); }
	int64_t fingerprint() const { return catalog.sealed() ? int64_t(catalog.fingerprint()) : 0; }
	int shot_profile_count() const { return int(catalog.shot_profile_count()); }
	int recoil_profile_count() const { return int(catalog.recoil_profile_count()); }
	int attachment_count() const { return int(catalog.attachment_count()); }
	int ammo_profile_count() const { return int(catalog.ammo_profile_count()); }
	int weapon_count() const { return int(catalog.weapon_count()); }

	// Runs the SAME validation register_*()/seal() above perform, over a
	// scratch catalog that is discarded afterward -- none of the input
	// arrays is ever registered into `this`, and this catalog's own
	// sealed/registered state is unaffected either way (mirrors
	// InventoryCatalog::validate_resource()'s "never registers" contract).
	// Findings accumulate in stable definition (array) order up to
	// p_max_findings; the returned Dictionary's "truncated" key is true (and
	// "truncated_count" the remaining count) when more findings existed than
	// the bound allowed (weapon-authoring spec.md "Bounded Catalog
	// Diagnostics": "Catalog contains many invalid definitions"). Each
	// finding is {severity, resource_path, field, code, message}. Unlike the
	// incremental register()+seal() pair above, this call keeps every input
	// array in hand for its own duration, so it CAN and DOES identify
	// exactly which weapon and which field (shot_profile_id vs
	// recoil_profile_id) names an unknown reference. Pure C++ over Resource
	// getters -- usable in editor, headless, and export builds.
	static Dictionary validate_catalog(
			const TypedArray<HitscanShotProfileResource> &p_shot_profiles,
			const TypedArray<RecoilProfileResource> &p_recoil_profiles,
			const TypedArray<AttachmentDefinitionResource> &p_attachments,
			const TypedArray<AmmunitionBallisticProfileResource> &p_ammo_profiles,
			const TypedArray<WeaponDefinitionResource> &p_weapons,
			int p_max_findings = DEFAULT_MAX_FINDINGS);

protected:
	static void _bind_methods();

private:
	wpn::WeaponCatalog catalog;
};

} // namespace godot

VARIANT_ENUM_CAST(WeaponDefinitionCatalog::StatusCode);

#endif // WEAPON_SYSTEM_GODOT_DEFINITION_CATALOG_H
