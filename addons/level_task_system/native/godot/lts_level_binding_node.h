#ifndef LEVEL_TASK_SYSTEM_GODOT_LEVEL_BINDING_NODE_H
#define LEVEL_TASK_SYSTEM_GODOT_LEVEL_BINDING_NODE_H

#include "core/lts_level_binding.h"
#include "resources/level_task_definition_resources.h"
#include "resources/lts_level_binding_resource.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Scene-side binding Node.  The host places one explicitly in each loaded
// scene (or constructs one in code) and owns its lifetime.  It is deliberately
// not an autoload/singleton and performs no scene loading or replacement.
class LevelTaskLevelBinding : public Node {
	GDCLASS(LevelTaskLevelBinding, Node)

public:
	LevelTaskLevelBinding() = default;

	void set_level_identifier(const StringName &p_identifier);
	StringName get_level_identifier() const { return level_identifier; }
	void set_anchor_bindings(const TypedArray<LevelTaskLevelAnchorBinding> &p_bindings);
	TypedArray<LevelTaskLevelAnchorBinding> get_anchor_bindings() const { return anchor_bindings; }
	void set_scene_available(bool p_available);
	bool get_scene_available() const { return scene_available; }
	void set_scene_presence_known(bool p_known);
	bool get_scene_presence_known() const { return scene_presence_known; }

	// Copies the typed Resources into the engine-independent value binding.
	lts::Status to_core_binding(lts::LevelBinding &r_binding) const;
	lts::Status validate_core() const;
	// Returns {ok, code, diagnostic, detail, finding_count, truncated} and
	// never exposes a live object in the returned data.
	Dictionary validate_for_level(const Ref<LevelTaskLevelDefinition> &p_level) const;

	PackedStringArray get_bound_anchor_identifiers() const;
	Ref<LevelTaskLevelAnchorBinding> find_anchor_binding(const StringName &p_identifier) const;

	// These lookups are scene-facing conveniences.  They resolve NodePath only
	// in this host-owned Node, never in lts::LevelBinding or a LevelDefinition.
	Node *resolve_anchor_node(const StringName &p_identifier) const;
	bool resolve_anchor_transform(const StringName &p_identifier, Transform3D &r_transform) const;
	Dictionary get_anchor_transform(const StringName &p_identifier) const;

protected:
	static void _bind_methods();

private:
	Dictionary status_dictionary(const lts::Status &p_status, std::uint32_t p_finding_count = 0, bool p_truncated = false) const;
	Ref<LevelTaskLevelAnchorBinding> find_anchor_binding_resource(const StringName &p_identifier) const;

	StringName level_identifier;
	TypedArray<LevelTaskLevelAnchorBinding> anchor_bindings;
	bool scene_available = true;
	bool scene_presence_known = false;
};

using LevelTaskBindingNode = LevelTaskLevelBinding;
using LevelBindingNode = LevelTaskLevelBinding;

} // namespace godot

#endif // LEVEL_TASK_SYSTEM_GODOT_LEVEL_BINDING_NODE_H
