class_name CommonUIActionValidator
extends RefCounted

## Static validation for a [CommonUIInputConfig].
##
## The runtime rejects an outright invalid configuration, but many problems are
## survivable yet still wrong: a required action with no binding, two actions
## fighting over one physical event in the same conflict context, or a key that
## Godot's GUI stage claims for a built-in `ui_*` action and so can never reach
## framework routing. This validator surfaces those so a project catches them
## before shipping. It is read-only and allocates nothing in the runtime.
##
## Returns an [Array] of findings, each a [Dictionary]:
## [code]{severity, action, message}[/code] where severity is one of
## [constant SEVERITY_ERROR], [constant SEVERITY_WARNING], [constant SEVERITY_INFO].
##
## [method validate] alone only walks the config's own action list, so it
## cannot see a different kind of survivable-but-wrong setup: a screen or
## control that calls [method CommonActivatableScreen.register_action] (or
## [method CommonUIRuntime.register_action]) for an action id the active config
## never defines, or defines with no bindings at all -- the control renders and
## the registration "succeeds", but the action can never be driven by any input.
## [method validate_runtime] additionally cross-checks every action currently
## registered at runtime against that same config and warns about exactly this
## (this is what would have caught [CommonTabList]'s tab_next/tab_previous
## shipping with no binding in [method CommonUIDefaults.build_default_config]).

const SEVERITY_ERROR := &"error"
const SEVERITY_WARNING := &"warning"
const SEVERITY_INFO := &"info"


## Validates a configuration. Pass the live [InputMap]-claimed `ui_*` keys via
## [param check_ui_collisions] to also flag keyboard bindings that the GUI stage
## would swallow; leave it true in a running project.
static func validate(config: CommonUIInputConfig, check_ui_collisions := true) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if config == null:
		findings.append(_finding(SEVERITY_ERROR, &"", "No input configuration was provided."))
		return findings

	var reserved_keys := _reserved_ui_keys() if check_ui_collisions else {}
	# signature -> {action, context} of the first binding that used it,
	# so a second binding with the same physical event can be reported.
	var seen_signatures := {}
	var seen_names := {}

	for action_variant in config.get_actions():
		var action: CommonUIAction = action_variant
		if action == null:
			findings.append(_finding(SEVERITY_ERROR, &"", "A null action is present in the config."))
			continue

		var name := action.get_action_name()
		findings.append_array(_validate_action(action, name, seen_names, seen_signatures, reserved_keys))

	return findings


static func _validate_action(action: CommonUIAction, name: StringName, seen_names: Dictionary,
		seen_signatures: Dictionary, reserved_keys: Dictionary) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []

	if String(name).is_empty():
		findings.append(_finding(SEVERITY_ERROR, name, "An action has an empty name."))
		return findings

	if seen_names.has(name):
		findings.append(_finding(SEVERITY_ERROR, name,
			"Duplicate action name '%s'; the later definition shadows the earlier one." % name))
	seen_names[name] = true

	if not String(name).contains("/"):
		findings.append(_finding(SEVERITY_WARNING, name,
			"Action '%s' is not namespaced (no '/'); it may collide with a project action in InputMap." % name))

	# Defer to the resource's own native validation for anything structural.
	var native_error := action.get_validation_error()
	if not native_error.is_empty():
		findings.append(_finding(SEVERITY_ERROR, name, native_error))

	var bindings := action.get_default_bindings()
	if bindings.is_empty():
		var severity := SEVERITY_ERROR if action.get_protection() == CommonUIAction.PROTECTION_REQUIRED \
			else SEVERITY_WARNING
		var why := "a required action must always keep a binding" if severity == SEVERITY_ERROR \
			else "it can only fire if a binding is added at runtime"
		findings.append(_finding(severity, name,
			"Action '%s' defines no default binding; %s." % [name, why]))

	var context := action.get_conflict_context()
	for binding_variant in bindings:
		var binding: CommonUIBinding = binding_variant
		if binding == null:
			findings.append(_finding(SEVERITY_ERROR, name, "Action '%s' has a null binding." % name))
			continue
		findings.append_array(_validate_binding(binding, name, context, seen_signatures, reserved_keys))

	return findings


