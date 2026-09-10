#ifndef GAMEPLAY_ABILITIES_RESOURCES_NETWORK_POLICY_H
#define GAMEPLAY_ABILITIES_RESOURCES_NETWORK_POLICY_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Per-component replication policy, authored once instead of hand-maintained
// as loose `PackedStringArray` literals wherever a `GameplayAbilityNetworkBridge`
// is configured (task 9.1's remainder).
//
// `GameplayAbilityNetworkBridge` (native/godot/gameplay_ability_network_bridge.h)
// is frozen for this task -- it already exposes exactly three "hidden from
// the public/observer feed" identifier lists (`hidden_attribute_identifiers`,
// `hidden_tag_identifiers`, `hidden_ability_identifiers`) plus
// `relevant_peers`/`owner_view`. Per the bridge's own doc comment: "anything
// NOT listed as hidden is public by default"; there is no configurable
// third "hidden even from the owner" tier -- the owner always receives the
// full canonical snapshot regardless of these lists. So "owner-only" here
// means exactly "hidden from the public/observer feed" from the observer's
// point of view: the owner alone still sees it via the full snapshot.
//
// `GameplayNetworkPolicyBridge.apply()` (runtime/ga_network_policy_bridge.gd)
// reads this resource and calls the bridge's EXISTING setters -- this
// Resource never talks to the bridge itself (godot-cpp stays out of
// runtime/, per the shared contract).
//
// `resync_rate_limit_per_minute` and `prediction_opt_in` are declarative
// documentation/intent fields only: the bridge constructs its
// `ga::proto::RateLimiter` with the fixed `ga::MAX_RESYNCS_PER_MINUTE` budget
// and has no exposed setter to override it, and prediction journaling
// (section 8) is not yet wired into the bridge at all (see that file's own
// "Section 8 seam" comment). They are still authored here so a policy asset
// documents the game's intent in one place; a follow-up that adds the
// corresponding bridge setters only needs to read these two fields.
class GameplayNetworkPolicy : public Resource {
	GDCLASS(GameplayNetworkPolicy, Resource)

public:
	// Attribute identifiers omitted from the public/observer state feed.
	// Feeds `GameplayAbilityNetworkBridge::set_hidden_attribute_identifiers`.
	void set_hidden_attribute_identifiers(const PackedStringArray &p_ids);
	PackedStringArray get_hidden_attribute_identifiers() const { return hidden_attribute_identifiers; }

	// Feeds `GameplayAbilityNetworkBridge::set_hidden_tag_identifiers`.
	void set_hidden_tag_identifiers(const PackedStringArray &p_ids);
	PackedStringArray get_hidden_tag_identifiers() const { return hidden_tag_identifiers; }

	// Feeds `GameplayAbilityNetworkBridge::set_hidden_ability_identifiers`.
	void set_hidden_ability_identifiers(const PackedStringArray &p_ids);
	PackedStringArray get_hidden_ability_identifiers() const { return hidden_ability_identifiers; }

	// Peer ids the server-side bridge should treat as relevant by default.
	// Empty (the default) means "every currently connected peer is
	// relevant", matching the bridge's own default. Feeds
	// `GameplayAbilityNetworkBridge::set_relevant_peers`.
	void set_default_relevant_peers(const PackedInt32Array &p_peers);
	PackedInt32Array get_default_relevant_peers() const { return default_relevant_peers; }

	// Feeds `GameplayAbilityNetworkBridge::set_owner_view` for the local
	// bridge instance this policy is applied to.
	void set_owner_view_default(bool p_owner_view);
	bool get_owner_view_default() const { return owner_view_default; }

	// Declarative only -- see file comment.
	void set_resync_rate_limit_per_minute(int p_limit);
	int get_resync_rate_limit_per_minute() const { return resync_rate_limit_per_minute; }

	// Declarative only -- see file comment.
	void set_prediction_opt_in(bool p_opt_in);
	bool get_prediction_opt_in() const { return prediction_opt_in; }

protected:
	static void _bind_methods();

private:
	PackedStringArray hidden_attribute_identifiers;
	PackedStringArray hidden_tag_identifiers;
	PackedStringArray hidden_ability_identifiers;
	PackedInt32Array default_relevant_peers;
	bool owner_view_default = true;
	int resync_rate_limit_per_minute = 6; // mirrors ga::MAX_RESYNCS_PER_MINUTE; kept as a literal to stay core-free.
	bool prediction_opt_in = false;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_NETWORK_POLICY_H
