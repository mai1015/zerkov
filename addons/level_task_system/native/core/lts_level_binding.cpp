#include "core/lts_level_binding.h"

#include "core/lts_catalog.h"
#include "core/lts_hash.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace lts {

namespace {

bool known_target_kind(LevelBindingTargetKind p_kind) {
	switch (p_kind) {
		case LevelBindingTargetKind::NODE:
		case LevelBindingTargetKind::TRANSFORM:
		case LevelBindingTargetKind::AREA:
			return true;
	}
	return false;
}

bool target_compatible(SceneAnchorKind p_anchor_kind, LevelBindingTargetKind p_target_kind) {
	// A point may be represented by any host target.  Transform and area
	// anchors are stricter: an area cannot satisfy a transform anchor and a
	// transform cannot satisfy an area anchor.  A NODE target is intentionally
	// accepted for both because a scene node may expose its transform/area via
	// the host adapter.
	if (p_anchor_kind == SceneAnchorKind::TRANSFORM && p_target_kind == LevelBindingTargetKind::AREA) return false;
	if (p_anchor_kind == SceneAnchorKind::AREA && p_target_kind == LevelBindingTargetKind::TRANSFORM) return false;
	return true;
}

std::string bounded_path(const std::string &p_path) {
	if (p_path.size() <= MAX_DIAGNOSTIC_PATH_BYTES) return p_path;
	const std::size_t suffix_size = MAX_DIAGNOSTIC_PATH_BYTES / 3;
	const std::size_t prefix_size = MAX_DIAGNOSTIC_PATH_BYTES - suffix_size - 3;
	return p_path.substr(0, prefix_size) + "..." + p_path.substr(p_path.size() - suffix_size);
}

std::string binding_path(const std::string &p_level_identifier) {
	return bounded_path("binding." + (p_level_identifier.empty() ? std::string("<invalid>") : p_level_identifier));
}

std::string anchor_path(const std::string &p_level_identifier, const std::string &p_anchor_identifier) {
	return bounded_path(binding_path(p_level_identifier) + ".anchor." +
			(p_anchor_identifier.empty() ? std::string("<invalid>") : p_anchor_identifier));
}

std::string level_path(const std::string &p_level_identifier) {
	return bounded_path("level." + (p_level_identifier.empty() ? std::string("<invalid>") : p_level_identifier));
}

void reset_report(LevelBindingValidationReport &r_report) {
	r_report.status = ok_status();
	r_report.findings.clear();
	r_report.total_finding_count = 0;
	r_report.truncated = false;
}

void append_finding(
		LevelBindingValidationReport &r_report,
		const Status &p_status,
		const std::string &p_path,
		const std::string &p_related_path = std::string()) {
	if (p_status.ok()) return;
	if (r_report.total_finding_count != std::numeric_limits<std::uint32_t>::max()) ++r_report.total_finding_count;
	if (r_report.findings.size() < MAX_LEVEL_BINDING_DIAGNOSTICS) {
		r_report.findings.push_back(LevelBindingDiagnostic{ p_status, bounded_path(p_path), bounded_path(p_related_path) });
	} else {
		r_report.truncated = true;
	}
}

void finish_report(LevelBindingValidationReport &r_report) {
	std::sort(r_report.findings.begin(), r_report.findings.end());
	if (r_report.total_finding_count > r_report.findings.size()) r_report.truncated = true;
	r_report.status = r_report.findings.empty() ? ok_status() : r_report.findings.front().status;
}

const LevelAnchorDefinition *find_definition_anchor(
		const LevelDefinition &p_level,
		const std::string &p_identifier) {
	for (const LevelAnchorDefinition &anchor : p_level.anchors) {
		if (anchor.identifier == p_identifier) return &anchor;
	}
	return nullptr;
}

} // namespace

LevelAnchorBinding LevelAnchorBinding::node(
		const std::string &p_anchor_identifier,
		SceneAnchorKind p_anchor_kind,
		const std::string &p_target_path) {
	LevelAnchorBinding binding;
	binding.anchor_identifier = p_anchor_identifier;
	binding.anchor_kind = p_anchor_kind;
	binding.target_kind = LevelBindingTargetKind::NODE;
	binding.target_path = p_target_path;
	return binding;
}