static func _validate_binding(binding: CommonUIBinding, name: StringName, context: StringName,
		seen_signatures: Dictionary, reserved_keys: Dictionary) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []

	# Two actions may share a physical event only when their conflict contexts
	# differ. Same signature + same context is a genuine, silent conflict.
	var signature := binding.get_signature()
	if seen_signatures.has(signature):
		var prior: Dictionary = seen_signatures[signature]
		if prior["context"] == context and prior["action"] != name:
			findings.append(_finding(SEVERITY_ERROR, name,
				"Actions '%s' and '%s' share the same physical binding in conflict context '%s'." % [
					prior["action"], name, _context_label(context)]))
	else:
		seen_signatures[signature] = {"action": name, "context": context}

	# A keyboard key the GUI stage already claims for a built-in ui_* action can
	# never reach framework routing while a Control has focus.
	if binding.get_device_kind() == CommonUIBinding.DEVICE_KEYBOARD and reserved_keys.has(binding.get_code()):
		findings.append(_finding(SEVERITY_WARNING, name,
			"Action '%s' binds key %s, which Godot's built-in '%s' already claims; framework routing cannot reach it while a Control has focus." % [
				name, OS.get_keycode_string(binding.get_code()), reserved_keys[binding.get_code()]]))

	return findings


## Keys currently bound to built-in `ui_*` actions, mapped to the action that
## claims them. Read from the live [InputMap].
static func _reserved_ui_keys() -> Dictionary:
	var reserved := {}
	for action in InputMap.get_actions():
		if not String(action).begins_with("ui_"):
			continue
		for event in InputMap.action_get_events(action):
			var key := event as InputEventKey
			if key == null:
				continue
			var code := key.physical_keycode if key.physical_keycode != 0 else key.keycode
			if code != 0 and not reserved.has(code):
				reserved[code] = action
	return reserved


static func _context_label(context: StringName) -> String:
	return String(context) if not String(context).is_empty() else "(none)"


static func _finding(severity: StringName, action: StringName, message: String) -> Dictionary:
	return {"severity": severity, "action": action, "message": message}


## Convenience: validate the configuration a runtime currently holds, plus (see
## the class doc comment) every action currently registered at runtime against
## that same config.
static func validate_runtime(runtime: CommonUIRuntime, check_ui_collisions := true) -> Array[Dictionary]:
	if runtime == null:
		return [_finding(SEVERITY_ERROR, &"", "No runtime was provided.")]
	var config := runtime.get_input_config()
	var findings := validate(config, check_ui_collisions)
	findings.append_array(_validate_registered_actions_have_bindings(runtime, config))
	return findings


## Registered-but-unbound actions: an id that appears in the runtime's active
## registrations (UI user 0, the common single-player/default case) but either
## has no definition in the config at all, or a definition with an empty
## binding list. Both mean the registration can never be driven by any input.
static func _validate_registered_actions_have_bindings(
		runtime: CommonUIRuntime, config: CommonUIInputConfig) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if config == null:
		return findings

	var has_bindings := {}
	for action_variant in config.get_actions():
		var action: CommonUIAction = action_variant
		if action != null:
			has_bindings[action.get_action_name()] = not action.get_default_bindings().is_empty()

	var reported := {}
	for entry in runtime.get_active_actions(0):
		var name: StringName = entry["action"]
		if reported.has(name) or (has_bindings.has(name) and has_bindings[name]):
			continue
		reported[name] = true
		if not has_bindings.has(name):
			findings.append(_finding(SEVERITY_WARNING, name,
				"Action '%s' is registered at runtime but the active config defines no such action; it can never be driven by any input." % name))
		else:
			findings.append(_finding(SEVERITY_WARNING, name,
				"Action '%s' is registered at runtime but its config definition has no bindings; it can never be driven by any input." % name))
	return findings


## True when no finding has [constant SEVERITY_ERROR] severity.
static func is_ok(findings: Array[Dictionary]) -> bool:
	for finding in findings:
		if finding["severity"] == SEVERITY_ERROR:
			return false
	return true


## A one-line-per-finding report suitable for logs or a label.
static func format(findings: Array[Dictionary]) -> String:
	if findings.is_empty():
		return "CommonUI action validation: OK"
	var lines := PackedStringArray()
	for finding in findings:
		lines.append("[%s] %s" % [String(finding["severity"]).to_upper(), finding["message"]])
	return "\n".join(lines)
