#ifndef INVENTORY_SYSTEM_GODOT_UTIL_H
#define INVENTORY_SYSTEM_GODOT_UTIL_H

#include "core/inv_ids.h"
#include "core/inv_runtime_state.h"
#include "core/inv_snapshot.h"
#include "core/inv_status.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Small Godot-Variant <-> engine-independent-core conversions shared by every
// native/godot/ file in this addon, mirroring gameplay_abilities' own
// gameplay_ability_godot_util.h precedent (same rationale: every conversion
// below is a two-to-fifteen line adapter with nothing to gain from an
// out-of-line definition, so this stays a header-only set of `inline` free
// functions in `namespace godot`, the namespace every Godot-facing class in
// this addon already lives in).
namespace godot {

// Godot String -> UTF-8 std::string.
inline std::string to_std(const String &p_value) {
	const CharString utf8 = p_value.utf8();
	return std::string(utf8.get_data());
}

// Clamps a script-supplied int64 (Dictionary/Variant fields arrive as int64)
// into an `inv::Handle<Tag>` -- a negative value folds to the invalid (zero)
// handle rather than wrapping into a huge unsigned id.
template <typename Tag>
inline inv::Handle<Tag> to_handle(int64_t p_value) {
	return inv::Handle<Tag>{ static_cast<std::uint64_t>(p_value < 0 ? 0 : p_value) };
}

inline inv::InventoryId to_inventory_id(int64_t p_value) { return to_handle<inv::InventoryIdTag>(p_value); }
inline inv::ContainerInstanceId to_container_id(int64_t p_value) { return to_handle<inv::ContainerInstanceIdTag>(p_value); }
inline inv::ItemInstanceId to_item_id(int64_t p_value) { return to_handle<inv::ItemInstanceIdTag>(p_value); }
inline inv::ReferenceId to_reference_id(int64_t p_value) { return to_handle<inv::ReferenceIdTag>(p_value); }
inline inv::ExternalOwnerId to_external_owner_id(int64_t p_value) { return to_handle<inv::ExternalOwnerIdTag>(p_value); }
inline inv::CommandId to_command_id(int64_t p_value) { return to_handle<inv::CommandIdTag>(p_value); }

// `inv::Status` -> the {code:int, diagnostic:int, detail:int, ok:bool}
// Dictionary shape every result/diagnostic surfaces it as (matches
// gameplay_abilities' `status_dict` precedent, field-for-field).
inline Dictionary status_dict(const inv::Status &p_status) {
	Dictionary d;
	d["code"] = int(p_status.code);
	d["diagnostic"] = int(p_status.diagnostic);
	d["detail"] = int64_t(p_status.detail);
	d["ok"] = p_status.ok();
	return d;
}

// Stable-path diagnostic Dictionary shape every `InventoryCatalog`
// registration/validation finding uses (design task 7.1's explicit
// contract): {status_code, diagnostic, detail, identifier, source}.
inline Dictionary diagnostic_dict(const inv::Status &p_status, const String &p_identifier, const String &p_source) {
	Dictionary d;
	d["status_code"] = int(p_status.code);
	d["diagnostic"] = int(p_status.diagnostic);
	d["detail"] = int64_t(p_status.detail);
	d["identifier"] = p_identifier;
	d["source"] = p_source;
	return d;
}

// `std::vector<uint8_t>` (core/protocol's own wire-bytes type) -> Godot's
// `PackedByteArray`.
inline PackedByteArray to_packed(const std::vector<std::uint8_t> &p_bytes) {
	PackedByteArray out;
	out.resize(int64_t(p_bytes.size()));
	for (std::size_t i = 0; i < p_bytes.size(); ++i) {
		out.set(int64_t(i), p_bytes[i]);
	}
	return out;
}

// The inverse of `to_packed()`.
inline std::vector<std::uint8_t> from_packed(const PackedByteArray &p_bytes) {
	std::vector<std::uint8_t> out;
	out.resize(std::size_t(p_bytes.size()));
	for (int64_t i = 0; i < p_bytes.size(); ++i) {
		out[std::size_t(i)] = std::uint8_t(p_bytes.get(i));
	}
	return out;
}

// Dictionary shape for an `inv::ItemLocation`/`inv::SnapshotLocation`:
// {kind: "spatial"|"slot"|"list", container: int64, x: int, y: int,
// rotated: bool, slot_identifier: String, ordinal: int}. Only the fields
// relevant to `kind` are meaningful on either side of the conversion.
inline Dictionary snapshot_location_dict(const inv::SnapshotLocation &p_location) {
	Dictionary d;
	switch (p_location.kind) {
		case inv::SnapshotLocationKind::SPATIAL:
			d["kind"] = String("spatial");
			break;
		case inv::SnapshotLocationKind::SLOT:
			d["kind"] = String("slot");
			break;
		case inv::SnapshotLocationKind::LIST:
		default:
			d["kind"] = String("list");
			break;
	}
	d["container"] = int64_t(p_location.container);
	d["x"] = int(p_location.x);
	d["y"] = int(p_location.y);
	d["rotated"] = p_location.rotated;
	d["slot_identifier"] = String(p_location.slot_identifier.c_str());
	d["ordinal"] = int(p_location.ordinal);
	return d;
}

inline Dictionary location_dict(const inv::ItemLocation &p_location) {
	return snapshot_location_dict(inv::to_snapshot_location(p_location));
}

// Builds an `inv::ItemLocation` from a script-authored Dictionary shaped
// like `location_dict()`'s output. Returns false (leaving r_out untouched)
// on a malformed shape -- a missing/unrecognized "kind" -- so the caller can
// fail closed with an INVALID_ARGUMENT status rather than guessing.
inline bool location_from_dict(const Dictionary &p_dict, inv::ItemLocation &r_out) {
	inv::SnapshotLocation snapshot;
	const String kind = String(p_dict.get("kind", "spatial"));
	if (kind == "spatial") {
		snapshot.kind = inv::SnapshotLocationKind::SPATIAL;
	} else if (kind == "slot") {
		snapshot.kind = inv::SnapshotLocationKind::SLOT;
	} else if (kind == "list") {
		snapshot.kind = inv::SnapshotLocationKind::LIST;
	} else {
		return false;
	}
	snapshot.container = std::uint64_t(int64_t(p_dict.get("container", int64_t(0))));
	snapshot.x = std::uint32_t(int64_t(p_dict.get("x", int64_t(0))));
	snapshot.y = std::uint32_t(int64_t(p_dict.get("y", int64_t(0))));
	snapshot.rotated = bool(p_dict.get("rotated", false));
	snapshot.slot_identifier = to_std(String(p_dict.get("slot_identifier", String())));
	snapshot.ordinal = std::uint32_t(int64_t(p_dict.get("ordinal", int64_t(0))));
	return inv::from_snapshot_location(snapshot, r_out).ok();
}

} // namespace godot

#endif // INVENTORY_SYSTEM_GODOT_UTIL_H