LevelAnchorBinding LevelAnchorBinding::transform(
		const std::string &p_anchor_identifier,
		const std::string &p_target_path,
		const std::array<std::int64_t, 12> &p_transform_raw) {
	LevelAnchorBinding binding;
	binding.anchor_identifier = p_anchor_identifier;
	binding.anchor_kind = SceneAnchorKind::TRANSFORM;
	binding.target_kind = LevelBindingTargetKind::TRANSFORM;
	binding.target_path = p_target_path;
	binding.transform_raw = p_transform_raw;
	binding.has_transform = true;
	return binding;
}

LevelAnchorBinding LevelAnchorBinding::area(
		const std::string &p_anchor_identifier,
		const std::string &p_target_path) {
	LevelAnchorBinding binding;
	binding.anchor_identifier = p_anchor_identifier;
	binding.anchor_kind = SceneAnchorKind::AREA;
	binding.target_kind = LevelBindingTargetKind::AREA;
	binding.target_path = p_target_path;
	return binding;
}

Status LevelAnchorBinding::validate() const {
	Status status = validate_local_identifier(anchor_identifier);
	if (!status.ok()) return status;
	if (!is_known_anchor_kind(anchor_kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::LEVEL_ANCHOR_INVALID,
				static_cast<std::uint8_t>(anchor_kind));
	}
	if (!known_target_kind(target_kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::LEVEL_ANCHOR_INVALID,
				static_cast<std::uint8_t>(target_kind));
	}
	if (target_path.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_ANCHOR_INVALID);
	}
	if (target_path.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, target_path.size());
	}
	if (!target_compatible(anchor_kind, target_kind)) {
		return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::LEVEL_ANCHOR_INVALID,
				(static_cast<std::uint64_t>(static_cast<std::uint8_t>(anchor_kind)) << 32) |
				static_cast<std::uint8_t>(target_kind));
	}
	return ok_status();
}

bool LevelAnchorBinding::operator==(const LevelAnchorBinding &p_other) const {
	return anchor_identifier == p_other.anchor_identifier && anchor_kind == p_other.anchor_kind &&
			target_kind == p_other.target_kind && target_path == p_other.target_path &&
			transform_raw == p_other.transform_raw && has_transform == p_other.has_transform;
}

bool LevelAnchorBinding::operator<(const LevelAnchorBinding &p_other) const {
	if (anchor_identifier != p_other.anchor_identifier) return local_identifier_less(anchor_identifier, p_other.anchor_identifier);
	if (anchor_kind != p_other.anchor_kind) {
		return static_cast<std::uint8_t>(anchor_kind) < static_cast<std::uint8_t>(p_other.anchor_kind);
	}
	if (target_kind != p_other.target_kind) {
		return static_cast<std::uint8_t>(target_kind) < static_cast<std::uint8_t>(p_other.target_kind);
	}
	if (target_path != p_other.target_path) return target_path < p_other.target_path;
	if (has_transform != p_other.has_transform) return has_transform < p_other.has_transform;
	return transform_raw < p_other.transform_raw;
}

bool LevelBindingDiagnostic::operator<(const LevelBindingDiagnostic &p_other) const {
	if (path != p_other.path) return path < p_other.path;
	if (related_path != p_other.related_path) return related_path < p_other.related_path;
	if (status.code != p_other.status.code) {
		return static_cast<std::uint16_t>(status.code) < static_cast<std::uint16_t>(p_other.status.code);
	}
	if (status.diagnostic != p_other.status.diagnostic) {
		return static_cast<std::uint16_t>(status.diagnostic) < static_cast<std::uint16_t>(p_other.status.diagnostic);
	}
	return status.detail < p_other.status.detail;
}

Status LevelSceneRegistry::add_scene(const std::string &p_scene_resource) {
	Status status = p_scene_resource.empty()
			? make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID)
			: ok_status();
	if (!status.ok()) return status;
	if (p_scene_resource.size() > MAX_SCENE_RESOURCE_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID, p_scene_resource.size());
	}
	if (std::find(scene_resources_.begin(), scene_resources_.end(), p_scene_resource) != scene_resources_.end()) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, hash_string(p_scene_resource));
	}
	scene_resources_.push_back(p_scene_resource);
	std::sort(scene_resources_.begin(), scene_resources_.end());
	return ok_status();
}

