#include "resources/gameplay_tag_query_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayTagQueryResource::set_all_of(const TypedArray<GameplayTagOperand> &p_operands) {
	all_of = p_operands;
	emit_changed();
}

void GameplayTagQueryResource::set_any_of(const TypedArray<GameplayTagOperand> &p_operands) {
	any_of = p_operands;
	emit_changed();
}

void GameplayTagQueryResource::set_none_of(const TypedArray<GameplayTagOperand> &p_operands) {
	none_of = p_operands;
	emit_changed();
}

void GameplayTagQueryResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_all_of", "operands"), &GameplayTagQueryResource::set_all_of);
	ClassDB::bind_method(D_METHOD("get_all_of"), &GameplayTagQueryResource::get_all_of);
	ClassDB::bind_method(D_METHOD("set_any_of", "operands"), &GameplayTagQueryResource::set_any_of);
	ClassDB::bind_method(D_METHOD("get_any_of"), &GameplayTagQueryResource::get_any_of);
	ClassDB::bind_method(D_METHOD("set_none_of", "operands"), &GameplayTagQueryResource::set_none_of);
	ClassDB::bind_method(D_METHOD("get_none_of"), &GameplayTagQueryResource::get_none_of);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "all_of", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTagOperand", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_all_of", "get_all_of");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "any_of", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTagOperand", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_any_of", "get_any_of");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "none_of", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTagOperand", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_none_of", "get_none_of");
}

} // namespace godot
