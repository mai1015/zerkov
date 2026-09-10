#include "resources/lts_level_binding_resource.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/char_string.hpp>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>

namespace godot {

namespace {

using lts::DiagnosticId;
using lts::Status;
using lts::StatusCode;

Status copy_node_path(const NodePath &p_path, std::string &r_path) {
	const CharString utf8 = String(p_path).utf8();
	if (utf8.length() <= 0) {
		return lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_ANCHOR_INVALID);
	}
	if (static_cast<std::size_t>(utf8.length()) > lts::MAX_STRING_BYTES) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED,
				static_cast<std::size_t>(utf8.length()));
	}
	r_path.assign(utf8.get_data(), static_cast<std::size_t>(utf8.length()));
	return lts::ok_status();
}

Status fixed_component(real_t p_value, std::int64_t &r_raw) {
	if (!std::isfinite(static_cast<double>(p_value))) {
		return lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE);
	}
	const double scaled = static_cast<double>(p_value) * static_cast<double>(lts::FIXED_SCALE);
	if (!std::isfinite(scaled) || scaled > static_cast<double>(std::numeric_limits<std::int64_t>::max()) ||
			scaled < static_cast<double>(std::numeric_limits<std::int64_t>::min())) {
		return lts::make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_NOT_REPRESENTABLE);
	}
	r_raw = static_cast<std::int64_t>(std::llround(scaled));
	return lts::ok_status();
}

} // namespace

void LevelTaskLevelAnchorBinding::set_anchor_identifier(const StringName &p_identifier) {
	anchor_identifier = p_identifier;
	emit_changed();
}

void LevelTaskLevelAnchorBinding::set_anchor_kind(AnchorKind p_kind) {
	anchor_kind = p_kind;
	emit_changed();
}

void LevelTaskLevelAnchorBinding::set_target_kind(TargetKind p_kind) {
	target_kind = p_kind;
	emit_changed();
}

void LevelTaskLevelAnchorBinding::set_node_path(const NodePath &p_path) {
	node_path = p_path;
	emit_changed();
}

void LevelTaskLevelAnchorBinding::set_transform(const Transform3D &p_transform) {
	transform = p_transform;
	has_transform = true;
	emit_changed();
}

void LevelTaskLevelAnchorBinding::set_has_transform(bool p_has_transform) {
	has_transform = p_has_transform;
	emit_changed();
}

Status LevelTaskLevelAnchorBinding::to_core_binding(lts::LevelAnchorBinding &r_binding) const {
	lts::LevelAnchorBinding binding;
	const CharString identifier_utf8 = String(anchor_identifier).utf8();
	if (identifier_utf8.length() <= 0) {
		return lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_ANCHOR_INVALID);
	}
	binding.anchor_identifier.assign(identifier_utf8.get_data(), static_cast<std::size_t>(identifier_utf8.length()));
	if (anchor_kind < ANCHOR_POINT || anchor_kind > ANCHOR_AREA) {
		return lts::make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint64_t>(anchor_kind));
	}
	binding.anchor_kind = static_cast<lts::SceneAnchorKind>(static_cast<int>(anchor_kind) + 1);
	if (target_kind < TARGET_NODE || target_kind > TARGET_AREA) {
		return lts::make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint64_t>(target_kind));
	}
	binding.target_kind = static_cast<lts::LevelBindingTargetKind>(static_cast<int>(target_kind) + 1);
	Status status = copy_node_path(node_path, binding.target_path);
	if (!status.ok()) return status;
	binding.has_transform = has_transform;
	if (has_transform) {
		const real_t components[12] = {
			transform.basis.rows[0][0], transform.basis.rows[0][1], transform.basis.rows[0][2],
			transform.basis.rows[1][0], transform.basis.rows[1][1], transform.basis.rows[1][2],
			transform.basis.rows[2][0], transform.basis.rows[2][1], transform.basis.rows[2][2],
			transform.origin.x, transform.origin.y, transform.origin.z,
		};
		for (std::size_t index = 0; index < 12; ++index) {
			status = fixed_component(components[index], binding.transform_raw[index]);
			if (!status.ok()) return status;
		}
	}
	status = binding.validate();
	if (!status.ok()) return status;
	r_binding = std::move(binding);
	return lts::ok_status();
}

Status LevelTaskLevelAnchorBinding::validate_core() const {
	lts::LevelAnchorBinding binding;
	return to_core_binding(binding);
}

void LevelTaskLevelAnchorBinding::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_anchor_identifier", "identifier"), &LevelTaskLevelAnchorBinding::set_anchor_identifier);
	ClassDB::bind_method(D_METHOD("get_anchor_identifier"), &LevelTaskLevelAnchorBinding::get_anchor_identifier);
	ClassDB::bind_method(D_METHOD("set_anchor_kind", "kind"), &LevelTaskLevelAnchorBinding::set_anchor_kind);
	ClassDB::bind_method(D_METHOD("get_anchor_kind"), &LevelTaskLevelAnchorBinding::get_anchor_kind);
	ClassDB::bind_method(D_METHOD("set_target_kind", "kind"), &LevelTaskLevelAnchorBinding::set_target_kind);
	ClassDB::bind_method(D_METHOD("get_target_kind"), &LevelTaskLevelAnchorBinding::get_target_kind);
	ClassDB::bind_method(D_METHOD("set_node_path", "path"), &LevelTaskLevelAnchorBinding::set_node_path);
	ClassDB::bind_method(D_METHOD("get_node_path"), &LevelTaskLevelAnchorBinding::get_node_path);
	ClassDB::bind_method(D_METHOD("set_transform", "transform"), &LevelTaskLevelAnchorBinding::set_transform);
	ClassDB::bind_method(D_METHOD("get_transform"), &LevelTaskLevelAnchorBinding::get_transform);
	ClassDB::bind_method(D_METHOD("set_has_transform", "has_transform"), &LevelTaskLevelAnchorBinding::set_has_transform);
	ClassDB::bind_method(D_METHOD("get_has_transform"), &LevelTaskLevelAnchorBinding::get_has_transform);
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "anchor_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT, "spawn"),
			"set_anchor_identifier", "get_anchor_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "anchor_kind", PROPERTY_HINT_ENUM, "Point,Transform,Area"),
			"set_anchor_kind", "get_anchor_kind");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "target_kind", PROPERTY_HINT_ENUM, "Node,Transform,Area"),
			"set_target_kind", "get_target_kind");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "node_path"), "set_node_path", "get_node_path");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "transform"), "set_transform", "get_transform");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "has_transform"), "set_has_transform", "get_has_transform");

	BIND_ENUM_CONSTANT(ANCHOR_POINT);
	BIND_ENUM_CONSTANT(ANCHOR_TRANSFORM);
	BIND_ENUM_CONSTANT(ANCHOR_AREA);
	BIND_ENUM_CONSTANT(TARGET_NODE);
	BIND_ENUM_CONSTANT(TARGET_TRANSFORM);
	BIND_ENUM_CONSTANT(TARGET_AREA);
}

} // namespace godot
