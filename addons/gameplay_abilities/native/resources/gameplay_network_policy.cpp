#include "resources/gameplay_network_policy.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayNetworkPolicy::set_hidden_attribute_identifiers(const PackedStringArray &p_ids) {
	hidden_attribute_identifiers = p_ids;
	emit_changed();
}

void GameplayNetworkPolicy::set_hidden_tag_identifiers(const PackedStringArray &p_ids) {
	hidden_tag_identifiers = p_ids;
	emit_changed();
}

void GameplayNetworkPolicy::set_hidden_ability_identifiers(const PackedStringArray &p_ids) {
	hidden_ability_identifiers = p_ids;
	emit_changed();
}

void GameplayNetworkPolicy::set_default_relevant_peers(const PackedInt32Array &p_peers) {
	default_relevant_peers = p_peers;
	emit_changed();
}

void GameplayNetworkPolicy::set_owner_view_default(bool p_owner_view) {
	owner_view_default = p_owner_view;
	emit_changed();
}

void GameplayNetworkPolicy::set_resync_rate_limit_per_minute(int p_limit) {
	resync_rate_limit_per_minute = p_limit < 1 ? 1 : p_limit;
	emit_changed();
}

void GameplayNetworkPolicy::set_prediction_opt_in(bool p_opt_in) {
	prediction_opt_in = p_opt_in;
	emit_changed();
}

void GameplayNetworkPolicy::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_hidden_attribute_identifiers", "ids"),
			&GameplayNetworkPolicy::set_hidden_attribute_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_attribute_identifiers"),
			&GameplayNetworkPolicy::get_hidden_attribute_identifiers);
	ClassDB::bind_method(D_METHOD("set_hidden_tag_identifiers", "ids"),
			&GameplayNetworkPolicy::set_hidden_tag_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_tag_identifiers"), &GameplayNetworkPolicy::get_hidden_tag_identifiers);
	ClassDB::bind_method(D_METHOD("set_hidden_ability_identifiers", "ids"),
			&GameplayNetworkPolicy::set_hidden_ability_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_ability_identifiers"),
			&GameplayNetworkPolicy::get_hidden_ability_identifiers);
	ClassDB::bind_method(D_METHOD("set_default_relevant_peers", "peers"),
			&GameplayNetworkPolicy::set_default_relevant_peers);
	ClassDB::bind_method(D_METHOD("get_default_relevant_peers"), &GameplayNetworkPolicy::get_default_relevant_peers);
	ClassDB::bind_method(D_METHOD("set_owner_view_default", "owner_view"),
			&GameplayNetworkPolicy::set_owner_view_default);
	ClassDB::bind_method(D_METHOD("get_owner_view_default"), &GameplayNetworkPolicy::get_owner_view_default);
	ClassDB::bind_method(D_METHOD("set_resync_rate_limit_per_minute", "limit"),
			&GameplayNetworkPolicy::set_resync_rate_limit_per_minute);
	ClassDB::bind_method(D_METHOD("get_resync_rate_limit_per_minute"),
			&GameplayNetworkPolicy::get_resync_rate_limit_per_minute);
	ClassDB::bind_method(D_METHOD("set_prediction_opt_in", "opt_in"), &GameplayNetworkPolicy::set_prediction_opt_in);
	ClassDB::bind_method(D_METHOD("get_prediction_opt_in"), &GameplayNetworkPolicy::get_prediction_opt_in);

	ADD_GROUP("Visibility", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_attribute_identifiers"),
			"set_hidden_attribute_identifiers", "get_hidden_attribute_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_tag_identifiers"),
			"set_hidden_tag_identifiers", "get_hidden_tag_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_ability_identifiers"),
			"set_hidden_ability_identifiers", "get_hidden_ability_identifiers");

	ADD_GROUP("Relevance", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "default_relevant_peers"),
			"set_default_relevant_peers", "get_default_relevant_peers");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "owner_view_default"),
			"set_owner_view_default", "get_owner_view_default");

	ADD_GROUP("Resync", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "resync_rate_limit_per_minute", PROPERTY_HINT_RANGE, "1,60,1"),
			"set_resync_rate_limit_per_minute", "get_resync_rate_limit_per_minute");

	ADD_GROUP("Prediction", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "prediction_opt_in"),
			"set_prediction_opt_in", "get_prediction_opt_in");
}

} // namespace godot
