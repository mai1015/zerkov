class_name ZerkovInputActions
extends RefCounted

## Game-owned logical input catalog for the first playable.
##
## CommonUI remains the physical-event router, but this catalog owns Zerkov's
## stable action identifiers, conflict groups, trigger policy, device-family
## metadata, and default binding intent.  The returned dictionaries are always
## detached copies; callers must not treat a CommonUI Resource or InputMap
## projection as the source of truth for the catalog.

const CONFIG_DEFINITION_VERSION: int = 803
const PERSISTENCE_FORMAT_VERSION: int = 2
const MAX_ACTIONS: int = 64
const MAX_BINDINGS_PER_ACTION: int = 8
const MAX_GLYPH_IDS: int = 256

const GAMEPLAY_CONTEXT: StringName = &"zerkov/gameplay"
const UI_CONTEXT: StringName = &"zerkov/ui"
const MODAL_CONTEXT: StringName = &"zerkov/modal"
const DEVELOPER_CONTEXT: StringName = &"zerkov/developer"

const FAMILY_KEYBOARD_MOUSE: StringName = &"keyboard_mouse"
const FAMILY_XBOX: StringName = &"xbox"
const FAMILY_PLAYSTATION: StringName = &"playstation"
const FAMILY_SWITCH: StringName = &"switch"
const FAMILY_GENERIC_GAMEPAD: StringName = &"generic_gamepad"
const FAMILY_UNKNOWN: StringName = &"unknown"

# Framework actions retain their accepted CommonUI identifiers.  Game-owned
# actions use the same safe namespace so the native registry never rewrites an
# unrelated project InputMap action.
const UI_BACK: StringName = CommonUIDefaults.BACK
const UI_CONFIRM: StringName = CommonUIDefaults.CONFIRM
const UI_MENU: StringName = CommonUIDefaults.MENU
const UI_TAB_NEXT: StringName = CommonUIDefaults.TAB_NEXT
const UI_TAB_PREVIOUS: StringName = CommonUIDefaults.TAB_PREVIOUS

const GAME_MOVE: StringName = &"common_ui/zerkov/gameplay/move"
const GAME_SPRINT: StringName = &"common_ui/zerkov/gameplay/sprint"
const GAME_CROUCH: StringName = &"common_ui/zerkov/gameplay/crouch"
const GAME_INTERACT: StringName = &"common_ui/zerkov/gameplay/interact"
const GAME_HOLD_INTERACT: StringName = &"common_ui/zerkov/gameplay/hold_interact"
const GAME_AIM: StringName = &"common_ui/zerkov/gameplay/aim"
const GAME_FIRE: StringName = &"common_ui/zerkov/gameplay/fire"
const GAME_RELOAD: StringName = &"common_ui/zerkov/gameplay/reload"
const GAME_CANCEL_RELOAD: StringName = &"common_ui/zerkov/gameplay/cancel_reload"
const GAME_MELEE: StringName = &"common_ui/zerkov/gameplay/melee"
const GAME_QUICK_HEAL: StringName = &"common_ui/zerkov/gameplay/quick_heal"
const GAME_FIRE_MODE: StringName = &"common_ui/zerkov/gameplay/fire_mode"
const GAME_GRENADE: StringName = &"common_ui/zerkov/gameplay/grenade"
const GAME_WEAPON_CYCLE: StringName = &"common_ui/zerkov/gameplay/weapon_cycle"
const GAME_QUICK_USE: StringName = &"common_ui/zerkov/gameplay/quick_use"
const GAME_EAT_DRINK: StringName = &"common_ui/zerkov/gameplay/eat_drink"
const GAME_PUSH_TO_TALK: StringName = &"common_ui/zerkov/gameplay/push_to_talk"

const UI_OPEN_INVENTORY: StringName = &"common_ui/zerkov/ui/open_inventory"
const UI_OPEN_MAP: StringName = &"common_ui/zerkov/ui/open_map"
const UI_OPEN_TASKS: StringName = &"common_ui/zerkov/ui/open_tasks"
const UI_OPEN_SETTINGS: StringName = &"common_ui/zerkov/ui/open_settings"

