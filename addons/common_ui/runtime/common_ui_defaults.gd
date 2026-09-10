class_name CommonUIDefaults
extends RefCounted

## Default action identifiers and a ready-to-use input configuration.
##
## The addon ships default UI layers and a dialog scene (see
## [CommonUIScreenRoot] and [CommonDialog]) so a consumer project starts with a
## working navigation stack instead of nothing. Those defaults route the actions
## defined here; a consumer that authors its own [CommonUIInputConfig] can ignore
## this file entirely.
##
## Keep these identifiers in the `common_ui/` namespace so the binding registry
## projects them into `InputMap` without touching gameplay actions.

## Closes the top screen / dismisses a dialog. Always keeps a binding: a player
## must never be stranded inside a modal.
const BACK := &"common_ui/back"
## Confirms the focused default action of a dialog.
const CONFIRM := &"common_ui/confirm"
## Opens the menu from gameplay.
const MENU := &"common_ui/menu"
## Advances to the next tab in a [CommonTabList] bound to the default action ids.
const TAB_NEXT := &"common_ui/tab_next"
## Returns to the previous tab in a [CommonTabList] bound to the default action ids.
const TAB_PREVIOUS := &"common_ui/tab_previous"

## Well-known layer identifiers created by [CommonUIScreenRoot], lowest priority
## first. A consumer may add its own layers alongside these.
const LAYER_HUD := &"hud"
const LAYER_MENU := &"menu"
const LAYER_MODAL := &"modal"
const LAYER_POPUP := &"popup"

## Layer priorities. Higher layers route first and draw on top.
const PRIORITY_HUD := 0
const PRIORITY_MENU := 50
const PRIORITY_MODAL := 100
const PRIORITY_POPUP := 150


static func _key(code: Key, slot := CommonUIBinding.SLOT_PRIMARY, glyph := &"") -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	binding.set_device_kind(CommonUIBinding.DEVICE_KEYBOARD)
	binding.set_code(code)
	binding.set_slot(slot)
	binding.set_glyph_id(glyph)
	return binding


static func _pad(button: JoyButton, slot := CommonUIBinding.SLOT_SECONDARY, glyph := &"") -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	binding.set_device_kind(CommonUIBinding.DEVICE_GAMEPAD_BUTTON)
	binding.set_code(button)
	binding.set_slot(slot)
	binding.set_glyph_id(glyph)
	return binding


static func _action(
	name: StringName,
	display: String,
	bindings: Array,
	protection := CommonUIAction.PROTECTION_NONE,
	display_priority := 0
) -> CommonUIAction:
	var action := CommonUIAction.new()
	action.set_action_name(name)
	action.set_display_name(display)
	var typed: Array[CommonUIBinding] = []
	typed.assign(bindings)
	action.set_default_bindings(typed)
	action.set_protection(protection)
	action.set_display_priority(display_priority)
	action.set_hold_threshold(0.4)
	action.set_repeat_interval(0.15)
	return action


## Builds the default input configuration the shipped layers and dialog rely on.
##
## Deliberately avoids keys Godot's GUI stage claims for built-in `ui_*` actions
## (Tab, arrows), which framework routing can never reach while a Control has
## focus. Escape reaches routing because ordinary Controls do not consume it.
static func build_default_config() -> CommonUIInputConfig:
	var config := CommonUIInputConfig.new()

	var actions: Array[CommonUIAction] = [
		_action(BACK, "Back",
			[_key(KEY_ESCAPE, CommonUIBinding.SLOT_PRIMARY, &"key_escape"),
			 _pad(JOY_BUTTON_B, CommonUIBinding.SLOT_SECONDARY, &"pad_east")],
			CommonUIAction.PROTECTION_REQUIRED, 100),
		_action(CONFIRM, "Confirm",
			[_key(KEY_ENTER, CommonUIBinding.SLOT_PRIMARY, &"key_enter"),
			 _pad(JOY_BUTTON_A, CommonUIBinding.SLOT_SECONDARY, &"pad_south")],
			CommonUIAction.PROTECTION_REQUIRED, 90),
		_action(MENU, "Menu",
			[_key(KEY_M, CommonUIBinding.SLOT_PRIMARY, &"key_m"),
			 _pad(JOY_BUTTON_START, CommonUIBinding.SLOT_SECONDARY, &"pad_start")],
			CommonUIAction.PROTECTION_NONE, 50),
		# CommonTabList's own defaults (see common_tab_list.gd) point at exactly
		# these two ids, so a tab list works out of the box against this config
		# alone. Shoulder buttons are the console convention for cycling tabs;
		# Q/E are the keyboard secondaries, matching the addon's own reference
		# example (examples/reference/reference_actions.gd) so both share one
		# out-of-the-box feel.
		_action(TAB_NEXT, "Next Tab",
			[_key(KEY_E, CommonUIBinding.SLOT_PRIMARY, &"key_e"),
			 _pad(JOY_BUTTON_RIGHT_SHOULDER, CommonUIBinding.SLOT_SECONDARY, &"pad_rb")]),
		_action(TAB_PREVIOUS, "Previous Tab",
			[_key(KEY_Q, CommonUIBinding.SLOT_PRIMARY, &"key_q"),
			 _pad(JOY_BUTTON_LEFT_SHOULDER, CommonUIBinding.SLOT_SECONDARY, &"pad_lb")]),
	]
	config.set_actions(actions)

	var policy := CommonUIInputPolicy.new()
	policy.set_mouse_jitter_threshold(8.0)
	policy.set_stick_dead_zone(0.25)
	policy.set_modality_hysteresis(0.15)
	config.set_input_policy(policy)

	config.set_definition_version(1)
	return config