Status LevelSceneRegistry::remove_scene(const std::string &p_scene_resource) {
	const auto found = std::find(scene_resources_.begin(), scene_resources_.end(), p_scene_resource);
	if (found == scene_resources_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_scene_resource));
	}
	scene_resources_.erase(found);
	return ok_status();
}

bool LevelSceneRegistry::has_scene(const std::string &p_scene_resource) const {
	return std::binary_search(scene_resources_.begin(), scene_resources_.end(), p_scene_resource);
}

Status LevelSceneRegistry::validate() const {
	if (scene_resources_.size() > MAX_LEVEL_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, scene_resources_.size());
	}
	for (const std::string &scene_resource : scene_resources_) {
		if (scene_resource.empty()) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID);
		if (scene_resource.size() > MAX_SCENE_RESOURCE_BYTES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID, scene_resource.size());
		}
	}
	return ok_status();
}

LevelBinding::LevelBinding(const std::string &p_level_identifier) : level_identifier_(p_level_identifier) {}

Status LevelBinding::set_level_identifier(const std::string &p_level_identifier) {
	const Status status = validate_identifier(p_level_identifier);
	if (!status.ok()) return status;
	level_identifier_ = p_level_identifier;
	return ok_status();
}

Status LevelBinding::add_anchor(const LevelAnchorBinding &p_binding) {
	const Status status = p_binding.validate();
	if (!status.ok()) return status;
	if (bindings_.size() >= MAX_ANCHORS_PER_LEVEL) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_ANCHOR_INVALID, bindings_.size() + 1);
	}
	bindings_.push_back(p_binding);
	return ok_status();
}

Status LevelBinding::bind_anchor(
		const std::string &p_anchor_identifier,
		SceneAnchorKind p_anchor_kind,
		LevelBindingTargetKind p_target_kind,
		const std::string &p_target_path) {
	LevelAnchorBinding binding;
	binding.anchor_identifier = p_anchor_identifier;
	binding.anchor_kind = p_anchor_kind;
	binding.target_kind = p_target_kind;
	binding.target_path = p_target_path;
	return add_anchor(binding);
}

Status LevelBinding::remove_anchor(const std::string &p_anchor_identifier) {
	const auto found = std::find_if(bindings_.begin(), bindings_.end(), [&](const LevelAnchorBinding &p_binding) {
		return p_binding.anchor_identifier == p_anchor_identifier;
	});
	if (found == bindings_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_anchor_identifier));
	}
	bindings_.erase(found);
	return ok_status();
}

const LevelAnchorBinding *LevelBinding::find_anchor(const std::string &p_anchor_identifier) const {
	for (const LevelAnchorBinding &binding : bindings_) {
		if (binding.anchor_identifier == p_anchor_identifier) return &binding;
	}
	return nullptr;
}

Status LevelBinding::validate() const {
	Status status = validate_identifier(level_identifier_);
	if (!status.ok()) return status;
	if (bindings_.size() > MAX_ANCHORS_PER_LEVEL) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_ANCHOR_INVALID, bindings_.size());
	}
	for (const LevelAnchorBinding &binding : bindings_) {
		status = binding.validate();
		if (!status.ok()) return status;
	}
	return ok_status();
}

