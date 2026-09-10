#ifndef WEAPON_SYSTEM_GODOT_WEAPON_AUTHORITY_H
#define WEAPON_SYSTEM_GODOT_WEAPON_AUTHORITY_H

#include "core/wpn_catalog.h"
#include "core/wpn_runtime.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>

namespace godot {

// Dictionary/value façade over `wpn::WeaponCatalog` + `wpn::WeaponRuntime`
// (native/core/wpn_catalog.h, wpn_runtime.h). Every mutating method here
// VALIDATES and COPIES its Dictionary/Array arguments' current values before
// handing them to the core -- no Dictionary/Array/Resource is ever retained,
// so later mutation of a caller's input can never reach already-configured
// authority state (weapon-authoring spec.md "Immutable Versioned Weapon
// Definitions"; mirrors `WeaponDefinitionCatalog`'s own copy-then-seal
// contract for the Resource-based authoring path).
class WeaponAuthority : public Node {
	GDCLASS(WeaponAuthority, Node)

public:
	enum Role {
		ROLE_OFFLINE_AUTHORITY = 0,
		ROLE_SERVER_AUTHORITY = 1,
	};

	void set_role(Role p_role) { role = p_role; }
	Role get_role() const { return role; }

	// `p_weapons[i]` entries now additionally accept `recoil_profile_id`
	// (REQUIRED, exactly like `shot_profile_id`), `recoil_profile_version`,
	// `accuracy_moa_milli`, and `attachment_slots` (an Array of
	// {slot_id: String, slot_kind: int} where slot_kind is a
	// `wpn::AttachmentSlotKind` BIT value: Optic=1, Muzzle=2, Stock=4,
	// Grip=8 -- the SAME bitmask vocabulary `p_attachments[i]`'s
	// `compatible_slot_kinds_mask` uses). `p_recoil_profiles`/`p_attachments`/
	// `p_ammo_profiles` mirror `p_shot_profiles`'s Dictionary-array shape for
	// their respective `wpn::RecoilProfile`/`wpn::AttachmentDefinition`/
	// `wpn::AmmunitionBallisticProfile` fields. Every recoil/attachment/
	// ammo-profile Dictionary is strictly checked for unknown keys before
	// conversion (weapon-runtime façade contract: "reject unknown keys ...
	// with actionable diagnostics").
	Dictionary configure(
			const Array &p_shot_profiles,
			const Array &p_weapons,
			const Array &p_recoil_profiles = Array(),
			const Array &p_attachments = Array(),
			const Array &p_ammo_profiles = Array());
	bool is_ready() const { return runtime != nullptr; }
	int64_t content_fingerprint() const;

	// `p_profile` ({id: String, version: int}) is REQUIRED exactly when
	// `p_loaded_rounds > 0` (weapon-runtime spec, "Deterministic Weapon
	// Instance State"); pass an empty Dictionary otherwise. `p_authority_scope`/
	// `p_authority_epoch` bind the instance's authority envelope (weapon-
	// runtime spec, "Canonical Revision and Authority-Tick Semantics");
	// default to the empty scope/epoch 0, matching every command's own
	// default so existing single-scope callers keep working unchanged.
	Dictionary create_weapon(
			const String &p_instance_id,
			const String &p_definition_id,
			int p_definition_version = 1,
			int p_loaded_rounds = 0,
			const Dictionary &p_profile = Dictionary(),
			const String &p_authority_scope = String(),
			int64_t p_authority_epoch = 0);
	// Administrative removal: erases the instance immediately without going
	// through the admitted command gate or leaving a tombstone. Used by
	// projection code (e.g. the inventory adapter) reconciling an unequip.
	// For an AUTHORITATIVE, idempotent, tombstone-leaving removal driven by a
	// client/owner command, use `teardown()` below instead.
	Dictionary remove_weapon(const String &p_instance_id);
	Dictionary snapshot(const String &p_instance_id) const;
	Array snapshots() const;
	Dictionary replace_snapshots(const Array &p_snapshots);

	// C++-only accessors (tasks.md 7.5) for a native/godot peer -- e.g.
	// WeaponNetworkBridge encoding a canonical wire snapshot/delta/tombstone
	// -- that needs the CORE value directly rather than round-tripping
	// through the Dictionary/Variant façade above. Never bound to GDScript
	// (no ClassDB registration below); `p_instance_id` is a std::string, not
	// a Godot String, on purpose. nullptr exactly when `snapshot()`/
	// `tombstone()` above would report `not found`/`found=false`.
	const wpn::WeaponSnapshot *find_snapshot(const std::string &p_instance_id) const {
		return runtime == nullptr ? nullptr : runtime->find_instance(p_instance_id);
	}
	const wpn::WeaponTombstone *find_tombstone_value(const std::string &p_instance_id) const {
		return runtime == nullptr ? nullptr : runtime->find_tombstone(p_instance_id);
	}

