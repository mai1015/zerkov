#ifndef LEVEL_TASK_SYSTEM_CORE_LEVEL_BINDING_H
#define LEVEL_TASK_SYSTEM_CORE_LEVEL_BINDING_H

#include "core/lts_definitions.h"
#include "core/lts_limits.h"
#include "core/lts_status.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

class LevelTaskCatalog;

// A scene-side target is deliberately a closed value.  The core never stores
// a Godot Node, ObjectID, RID, NodePath object, or callable.  A Godot adapter
// may use target_path as a diagnostic/lookup key and resolve it to a live
// object in the host scene while the binding is attached.
enum class LevelBindingTargetKind : std::uint8_t {
	NODE = 1,
	TRANSFORM = 2,
	AREA = 3,
};

struct LevelAnchorBinding {
	std::string anchor_identifier;
	SceneAnchorKind anchor_kind = SceneAnchorKind::POINT;
	LevelBindingTargetKind target_kind = LevelBindingTargetKind::NODE;
	std::string target_path;

	// A transform is an optional fixed-point, row-major 3x4 value.  Keeping the
	// representation integer-only makes headless validation deterministic and
	// gives adapters a loss-bounded seam for converting engine transforms.  A
	// node target may also provide an explicit transform override.
	std::array<std::int64_t, 12> transform_raw{};
	bool has_transform = false;

	static LevelAnchorBinding node(
			const std::string &p_anchor_identifier,
			SceneAnchorKind p_anchor_kind,
			const std::string &p_target_path);
	static LevelAnchorBinding transform(
			const std::string &p_anchor_identifier,
			const std::string &p_target_path,
			const std::array<std::int64_t, 12> &p_transform_raw);
	static LevelAnchorBinding area(
			const std::string &p_anchor_identifier,
			const std::string &p_target_path);

	Status validate() const;
	bool operator==(const LevelAnchorBinding &p_other) const;
	bool operator!=(const LevelAnchorBinding &p_other) const { return !(*this == p_other); }
	bool operator<(const LevelAnchorBinding &p_other) const;
};

using SceneAnchorBinding = LevelAnchorBinding;
using LevelBindingAnchor = LevelAnchorBinding;

// Binding diagnostics mirror the catalog's bounded, path-addressable report.
// `path` and `related_path` are stable values suitable for editor navigation;
// they never contain a live engine object or an unbounded error string.
struct LevelBindingDiagnostic {
	Status status;
	std::string path;
	std::string related_path;

	bool operator==(const LevelBindingDiagnostic &p_other) const {
		return status == p_other.status && path == p_other.path && related_path == p_other.related_path;
	}
	bool operator!=(const LevelBindingDiagnostic &p_other) const { return !(*this == p_other); }
	bool operator<(const LevelBindingDiagnostic &p_other) const;
};

constexpr std::size_t MAX_LEVEL_BINDING_DIAGNOSTICS = 64;

struct LevelBindingValidationReport {
	Status status;
	std::vector<LevelBindingDiagnostic> findings;
	std::uint32_t total_finding_count = 0;
	bool truncated = false;

	bool ok() const { return status.ok() && total_finding_count == 0; }
};

// A host-owned inventory of scene resources.  It is intentionally an
// ordinary value object rather than a singleton or a filesystem service: a
// test, server, or game can supply the exact resources visible to its scope.
class LevelSceneRegistry {
public:
	LevelSceneRegistry() = default;

	Status add_scene(const std::string &p_scene_resource);
	Status add_scene_resource(const std::string &p_scene_resource) { return add_scene(p_scene_resource); }
	Status register_scene(const std::string &p_scene_resource) { return add_scene(p_scene_resource); }
	Status remove_scene(const std::string &p_scene_resource);
	bool has_scene(const std::string &p_scene_resource) const;
	bool contains(const std::string &p_scene_resource) const { return has_scene(p_scene_resource); }
	const std::vector<std::string> &scenes() const { return scene_resources_; }
	std::size_t size() const { return scene_resources_.size(); }
	Status validate() const;

private:
	std::vector<std::string> scene_resources_;
};

using LevelSceneAvailability = LevelSceneRegistry;

// A binding is created by the host after a scene has been loaded.  It is
// copyable and instance-local; no process-global ownership or scene loading is
// performed here.  The canonical LevelDefinition remains completely free of
// these values and therefore cannot retain a live scene reference.
class LevelBinding {
public:
	LevelBinding() = default;
	explicit LevelBinding(const std::string &p_level_identifier);

	Status set_level_identifier(const std::string &p_level_identifier);
	const std::string &level_identifier() const { return level_identifier_; }
	const std::string &level_id() const { return level_identifier_; }

	// Scene presence is optional metadata supplied by the host.  The default
	// state is "unknown" so a pure mapping can be validated in a headless unit
	// test.  If explicitly marked unavailable, validation reports a missing
	// scene before any task graph can start.
	void set_scene_available(bool p_available) {
		scene_presence_known_ = true;
		scene_available_ = p_available;
	}
	void mark_scene_available(bool p_available) { set_scene_available(p_available); }
	void clear_scene_availability() { scene_presence_known_ = false; }
	bool has_scene_availability() const { return scene_presence_known_; }
	bool scene_available() const { return !scene_presence_known_ || scene_available_; }

	Status add_anchor(const LevelAnchorBinding &p_binding);
	Status add_binding(const LevelAnchorBinding &p_binding) { return add_anchor(p_binding); }
	Status bind_anchor(const LevelAnchorBinding &p_binding) { return add_anchor(p_binding); }
	Status bind_anchor(
			const std::string &p_anchor_identifier,
			SceneAnchorKind p_anchor_kind,
			LevelBindingTargetKind p_target_kind,
			const std::string &p_target_path);
	Status remove_anchor(const std::string &p_anchor_identifier);
	void clear_anchors() { bindings_.clear(); }

	const std::vector<LevelAnchorBinding> &anchors() const { return bindings_; }
	const std::vector<LevelAnchorBinding> &bindings() const { return bindings_; }
	std::size_t anchor_count() const { return bindings_.size(); }
	const LevelAnchorBinding *find_anchor(const std::string &p_anchor_identifier) const;
	const LevelAnchorBinding *resolve_anchor(const std::string &p_anchor_identifier) const { return find_anchor(p_anchor_identifier); }

	Status validate() const;
	Status validate(const LevelDefinition &p_level, LevelBindingValidationReport &r_report) const;
	Status validate(const LevelDefinition &p_level) const;
	Status validate_against(const LevelDefinition &p_level, LevelBindingValidationReport &r_report) const {
		return validate(p_level, r_report);
	}
	Status validate_against(const LevelDefinition &p_level) const { return validate(p_level); }

private:
	std::string level_identifier_;
	std::vector<LevelAnchorBinding> bindings_;
	bool scene_presence_known_ = false;
	bool scene_available_ = true;
};

using SceneBinding = LevelBinding;
using LevelSceneBinding = LevelBinding;

// Shared validation entry point used by session startup and headless/editor
// adapters.  The catalog must already be sealed.  `p_scene_registry` and
// `p_binding` may be null when an adapter is only checking catalog references;
// a session that is about to start should provide both.
Status validate_level_binding(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const LevelSceneRegistry *p_scene_registry,
		const LevelBinding *p_binding,
		LevelBindingValidationReport &r_report);

Status validate_level_binding(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const LevelSceneRegistry *p_scene_registry = nullptr,
		const LevelBinding *p_binding = nullptr);

using LevelBindingReport = LevelBindingValidationReport;

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_LEVEL_BINDING_H
