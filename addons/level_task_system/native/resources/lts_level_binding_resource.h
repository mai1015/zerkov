#ifndef LEVEL_TASK_SYSTEM_RESOURCES_LEVEL_BINDING_RESOURCE_H
#define LEVEL_TASK_SYSTEM_RESOURCES_LEVEL_BINDING_RESOURCE_H

#include "core/lts_level_binding.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace godot {

// Editor/scene-side value for one stable anchor mapping.  It is a Resource so
// a binding Node can expose a typed array in the Inspector, but conversion to
// lts::LevelAnchorBinding copies only bounded scalar data and a textual lookup
// path.  No live Object reference enters the core.
class LevelTaskLevelAnchorBinding : public Resource {
	GDCLASS(LevelTaskLevelAnchorBinding, Resource)

public:
	enum AnchorKind {
		ANCHOR_POINT = 0,
		ANCHOR_TRANSFORM = 1,
		ANCHOR_AREA = 2,
	};
	enum TargetKind {
		TARGET_NODE = 0,
		TARGET_TRANSFORM = 1,
		TARGET_AREA = 2,
	};

	void set_anchor_identifier(const StringName &p_identifier);
	StringName get_anchor_identifier() const { return anchor_identifier; }
	void set_anchor_kind(AnchorKind p_kind);
	AnchorKind get_anchor_kind() const { return anchor_kind; }
	void set_target_kind(TargetKind p_kind);
	TargetKind get_target_kind() const { return target_kind; }
	void set_node_path(const NodePath &p_path);
	NodePath get_node_path() const { return node_path; }
	void set_transform(const Transform3D &p_transform);
	Transform3D get_transform() const { return transform; }
	void set_has_transform(bool p_has_transform);
	bool get_has_transform() const { return has_transform; }

	lts::Status to_core_binding(lts::LevelAnchorBinding &r_binding) const;
	lts::LevelAnchorBinding to_core_binding() const {
		lts::LevelAnchorBinding binding;
		to_core_binding(binding);
		return binding;
	}
	lts::Status validate_core() const;

protected:
	static void _bind_methods();

private:
	StringName anchor_identifier;
	AnchorKind anchor_kind = ANCHOR_POINT;
	TargetKind target_kind = TARGET_NODE;
	NodePath node_path;
	Transform3D transform;
	bool has_transform = false;
};

using LevelTaskAnchorBinding = LevelTaskLevelAnchorBinding;
using LevelAnchorBindingResource = LevelTaskLevelAnchorBinding;

} // namespace godot

VARIANT_ENUM_CAST(LevelTaskLevelAnchorBinding::TargetKind);
VARIANT_ENUM_CAST(LevelTaskLevelAnchorBinding::AnchorKind);

#endif // LEVEL_TASK_SYSTEM_RESOURCES_LEVEL_BINDING_RESOURCE_H
