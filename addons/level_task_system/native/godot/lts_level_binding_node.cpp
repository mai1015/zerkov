#include "godot/lts_level_binding_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/char_string.hpp>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <utility>

namespace godot {

namespace {

StringName to_string_name(const std::string &p_value) {
	return StringName(String(p_value.c_str()));
}

} // namespace

void LevelTaskLevelBinding::set_level_identifier(const StringName &p_identifier) {
	level_identifier = p_identifier;
}

void LevelTaskLevelBinding::set_anchor_bindings(const TypedArray<LevelTaskLevelAnchorBinding> &p_bindings) {
	anchor_bindings = p_bindings;
}

void LevelTaskLevelBinding::set_scene_available(bool p_available) {
	scene_available = p_available;
	scene_presence_known = true;
}

void LevelTaskLevelBinding::set_scene_presence_known(bool p_known) {
	scene_presence_known = p_known;
}

lts::Status LevelTaskLevelBinding::to_core_binding(lts::LevelBinding &r_binding) const {
	lts::LevelBinding binding;
	const lts::Status identifier_status = binding.set_level_identifier(std::string(String(level_identifier).utf8().get_data()));
	if (!identifier_status.ok()) return identifier_status;
	if (scene_presence_known) binding.set_scene_available(scene_available);
	for (int index = 0; index < anchor_bindings.size(); ++index) {
		const Ref<LevelTaskLevelAnchorBinding> anchor = anchor_bindings[index];
		if (anchor.is_null()) {
			return lts::make_status(lts::StatusCode::INVALID_ARGUMENT, lts::DiagnosticId::LEVEL_ANCHOR_INVALID, index);
		}
		lts::LevelAnchorBinding core_anchor;
		const lts::Status status = anchor->to_core_binding(core_anchor);
		if (!status.ok()) return status;
		const lts::Status add_status = binding.add_anchor(core_anchor);
		if (!add_status.ok()) return add_status;
	}
	r_binding = std::move(binding);
	return lts::ok_status();
}

lts::Status LevelTaskLevelBinding::validate_core() const {
	lts::LevelBinding binding;
	const lts::Status status = to_core_binding(binding);
	return status.ok() ? binding.validate() : status;
}

Dictionary LevelTaskLevelBinding::status_dictionary(
		const lts::Status &p_status,
		std::uint32_t p_finding_count,
		bool p_truncated) const {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["code"] = static_cast<int>(p_status.code);
	result["diagnostic"] = static_cast<int>(p_status.diagnostic);
	result["detail"] = static_cast<int64_t>(p_status.detail);
	result["finding_count"] = static_cast<int64_t>(p_finding_count);
	result["truncated"] = p_truncated;
	return result;
}

Dictionary LevelTaskLevelBinding::validate_for_level(const Ref<LevelTaskLevelDefinition> &p_level) const {
	if (p_level.is_null()) {
		return status_dictionary(lts::make_status(lts::StatusCode::INVALID_ARGUMENT, lts::DiagnosticId::LEVEL_ANCHOR_INVALID));
	}
	lts::LevelDefinition level;
	lts::Status status = p_level->to_core_level(level);
	if (!status.ok()) return status_dictionary(status);
	lts::LevelBinding binding;
	status = to_core_binding(binding);
	if (!status.ok()) return status_dictionary(status);
	lts::LevelBindingValidationReport report;
	status = binding.validate(level, report);
	// A loaded scene may additionally prove that each textual NodePath resolves.
	// Detached bindings remain valid value mappings; the host can call this
	// method again after attaching the Node to a scene tree.
	if (status.ok() && is_inside_tree()) {
		for (int index = 0; index < anchor_bindings.size(); ++index) {
			const Ref<LevelTaskLevelAnchorBinding> anchor = anchor_bindings[index];
			if (anchor.is_null() || get_node_or_null(anchor->get_node_path()) != nullptr) continue;
			const String path = String("binding.") + String(level_identifier) + ".anchor." + String(anchor->get_anchor_identifier()) + ".node_path";
			const CharString utf8 = path.utf8();
			const std::string stable_path(utf8.get_data(), static_cast<std::size_t>(utf8.length()));
			const lts::Status node_status = lts::make_status(lts::StatusCode::INVALID_REFERENCE,
					lts::DiagnosticId::LEVEL_ANCHOR_INVALID, static_cast<std::uint64_t>(index));
			if (report.total_finding_count != UINT32_MAX) ++report.total_finding_count;
			if (report.findings.size() < lts::MAX_LEVEL_BINDING_DIAGNOSTICS) {
				report.findings.push_back(lts::LevelBindingDiagnostic{ node_status, stable_path, stable_path });
			} else {
				report.truncated = true;
			}
		}
		std::sort(report.findings.begin(), report.findings.end());
		if (!report.findings.empty()) report.status = report.findings.front().status;
	}
	Dictionary result = status_dictionary(report.status, report.total_finding_count, report.truncated);
	Array findings;
	for (const lts::LevelBindingDiagnostic &finding : report.findings) {
		Dictionary item;
		item["code"] = static_cast<int>(finding.status.code);
		item["diagnostic"] = static_cast<int>(finding.status.diagnostic);
		item["detail"] = static_cast<int64_t>(finding.status.detail);
		item["path"] = String(finding.path.c_str());
		item["related_path"] = String(finding.related_path.c_str());
		findings.push_back(item);
	}
	result["findings"] = findings;
	return result;
}

PackedStringArray LevelTaskLevelBinding::get_bound_anchor_identifiers() const {
	PackedStringArray result;
	for (int index = 0; index < anchor_bindings.size(); ++index) {
		const Ref<LevelTaskLevelAnchorBinding> anchor = anchor_bindings[index];
		if (!anchor.is_null()) result.push_back(anchor->get_anchor_identifier());
	}
	return result;
}

Ref<LevelTaskLevelAnchorBinding> LevelTaskLevelBinding::find_anchor_binding_resource(const StringName &p_identifier) const {
	for (int index = 0; index < anchor_bindings.size(); ++index) {
		const Ref<LevelTaskLevelAnchorBinding> anchor = anchor_bindings[index];
		if (!anchor.is_null() && anchor->get_anchor_identifier() == p_identifier) return anchor;
	}
	return Ref<LevelTaskLevelAnchorBinding>();
}

Ref<LevelTaskLevelAnchorBinding> LevelTaskLevelBinding::find_anchor_binding(const StringName &p_identifier) const {
	return find_anchor_binding_resource(p_identifier);
}

Node *LevelTaskLevelBinding::resolve_anchor_node(const StringName &p_identifier) const {
	const Ref<LevelTaskLevelAnchorBinding> anchor = find_anchor_binding_resource(p_identifier);
	if (anchor.is_null()) return nullptr;
	return get_node_or_null(anchor->get_node_path());
}

bool LevelTaskLevelBinding::resolve_anchor_transform(const StringName &p_identifier, Transform3D &r_transform) const {
	const Ref<LevelTaskLevelAnchorBinding> anchor = find_anchor_binding_resource(p_identifier);
	if (anchor.is_null()) return false;
	if (anchor->get_has_transform()) {
		r_transform = anchor->get_transform();
		return true;
	}
	Node *node = get_node_or_null(anchor->get_node_path());
	Node3D *node_3d = Object::cast_to<Node3D>(node);
	if (node_3d == nullptr) return false;
	r_transform = node_3d->get_global_transform();
	return true;
}

Dictionary LevelTaskLevelBinding::get_anchor_transform(const StringName &p_identifier) const {
	Transform3D transform;
	Dictionary result;
	result["ok"] = resolve_anchor_transform(p_identifier, transform);
	result["transform"] = transform;
	return result;
}

void LevelTaskLevelBinding::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_level_identifier", "identifier"), &LevelTaskLevelBinding::set_level_identifier);
	ClassDB::bind_method(D_METHOD("get_level_identifier"), &LevelTaskLevelBinding::get_level_identifier);
	ClassDB::bind_method(D_METHOD("set_anchor_bindings", "bindings"), &LevelTaskLevelBinding::set_anchor_bindings);
	ClassDB::bind_method(D_METHOD("get_anchor_bindings"), &LevelTaskLevelBinding::get_anchor_bindings);
	ClassDB::bind_method(D_METHOD("set_scene_available", "available"), &LevelTaskLevelBinding::set_scene_available);
	ClassDB::bind_method(D_METHOD("get_scene_available"), &LevelTaskLevelBinding::get_scene_available);
	ClassDB::bind_method(D_METHOD("set_scene_presence_known", "known"), &LevelTaskLevelBinding::set_scene_presence_known);
	ClassDB::bind_method(D_METHOD("get_scene_presence_known"), &LevelTaskLevelBinding::get_scene_presence_known);
	ClassDB::bind_method(D_METHOD("validate_for_level", "level"), &LevelTaskLevelBinding::validate_for_level);
	ClassDB::bind_method(D_METHOD("get_bound_anchor_identifiers"), &LevelTaskLevelBinding::get_bound_anchor_identifiers);
	ClassDB::bind_method(D_METHOD("find_anchor_binding", "identifier"), &LevelTaskLevelBinding::find_anchor_binding);
	ClassDB::bind_method(D_METHOD("resolve_anchor_node", "identifier"), &LevelTaskLevelBinding::resolve_anchor_node);
	ClassDB::bind_method(D_METHOD("get_anchor_transform", "identifier"), &LevelTaskLevelBinding::get_anchor_transform);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "level_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT, "game.level.example"),
			"set_level_identifier", "get_level_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "anchor_bindings", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskLevelAnchorBinding", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_anchor_bindings", "get_anchor_bindings");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "scene_available"), "set_scene_available", "get_scene_available");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "scene_presence_known"), "set_scene_presence_known", "get_scene_presence_known");
}

} // namespace godot