const _GLYPH_META := {
	&"glyph_unknown": {"family": "generic", "label": "?", "fallback": "glyph_unknown"},
	&"glyph_unbound": {"family": "generic", "label": "—", "fallback": "glyph_unbound"},
	&"key_w": {"family": "keyboard", "label": "W", "fallback": "glyph_unknown"},
	&"key_a": {"family": "keyboard", "label": "A", "fallback": "glyph_unknown"},
	&"key_s": {"family": "keyboard", "label": "S", "fallback": "glyph_unknown"},
	&"key_d": {"family": "keyboard", "label": "D", "fallback": "glyph_unknown"},
	&"key_shift": {"family": "keyboard", "label": "Shift", "fallback": "glyph_unknown"},
	&"key_c": {"family": "keyboard", "label": "C", "fallback": "glyph_unknown"},
	&"key_e": {"family": "keyboard", "label": "E", "fallback": "glyph_unknown"},
	&"key_q": {"family": "keyboard", "label": "Q", "fallback": "glyph_unknown"},
	&"key_r": {"family": "keyboard", "label": "R", "fallback": "glyph_unknown"},
	&"key_escape": {"family": "keyboard", "label": "Esc", "fallback": "glyph_unknown"},
	&"key_enter": {"family": "keyboard", "label": "Enter", "fallback": "glyph_unknown"},
	&"key_i": {"family": "keyboard", "label": "I", "fallback": "glyph_unknown"},
	&"key_m": {"family": "keyboard", "label": "M", "fallback": "glyph_unknown"},
	&"key_j": {"family": "keyboard", "label": "J", "fallback": "glyph_unknown"},
	&"key_p": {"family": "keyboard", "label": "P", "fallback": "glyph_unknown"},
	&"key_o": {"family": "keyboard", "label": "O", "fallback": "glyph_unknown"},
	&"key_b": {"family": "keyboard", "label": "B", "fallback": "glyph_unknown"},
	&"key_y": {"family": "keyboard", "label": "Y", "fallback": "glyph_unknown"},
	&"key_v": {"family": "keyboard", "label": "V", "fallback": "glyph_unknown"},
	&"key_g": {"family": "keyboard", "label": "G", "fallback": "glyph_unknown"},
	&"key_1": {"family": "keyboard", "label": "1", "fallback": "glyph_unknown"},
	&"key_5": {"family": "keyboard", "label": "5", "fallback": "glyph_unknown"},
	&"key_h": {"family": "keyboard", "label": "H", "fallback": "glyph_unknown"},
	&"key_t": {"family": "keyboard", "label": "T", "fallback": "glyph_unknown"},
	&"key_capslock": {"family": "keyboard", "label": "Caps", "fallback": "glyph_unknown"},
	&"key_tab": {"family": "keyboard", "label": "Tab", "fallback": "glyph_unknown"},
	&"mouse_left": {"family": "mouse", "label": "LMB", "fallback": "glyph_unknown"},
	&"mouse_right": {"family": "mouse", "label": "RMB", "fallback": "glyph_unknown"},
	&"mouse_wheel": {"family": "mouse", "label": "Wheel", "fallback": "glyph_unknown"},
	&"pad_a": {"family": "gamepad", "label": "A", "fallback": "pad_generic"},
	&"pad_b": {"family": "gamepad", "label": "B", "fallback": "pad_generic"},
	&"pad_south": {"family": "gamepad", "label": "South / A", "fallback": "pad_generic"},
	&"pad_east": {"family": "gamepad", "label": "East / B", "fallback": "pad_generic"},
	&"pad_north": {"family": "gamepad", "label": "North / Y", "fallback": "pad_generic"},
	&"pad_x": {"family": "gamepad", "label": "X", "fallback": "pad_generic"},
	&"pad_y": {"family": "gamepad", "label": "Y", "fallback": "pad_generic"},
	&"pad_start": {"family": "gamepad", "label": "Start", "fallback": "pad_generic"},
	&"pad_back": {"family": "gamepad", "label": "Back", "fallback": "pad_generic"},
	&"pad_lb": {"family": "gamepad", "label": "LB", "fallback": "pad_generic"},
	&"pad_rb": {"family": "gamepad", "label": "RB", "fallback": "pad_generic"},
	&"pad_ls": {"family": "gamepad", "label": "LS", "fallback": "pad_generic"},
	&"pad_rs": {"family": "gamepad", "label": "RS", "fallback": "pad_generic"},
	&"pad_lt": {"family": "gamepad", "label": "LT", "fallback": "pad_generic"},
	&"pad_rt": {"family": "gamepad", "label": "RT", "fallback": "pad_generic"},
	&"pad_dpad_up": {"family": "gamepad", "label": "D-pad ↑", "fallback": "pad_generic"},
	&"pad_dpad_down": {"family": "gamepad", "label": "D-pad ↓", "fallback": "pad_generic"},
	&"pad_dpad_left": {"family": "gamepad", "label": "D-pad ←", "fallback": "pad_generic"},
	&"pad_dpad_right": {"family": "gamepad", "label": "D-pad →", "fallback": "pad_generic"},
	&"pad_ls_up": {"family": "gamepad", "label": "LS ↑", "fallback": "pad_generic"},
	&"pad_ls_left": {"family": "gamepad", "label": "LS ←", "fallback": "pad_generic"},
	&"pad_generic": {"family": "gamepad", "label": "Gamepad", "fallback": "glyph_unknown"},
	&"xbox_a": {"family": "xbox", "label": "A", "fallback": "xbox_generic"},
	&"xbox_b": {"family": "xbox", "label": "B", "fallback": "xbox_generic"},
	&"xbox_x": {"family": "xbox", "label": "X", "fallback": "xbox_generic"},
	&"xbox_y": {"family": "xbox", "label": "Y", "fallback": "xbox_generic"},
	&"xbox_lb": {"family": "xbox", "label": "LB", "fallback": "xbox_generic"},
	&"xbox_rb": {"family": "xbox", "label": "RB", "fallback": "xbox_generic"},
	&"xbox_back": {"family": "xbox", "label": "View", "fallback": "xbox_generic"},
	&"xbox_start": {"family": "xbox", "label": "Menu", "fallback": "xbox_generic"},
	&"xbox_generic": {"family": "xbox", "label": "Xbox", "fallback": "pad_generic"},
	&"ps_cross": {"family": "playstation", "label": "Cross", "fallback": "playstation_generic"},
	&"ps_circle": {"family": "playstation", "label": "Circle", "fallback": "playstation_generic"},
	&"ps_square": {"family": "playstation", "label": "Square", "fallback": "playstation_generic"},
	&"ps_triangle": {"family": "playstation", "label": "Triangle", "fallback": "playstation_generic"},
	&"ps_l1": {"family": "playstation", "label": "L1", "fallback": "playstation_generic"},
	&"ps_r1": {"family": "playstation", "label": "R1", "fallback": "playstation_generic"},
	&"ps_share": {"family": "playstation", "label": "Share", "fallback": "playstation_generic"},
	&"ps_options": {"family": "playstation", "label": "Options", "fallback": "playstation_generic"},
	&"playstation_generic": {"family": "playstation", "label": "PlayStation", "fallback": "pad_generic"},
	&"switch_a": {"family": "switch", "label": "A", "fallback": "switch_generic"},
	&"switch_b": {"family": "switch", "label": "B", "fallback": "switch_generic"},
	&"switch_x": {"family": "switch", "label": "X", "fallback": "switch_generic"},
	&"switch_y": {"family": "switch", "label": "Y", "fallback": "switch_generic"},
	&"switch_generic": {"family": "switch", "label": "Switch", "fallback": "pad_generic"},
}


