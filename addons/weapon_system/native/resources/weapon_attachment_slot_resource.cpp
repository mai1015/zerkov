#include "resources/weapon_attachment_slot_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void WeaponAttachmentSlotResource::set_slot_id(const StringName &p_slot_id) {
	slot_id = p_slot_id;
	emit_changed();
}

void WeaponAttachmentSlotResource::set_slot_kind(SlotKind p_slot_kind) {
	slot_kind = p_slot_kind;
	emit_changed();
}

void WeaponAttachmentSlotResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_slot_id", "slot_id"), &WeaponAttachmentSlotResource::set_slot_id);
	ClassDB::bind_method(D_METHOD("get_slot_id"), &WeaponAttachmentSlotResource::get_slot_id);
	ClassDB::bind_method(D_METHOD("set_slot_kind", "slot_kind"), &WeaponAttachmentSlotResource::set_slot_kind);
	ClassDB::bind_method(D_METHOD("get_slot_kind"), &WeaponAttachmentSlotResource::get_slot_kind);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "slot_id", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.slot.optic_rail (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_slot_id", "get_slot_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slot_kind", PROPERTY_HINT_ENUM, "Optic,Muzzle,Stock,Grip"),
			"set_slot_kind", "get_slot_kind");

	BIND_ENUM_CONSTANT(SLOT_KIND_OPTIC);
	BIND_ENUM_CONSTANT(SLOT_KIND_MUZZLE);
	BIND_ENUM_CONSTANT(SLOT_KIND_STOCK);
	BIND_ENUM_CONSTANT(SLOT_KIND_GRIP);
}

} // namespace godot