Status LevelBinding::validate(const LevelDefinition &p_level, LevelBindingValidationReport &r_report) const {
	reset_report(r_report);
	const std::string expected_level = p_level.identifier;

	const Status level_status = p_level.validate();
	if (!level_status.ok()) {
		append_finding(r_report, level_status, level_path(expected_level));
	}
	const Status binding_status = validate();
	if (!binding_status.ok()) {
		append_finding(r_report, binding_status, binding_path(level_identifier_));
	}
	if (!level_identifier_.empty() && !expected_level.empty() && level_identifier_ != expected_level) {
		append_finding(r_report,
				make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::LEVEL_ANCHOR_INVALID, hash_string(level_identifier_)),
				binding_path(level_identifier_) + ".level",
				level_path(expected_level));
	}
	if (scene_presence_known_ && !scene_available_) {
		append_finding(r_report,
				make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID, hash_string(p_level.scene_resource)),
				level_path(expected_level) + ".scene_resource");
	}

	for (std::size_t index = 0; index < bindings_.size(); ++index) {
		const LevelAnchorBinding &binding = bindings_[index];
		const std::string path = anchor_path(expected_level.empty() ? level_identifier_ : expected_level, binding.anchor_identifier);
		const Status status = binding.validate();
		if (!status.ok()) append_finding(r_report, status, path);
		for (std::size_t other = index + 1; other < bindings_.size(); ++other) {
			if (binding.anchor_identifier == bindings_[other].anchor_identifier) {
				append_finding(r_report,
						make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::LEVEL_ANCHOR_INVALID, other),
						path,
						anchor_path(expected_level.empty() ? level_identifier_ : expected_level, bindings_[other].anchor_identifier));
			}
		}
		const LevelAnchorDefinition *definition = find_definition_anchor(p_level, binding.anchor_identifier);
		if (definition == nullptr) {
			append_finding(r_report,
					make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_ANCHOR_INVALID,
							hash_string(binding.anchor_identifier)),
					path,
					level_path(expected_level) + ".anchor.<missing>");
			continue;
		}
		if (definition->kind != binding.anchor_kind || !target_compatible(definition->kind, binding.target_kind)) {
			const std::uint64_t detail = (static_cast<std::uint64_t>(static_cast<std::uint8_t>(definition->kind)) << 24) |
				(static_cast<std::uint64_t>(static_cast<std::uint8_t>(binding.anchor_kind)) << 16) |
				static_cast<std::uint8_t>(binding.target_kind);
			append_finding(r_report,
					make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::LEVEL_ANCHOR_INVALID, detail),
					path,
					level_path(expected_level) + ".anchor." + definition->identifier);
		}
	}

	for (const LevelAnchorDefinition &definition : p_level.anchors) {
		if (find_anchor(definition.identifier) != nullptr) continue;
		if (!definition.required) continue;
		append_finding(r_report,
				make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_ANCHOR_INVALID,
					hash_string(definition.identifier)),
				anchor_path(expected_level, definition.identifier),
				binding_path(level_identifier_));
	}
	finish_report(r_report);
	return r_report.status;
}

Status LevelBinding::validate(const LevelDefinition &p_level) const {
	LevelBindingValidationReport report;
	return validate(p_level, report);
}

Status validate_level_binding(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const LevelSceneRegistry *p_scene_registry,
		const LevelBinding *p_binding,
		LevelBindingValidationReport &r_report) {
	reset_report(r_report);
	if (!p_catalog.sealed()) {
		append_finding(r_report, make_status(StatusCode::CATALOG_NOT_SEALED), "catalog");
		finish_report(r_report);
		return r_report.status;
	}
	const Status catalog_status = p_catalog.validate();
	if (!catalog_status.ok()) {
		append_finding(r_report, catalog_status, "catalog");
	}
	const LevelDefinition *level = nullptr;
	const Status level_status = p_catalog.resolve_level(p_level_identifier, level);
	if (!level_status.ok() || level == nullptr) {
		append_finding(r_report,
				level_status.ok() ? make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(p_level_identifier)) : level_status,
				level_path(p_level_identifier));
		finish_report(r_report);
		return r_report.status;
	}
	if (p_scene_registry != nullptr) {
		const Status registry_status = p_scene_registry->validate();
		if (!registry_status.ok()) append_finding(r_report, registry_status, "scene_registry");
		if (!p_scene_registry->has_scene(level->scene_resource)) {
			append_finding(r_report,
					make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID,
						hash_string(level->scene_resource)),
					level_path(level->identifier) + ".scene_resource");
		}
	}
	if (p_binding != nullptr) {
		LevelBindingValidationReport binding_report;
		p_binding->validate(*level, binding_report);
		for (const LevelBindingDiagnostic &finding : binding_report.findings) append_finding(r_report, finding.status, finding.path, finding.related_path);
		if (binding_report.total_finding_count > binding_report.findings.size()) {
			r_report.total_finding_count += binding_report.total_finding_count - static_cast<std::uint32_t>(binding_report.findings.size());
			r_report.truncated = true;
		}
	}
	finish_report(r_report);
	return r_report.status;
}

Status validate_level_binding(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const LevelSceneRegistry *p_scene_registry,
		const LevelBinding *p_binding) {
	LevelBindingValidationReport report;
	return validate_level_binding(p_catalog, p_level_identifier, p_scene_registry, p_binding, report);
}

} // namespace lts
