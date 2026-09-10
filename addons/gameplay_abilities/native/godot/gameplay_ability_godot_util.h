#ifndef GAMEPLAY_ABILITIES_GODOT_UTIL_H
#define GAMEPLAY_ABILITIES_GODOT_UTIL_H

#include "core/ga_ids.h"
#include "core/ga_status.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Cleanup pass: the small Godot-Variant <-> engine-independent-core
// conversions every native/godot/ file that crosses that boundary needs had
// drifted into independent, byte-for-byte-identical per-file copies --
// `to_std`/`to_entity_id`/a `status_dict`-shaped Dictionary builder in
// gameplay_ability_command_builder.cpp, gameplay_ability_component.*, and
// gameplay_ability_network_bridge.*, plus `to_std` again in
// gameplay_definition_validator.cpp. Consolidated here as plain `inline` free
// functions directly in `namespace godot` -- the same namespace every
// Godot-facing class in this addon already lives in (see
// gameplay_ability_hook_bridge.h's `interpret_script_hook_result` for the
// existing precedent of a shared free function declared there rather than a
// further-nested sub-namespace) -- rather than a new .cpp: every one of these
// is a two-to-six line conversion, so there is nothing for a translation unit
// to gain from an out-of-line definition.
namespace godot {

// Godot String -> UTF-8 std::string. The one conversion every native/godot/
// file goes through before handing a script-authored identifier/name to the
// engine-independent core.
inline std::string to_std(const String &p_value) {
	const CharString utf8 = p_value.utf8();
	return std::string(utf8.get_data());
}

// Clamps a script-supplied int64 (Dictionary/Variant fields arrive as int64)
// into a `ga::EntityId` -- a negative value folds to 0 rather than wrapping
// into a huge unsigned id.
inline ga::EntityId to_entity_id(int64_t p_value) {
	return ga::EntityId{ static_cast<uint64_t>(p_value < 0 ? 0 : p_value) };
}

// `ga::Status` -> the {code:int, diagnostic:int, detail:int64, ok:bool}
// Dictionary shape every signal/RPC/script-facing result surfaces it as.
inline Dictionary status_dict(const ga::Status &p_status) {
	Dictionary d;
	d["code"] = int(p_status.code);
	d["diagnostic"] = int(p_status.diagnostic);
	d["detail"] = int64_t(p_status.detail);
	d["ok"] = p_status.ok();
	return d;
}

// `std::vector<uint8_t>` (core/protocol's own wire-bytes type) -> Godot's
// `PackedByteArray`, used for RPC payloads and component snapshots alike.
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

} // namespace godot

#endif // GAMEPLAY_ABILITIES_GODOT_UTIL_H