	// C++-only fire entry point (tasks.md 7.5) for a native/godot peer (e.g.
	// WeaponNetworkBridge) that already holds a trusted core::FireCommand
	// (built server-side from an admitted wire FireIntent plus the bridge's
	// own trusted tick/authority envelope) and needs the CORE
	// `wpn::CommandOutcome` -- including its `shot` (`std::optional<
	// CommittedShot>`), which the Dictionary-shaped `fire()` below cannot
	// losslessly hand back to C++ callers -- rather than round-tripping
	// through Dictionary/Variant. Emits the exact same
	// `shot_committed`/`command_rejected`/`recoil_anchor_changed` signals
	// `fire()` below does; the two differ only in how the caller supplies
	// the command and receives the result, never in behavior.
	wpn::CommandOutcome fire_native(const wpn::FireCommand &p_command, const wpn::AuthorityContext &p_authority);

	Dictionary fire(const Dictionary &p_command, const Dictionary &p_authority);
	// `p_command` now additionally REQUIRES a `profile` sub-Dictionary
	// ({id: String, version: int}) -- the exact ballistic-profile identity
	// this reservation carries (weapon-runtime spec, "Simple Tick-Based
	// Reload").
	Dictionary begin_reload(const Dictionary &p_command);
	Dictionary cancel_reload(const Dictionary &p_command);
	// Atomically replaces an instance's complete accepted attachment loadout
	// (weapon-runtime spec, "Atomic Flat Attachment Loadout"). `p_command`'s
	// `desired_loadout` is an Array of {slot_id: String, attachment_id:
	// String, attachment_version: int}; a declared slot the game wants empty
	// is simply absent, never a null/empty entry. Emits
	// `attachment_loadout_changed` on acceptance.
	Dictionary configure_attachments(const Dictionary &p_command);
	// Authoritative, idempotent teardown: removes the instance, releases any
	// active reload reservation (via the returned `reservation_to_release`,
	// exactly like a cancelled reload), and leaves a bounded, queryable
	// tombstone (see `tombstone()` below) -- weapon-runtime spec's revision
	// matrix, "teardown/tombstone".
	Dictionary teardown(const Dictionary &p_command);
	Array due_reloads(int64_t p_tick) const;
	Dictionary commit_due_reload(
			int64_t p_tick,
			const String &p_instance_id,
			const String &p_reservation_id);
	void publish_reload_completion(const Dictionary &p_completion);
	Array advance_tick(int64_t p_tick);

	// {found: bool, instance_id, authority_scope, authority_epoch, revision}.
	// `found` is false (and every other key absent) when no tombstone is on
	// record for `p_instance_id` -- either it was never torn down, or its
	// tombstone aged out of the bounded MAX_TOMBSTONES retention.
	Dictionary tombstone(const String &p_instance_id) const;
	// Pure read-only recoil query at `p_authority_tick` (tasks.md 4.10):
	// {ok, status, vertical_offset_nrad, horizontal_offset_nrad}. Presenters
	// derive per-frame recovery from the returned anchor + tick themselves;
	// this façade deliberately has no per-tick "canonical recovery" signal.
	Dictionary effective_recoil(const String &p_instance_id, int64_t p_authority_tick) const;
	// Pure read-only aggregate-modifier query over an instance's CURRENT
	// accepted attachment loadout only (no authority-supplied delta folded
	// in, unlike the fire-time computation): {ok, status,
	// accuracy_multiplier_ppm, recoil_multiplier_ppm, noise_multiplier_ppm,
	// reload_duration_multiplier_ppm, cadence_multiplier_ppm}. Each
	// `*_multiplier_ppm` is `wpn::fold_modifier_deltas_ppm()`'s aggregate
	// multiplier around `wpn::MODIFIER_NEUTRAL_PPM` (1000000 == neutral).
	Dictionary effective_modifiers(const String &p_instance_id) const;
	// {has_profile: bool, id, version}. `has_profile` is false (id/version
	// absent) exactly when the instance currently holds zero loaded rounds.
	Dictionary loaded_profile(const String &p_instance_id) const;

protected:
	static void _bind_methods();

private:
	static Dictionary status_dict(const wpn::Status &p_status);
	static Dictionary snapshot_dict(const wpn::WeaponSnapshot &p_snapshot);
	static Dictionary completion_dict(const wpn::ReloadCompletion &p_completion);
	static Dictionary outcome_dict(const wpn::CommandOutcome &p_outcome);
	static Dictionary tombstone_dict(const wpn::WeaponTombstone &p_tombstone);
	static wpn::FixedVec2 fixed_vec_from_dict(const Dictionary &p_value);
	static wpn::AuthorityContext authority_from_dict(const Dictionary &p_value);
	static Dictionary profile_dict(const std::optional<wpn::BallisticProfileIdentity> &p_value);

	Role role = ROLE_OFFLINE_AUTHORITY;
	std::unique_ptr<wpn::WeaponCatalog> catalog;
	std::unique_ptr<wpn::WeaponRuntime> runtime;
};

} // namespace godot

VARIANT_ENUM_CAST(WeaponAuthority::Role);

#endif // WEAPON_SYSTEM_GODOT_WEAPON_AUTHORITY_H