static func all_action_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry_variant in catalog_definitions():
		var entry: Dictionary = entry_variant
		result.append(entry["id"] as StringName)
	return result


static func gameplay_action_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry_variant in action_definitions():
		var entry: Dictionary = entry_variant
		if entry["context"] == GAMEPLAY_CONTEXT:
			result.append(entry["id"] as StringName)
	return result


static func ui_action_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry_variant in catalog_definitions():
		var entry: Dictionary = entry_variant
		if entry["context"] == UI_CONTEXT:
			result.append(entry["id"] as StringName)
	return result


static func glyph_metadata() -> Dictionary:
	return (_GLYPH_META as Dictionary).duplicate(true)


static func has_glyph(glyph_id: StringName) -> bool:
	return _GLYPH_META.has(glyph_id)


static func action_definition(action_id: StringName) -> Dictionary:
	for entry_variant in catalog_definitions():
		var entry: Dictionary = entry_variant
		if entry["id"] == action_id:
			return entry.duplicate(true)
	return {}


static func catalog_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(framework_action_definitions())
	result.append_array(action_definitions())
	return result


static func framework_action_definitions() -> Array[Dictionary]:
	# The framework owns dispatch/lifecycle for these five actions, while the
	# game owns their presentation metadata and final defaults (notably Menu's
	# P binding, which leaves M available for Map).
	return [
		_definition(UI_BACK, "Back", UI_CONTEXT, &"ui", CommonUIAction.PROTECTION_REQUIRED,
			[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_ESCAPE, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_escape", FAMILY_KEYBOARD_MOUSE),
			 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_B, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_east", FAMILY_GENERIC_GAMEPAD)],
			0.0, false),
		_definition(UI_CONFIRM, "Confirm", UI_CONTEXT, &"ui", CommonUIAction.PROTECTION_REQUIRED,
			[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_ENTER, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_enter", FAMILY_KEYBOARD_MOUSE),
			 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_A, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_south", FAMILY_GENERIC_GAMEPAD)],
			0.0, false),
		_definition(UI_MENU, "Menu", UI_CONTEXT, &"ui", CommonUIAction.PROTECTION_NONE,
			[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_P, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_p", FAMILY_KEYBOARD_MOUSE),
			 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_START, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_start", FAMILY_GENERIC_GAMEPAD)],
			0.0, false),
		_definition(UI_TAB_NEXT, "Next tab", UI_CONTEXT, &"ui", CommonUIAction.PROTECTION_NONE,
			[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_E, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_e", FAMILY_KEYBOARD_MOUSE),
			 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_RIGHT_SHOULDER, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_rb", FAMILY_GENERIC_GAMEPAD)],
			0.0, false),
		_definition(UI_TAB_PREVIOUS, "Previous tab", UI_CONTEXT, &"ui", CommonUIAction.PROTECTION_NONE,
			[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Q, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_q", FAMILY_KEYBOARD_MOUSE),
			 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_LEFT_SHOULDER, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_lb", FAMILY_GENERIC_GAMEPAD)],
			0.0, false),
	]


static func action_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append(_definition(
		GAME_MOVE, "Move", GAMEPLAY_CONTEXT, &"gameplay/movement", CommonUIAction.PROTECTION_REQUIRED,
		[
			_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_W, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_w", FAMILY_KEYBOARD_MOUSE),
			_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_A, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_a", FAMILY_KEYBOARD_MOUSE),
			_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_S, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_s", FAMILY_KEYBOARD_MOUSE),
			_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_D, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_d", FAMILY_KEYBOARD_MOUSE),
			_binding(CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_Y, CommonUIBinding.AXIS_DIRECTION_NEGATIVE, &"pad_ls_up", FAMILY_GENERIC_GAMEPAD),
			_binding(CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_X, CommonUIBinding.AXIS_DIRECTION_NEGATIVE, &"pad_ls_left", FAMILY_GENERIC_GAMEPAD),
		],
		0.0, false,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_W, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_w", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_Y, CommonUIBinding.AXIS_DIRECTION_NEGATIVE, &"pad_ls_up", FAMILY_GENERIC_GAMEPAD)]))
	result.append(_definition(
		GAME_SPRINT, "Sprint", GAMEPLAY_CONTEXT, &"gameplay/movement", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_SHIFT, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_shift", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_LEFT_STICK, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_ls", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_CROUCH, "Crouch / cover", GAMEPLAY_CONTEXT, &"gameplay/movement", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_C, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_c", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_B, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_b", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_INTERACT, "Interact / loot", GAMEPLAY_CONTEXT, &"gameplay/interaction", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_E, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_e", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_X, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_x", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_HOLD_INTERACT, "Hold interact", GAMEPLAY_CONTEXT, &"gameplay/hold_interaction", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Q, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_q", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_A, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_a", FAMILY_GENERIC_GAMEPAD)],
		0.4, false))
	result.append(_definition(
		GAME_FIRE, "Fire", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_MOUSE, MOUSE_BUTTON_LEFT, CommonUIBinding.AXIS_DIRECTION_NONE, &"mouse_left", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_TRIGGER_RIGHT, CommonUIBinding.AXIS_DIRECTION_POSITIVE, &"pad_rt", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_AIM, "Aim", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_MOUSE, MOUSE_BUTTON_RIGHT, CommonUIBinding.AXIS_DIRECTION_NONE, &"mouse_right", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_TRIGGER_LEFT, CommonUIBinding.AXIS_DIRECTION_POSITIVE, &"pad_lt", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_RELOAD, "Reload", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_R, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_r", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_Y, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_y", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_CANCEL_RELOAD, "Cancel reload", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_ESCAPE, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_escape", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_B, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_b", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_MELEE, "Melee", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_V, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_v", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_RIGHT_STICK, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_rs", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_QUICK_HEAL, "Quick heal", GAMEPLAY_CONTEXT, &"gameplay/survival", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Y, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_y", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_DPAD_LEFT, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_dpad_left", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_FIRE_MODE, "Fire mode", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_B, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_b", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_DPAD_RIGHT, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_dpad_right", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_GRENADE, "Grenade", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_G, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_g", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_RIGHT_SHOULDER, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_rb", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_WEAPON_CYCLE, "Weapon cycle", GAMEPLAY_CONTEXT, &"gameplay/combat", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_1, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_1", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_MOUSE, MOUSE_BUTTON_WHEEL_UP, CommonUIBinding.AXIS_DIRECTION_NONE, &"mouse_wheel", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_GUIDE, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_generic", FAMILY_GENERIC_GAMEPAD)],
		0.0, false,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_1, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_1", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_GUIDE, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_generic", FAMILY_GENERIC_GAMEPAD)]))
	result.append(_definition(
		GAME_QUICK_USE, "Quick use", GAMEPLAY_CONTEXT, &"gameplay/survival", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_5, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_5", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_DPAD_UP, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_dpad_up", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_EAT_DRINK, "Eat / drink", GAMEPLAY_CONTEXT, &"gameplay/survival", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_H, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_h", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_DPAD_DOWN, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_dpad_down", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		GAME_PUSH_TO_TALK, "Push to talk", GAMEPLAY_CONTEXT, &"gameplay/communication", CommonUIAction.PROTECTION_NONE,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_CAPSLOCK, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_capslock", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_BACK, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_back", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))

	result.append(_definition(
		UI_OPEN_INVENTORY, "Inventory", UI_CONTEXT, &"ui/navigation", CommonUIAction.PROTECTION_REQUIRED,
		# Tab is the established first-playable affordance for leaving a raid
		# surface; controller Y occupies the second CommonUI slot.  The controls
		# fixture's legacy I label is presentation-only until task 8.10 ports the
		# rebinding rows to this registry.
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_TAB, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_tab", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_Y, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_y", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		UI_OPEN_MAP, "Map", UI_CONTEXT, &"ui/navigation", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_M, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_m", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_BACK, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_back", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		UI_OPEN_TASKS, "Tasks", UI_CONTEXT, &"ui/navigation", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_J, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_j", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_DPAD_DOWN, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_dpad_down", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	result.append(_definition(
		UI_OPEN_SETTINGS, "Settings", UI_CONTEXT, &"ui/navigation", CommonUIAction.PROTECTION_REQUIRED,
		[_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_O, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_o", FAMILY_KEYBOARD_MOUSE),
		 _binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_START, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_start", FAMILY_GENERIC_GAMEPAD)],
		0.0, false))
	return result


static func build_input_config() -> CommonUIInputConfig:
	var config := CommonUIDefaults.build_default_config()
	config.set_definition_version(CONFIG_DEFINITION_VERSION)

	# CommonUI's stock Menu default is M.  Zerkov owns M for the Map action, so
	# move the unused framework Menu affordance to P before appending the game
	# catalog.  This prevents a silent global conflict in the registry.
	var menu := config.find_action(UI_MENU)
	if menu != null:
		menu.set_conflict_context(&"ui")
		menu.set_default_bindings(_typed_bindings([
			_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_P, CommonUIBinding.AXIS_DIRECTION_NONE, &"key_p", FAMILY_KEYBOARD_MOUSE),
			_binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_START, CommonUIBinding.AXIS_DIRECTION_NONE, &"pad_start", FAMILY_GENERIC_GAMEPAD),
		]))
	for framework_id in [UI_BACK, UI_CONFIRM, UI_TAB_NEXT, UI_TAB_PREVIOUS]:
		var framework_action := config.find_action(framework_id)
		if framework_action != null:
			framework_action.set_conflict_context(&"ui")

	var actions: Array[CommonUIAction] = []
	for action_variant in config.get_actions():
		actions.append(action_variant as CommonUIAction)
	for definition_variant in action_definitions():
		var definition: Dictionary = definition_variant
		var action := CommonUIAction.new()
		action.set_action_name(definition["id"] as StringName)
		action.set_display_name(str(definition["label"]))
		action.set_conflict_context(definition["conflict_context"] as StringName)
		action.set_protection(int(definition["protection"]))
		action.set_hold_threshold(float(definition["hold_threshold"]))
		action.set_repeat_enabled(bool(definition["repeat_enabled"]))
		action.set_repeat_interval(float(definition["repeat_interval"]))
		action.set_display_priority(int(definition["display_priority"]))
		action.set_show_in_action_bar(false)
		action.set_default_bindings(_typed_bindings(definition["common_bindings"] as Array))
		actions.append(action)
	config.set_actions(actions)
	config.set_device_profiles(_device_profiles())
	config.set_input_policy(_input_policy())
	return config


static func _input_policy() -> CommonUIInputPolicy:
	var policy := CommonUIInputPolicy.new()
	policy.set_mouse_jitter_threshold(8.0)
	policy.set_stick_dead_zone(0.25)
	policy.set_modality_hysteresis(0.15)
	policy.set_mouse_motion_decay(0.5)
	policy.set_mouse_button_always_activates(true)
	policy.set_unassigned_devices_use_default_user(true)
	policy.set_shared_device_policy(false)
	return policy


static func _device_profiles() -> Array[CommonUIDeviceProfile]:
	var profiles: Array[CommonUIDeviceProfile] = []
	profiles.append(_profile(FAMILY_XBOX, ["xbox", "xinput", "microsoft"], {
		"2:%d" % JOY_BUTTON_A: &"xbox_a",
		"2:%d" % JOY_BUTTON_B: &"xbox_b",
		"2:%d" % JOY_BUTTON_X: &"xbox_x",
		"2:%d" % JOY_BUTTON_Y: &"xbox_y",
		"2:%d" % JOY_BUTTON_LEFT_SHOULDER: &"xbox_lb",
		"2:%d" % JOY_BUTTON_RIGHT_SHOULDER: &"xbox_rb",
		"2:%d" % JOY_BUTTON_BACK: &"xbox_back",
		"2:%d" % JOY_BUTTON_START: &"xbox_start",
	}, &"xbox_generic"))
	profiles.append(_profile(FAMILY_PLAYSTATION, ["dualshock", "dualsense", "playstation", "sony"], {
		"2:%d" % JOY_BUTTON_A: &"ps_cross",
		"2:%d" % JOY_BUTTON_B: &"ps_circle",
		"2:%d" % JOY_BUTTON_X: &"ps_square",
		"2:%d" % JOY_BUTTON_Y: &"ps_triangle",
		"2:%d" % JOY_BUTTON_LEFT_SHOULDER: &"ps_l1",
		"2:%d" % JOY_BUTTON_RIGHT_SHOULDER: &"ps_r1",
		"2:%d" % JOY_BUTTON_BACK: &"ps_share",
		"2:%d" % JOY_BUTTON_START: &"ps_options",
	}, &"playstation_generic"))
	profiles.append(_profile(FAMILY_SWITCH, ["nintendo", "switch", "joy-con", "pro controller"], {
		"2:%d" % JOY_BUTTON_A: &"switch_a",
		"2:%d" % JOY_BUTTON_B: &"switch_b",
		"2:%d" % JOY_BUTTON_X: &"switch_x",
		"2:%d" % JOY_BUTTON_Y: &"switch_y",
	}, &"switch_generic"))
	profiles.append(_profile(FAMILY_GENERIC_GAMEPAD, ["controller", "gamepad", "joypad"], {}, &"pad_generic"))
	return profiles


static func _profile(family: StringName, patterns: Array, glyph_map: Dictionary, fallback: StringName) -> CommonUIDeviceProfile:
	var profile := CommonUIDeviceProfile.new()
	profile.set_family_id(family)
	var typed_patterns := PackedStringArray()
	for pattern in patterns:
		typed_patterns.append(str(pattern))
	profile.set_name_patterns(typed_patterns)
	profile.set_glyph_map(glyph_map)
	profile.set_fallback_glyph_id(fallback)
	return profile


static func resolve_glyph_for_binding(binding: CommonUIBinding, family: StringName) -> StringName:
	if binding == null or not binding.is_valid_binding():
		return &"glyph_unbound"
	var normalized := String(family).to_lower()
	if binding.get_device_kind() == CommonUIBinding.DEVICE_GAMEPAD_BUTTON \
			or binding.get_device_kind() == CommonUIBinding.DEVICE_GAMEPAD_AXIS:
		var key := "%d:%d" % [binding.get_device_kind(), binding.get_code()]
		var family_map := _family_glyph_map(StringName(normalized))
		if family_map.has(key):
			return family_map[key] as StringName
		if normalized == String(FAMILY_XBOX): return &"xbox_generic"
		if normalized == String(FAMILY_PLAYSTATION): return &"playstation_generic"
		if normalized == String(FAMILY_SWITCH): return &"switch_generic"
		if has_glyph(binding.get_glyph_id()):
			return binding.get_glyph_id()
		return &"pad_generic"
	if has_glyph(binding.get_glyph_id()):
		return binding.get_glyph_id()
	return &"glyph_unknown"


static func family_for_device_name(device_name: String) -> StringName:
	var lowered := device_name.to_lower()
	if lowered.is_empty():
		return FAMILY_KEYBOARD_MOUSE
	for family_variant in [FAMILY_XBOX, FAMILY_PLAYSTATION, FAMILY_SWITCH, FAMILY_GENERIC_GAMEPAD]:
		var family: StringName = family_variant
		for pattern in _family_patterns(family):
			if lowered.contains(str(pattern).to_lower()):
				return family
	return FAMILY_UNKNOWN


static func _family_patterns(family: StringName) -> Array[String]:
	match family:
		FAMILY_XBOX: return ["xbox", "xinput", "microsoft"]
		FAMILY_PLAYSTATION: return ["dualshock", "dualsense", "playstation", "sony"]
		FAMILY_SWITCH: return ["nintendo", "switch", "joy-con", "pro controller"]
		FAMILY_GENERIC_GAMEPAD: return ["controller", "gamepad", "joypad"]
	return []


static func _family_glyph_map(family: StringName) -> Dictionary:
	match family:
		FAMILY_XBOX:
			return {
				"2:%d" % JOY_BUTTON_A: &"xbox_a", "2:%d" % JOY_BUTTON_B: &"xbox_b",
				"2:%d" % JOY_BUTTON_X: &"xbox_x", "2:%d" % JOY_BUTTON_Y: &"xbox_y",
				"2:%d" % JOY_BUTTON_LEFT_SHOULDER: &"xbox_lb",
				"2:%d" % JOY_BUTTON_RIGHT_SHOULDER: &"xbox_rb",
				"2:%d" % JOY_BUTTON_BACK: &"xbox_back", "2:%d" % JOY_BUTTON_START: &"xbox_start",
			}
		FAMILY_PLAYSTATION:
			return {
				"2:%d" % JOY_BUTTON_A: &"ps_cross", "2:%d" % JOY_BUTTON_B: &"ps_circle",
				"2:%d" % JOY_BUTTON_X: &"ps_square", "2:%d" % JOY_BUTTON_Y: &"ps_triangle",
				"2:%d" % JOY_BUTTON_LEFT_SHOULDER: &"ps_l1",
				"2:%d" % JOY_BUTTON_RIGHT_SHOULDER: &"ps_r1",
				"2:%d" % JOY_BUTTON_BACK: &"ps_share", "2:%d" % JOY_BUTTON_START: &"ps_options",
			}
		FAMILY_SWITCH:
			return {"2:%d" % JOY_BUTTON_A: &"switch_a", "2:%d" % JOY_BUTTON_B: &"switch_b", "2:%d" % JOY_BUTTON_X: &"switch_x", "2:%d" % JOY_BUTTON_Y: &"switch_y"}
	return {}


static func binding_descriptor(binding: CommonUIBinding, slot: int = -1) -> Dictionary:
	if binding == null:
		return {"bound": false, "slot": slot}
	return {
		"bound": binding.is_valid_binding(),
		"slot": slot,
		"device_kind": int(binding.get_device_kind()),
		"code": int(binding.get_code()),
		"axis_direction": int(binding.get_axis_direction()),
		"dead_zone": float(binding.get_dead_zone()),
		"shift": binding.is_shift_pressed(),
		"ctrl": binding.is_ctrl_pressed(),
		"alt": binding.is_alt_pressed(),
		"meta": binding.is_meta_pressed(),
		"glyph": String(binding.get_glyph_id()),
	}


static func _definition(
	action_id: StringName,
	label: String,
	context: StringName,
	conflict_context: StringName,
	protection: int,
	bindings: Array,
	hold_threshold: float,
	repeat_enabled: bool,
	common_bindings: Array = []
) -> Dictionary:
	var projected := common_bindings
	if projected.is_empty():
		projected = bindings.slice(0, mini(2, bindings.size()))
	return {
		"id": action_id,
		"label": label,
		"context": context,
		"conflict_context": conflict_context,
		"protection": protection,
		"hold_threshold": hold_threshold,
		"repeat_enabled": repeat_enabled,
		"repeat_interval": 0.1,
		"display_priority": 0,
		"bindings": bindings.duplicate(true),
		"common_bindings": projected.duplicate(true),
	}


static func _binding(device_kind: int, code: int, axis_direction: int, glyph: StringName, family: StringName, dead_zone: float = 0.25) -> Dictionary:
	return {
		"device_kind": device_kind,
		"code": code,
		"axis_direction": axis_direction,
		"dead_zone": dead_zone,
		"shift": false,
		"ctrl": false,
		"alt": false,
		"meta": false,
		"glyph": glyph,
		"family": family,
	}


static func _typed_bindings(values: Array) -> Array[CommonUIBinding]:
	var result: Array[CommonUIBinding] = []
	for index in range(values.size()):
		var descriptor: Dictionary = values[index]
		var binding := CommonUIBinding.new()
		binding.set_device_kind(int(descriptor["device_kind"]))
		binding.set_code(int(descriptor["code"]))
		binding.set_axis_direction(int(descriptor["axis_direction"]))
		binding.set_dead_zone(float(descriptor.get("dead_zone", 0.25)))
		binding.set_shift_pressed(bool(descriptor.get("shift", false)))
		binding.set_ctrl_pressed(bool(descriptor.get("ctrl", false)))
		binding.set_alt_pressed(bool(descriptor.get("alt", false)))
		binding.set_meta_pressed(bool(descriptor.get("meta", false)))
		binding.set_glyph_id(descriptor["glyph"] as StringName)
		binding.set_slot(CommonUIBinding.SLOT_PRIMARY if index == 0 else CommonUIBinding.SLOT_SECONDARY)
		result.append(binding)
	return result
