@tool
class_name GADiagnosticOverlay
extends PanelContainer

## A minimal runtime diagnostic inspector for one LOCAL [GameplayAbilityComponent]
## (task 9.3). Modeled directly on
## [code]addons/common_ui/diagnostics/common_ui_diagnostic_overlay.gd[/code]:
## a single [RichTextLabel], rebuilt from signals plus a light polling timer
## for state that has no dedicated change signal.
##
## VISIBILITY RULE -- read this before wiring the overlay to anything:
## this overlay is a strictly LOCAL diagnostic. It never queries another
## peer's component, never bypasses [GameplayAbilityNetworkBridge]'s
## visibility filtering, and never becomes a new way to observe another
## peer's owner-only state. It is driven ONLY by:
##   - the public accessors and signals of the ONE [GameplayAbilityComponent]
##     named by [member component_path], already present in THIS scene tree
##     on THIS peer, and
##   - optionally, the public signals of the ONE [GameplayAbilityNetworkBridge]
##     (named by [member bridge_path]) already attached to that SAME local
##     component, purely for the authoritative-sequence/replication-gap
##     figures a bridge tracks that the component itself does not.
## Whatever that component/bridge pair already legitimately holds locally --
## full authoritative state for an owned/authority entity, or only the
## relevance-filtered public state for a merely-observed one -- is exactly,
## and only, what this overlay can show. It adds no new query surface, no
## cross-peer lookup, and no privileged accessor; every field below is one
## already-public getter or signal payload field on those two node types.
##
## Bounded output: every list is capped at [member max_list_items] entries.
## Every string this overlay prints is a locally-authored resource
## identifier or a stable enum name -- never an unbounded network-supplied
## string (the protocol never puts free-text client diagnostics on the wire
## in the first place; see design.md "Security and failure policy").
##
## Tag/attribute *activity* below is resolved through
## [method GameplayAbilityComponent.resolve_tag_identifier] /
## [method GameplayAbilityComponent.resolve_attribute_identifier] (task
## 12.3's ergonomic follow-up), so it reads the same identifier the CURRENT
## owned-tag and initialized-attribute name lists already used -- falls back
## to the raw numeric [code]DefinitionId[/code] only if resolution somehow
## fails (e.g. a stale record from before configure()).

## Path to the local [GameplayAbilityComponent] to inspect.
@export var component_path: NodePath
## Optional path to the local [GameplayAbilityNetworkBridge] attached to that
## same component, for authoritative-sequence and replication-gap detail the
## component alone does not track. May be left empty.
@export var bridge_path: NodePath
## Show or hide the whole panel.
@export var overlay_visible: bool = true:
	set(value):
		overlay_visible = value
		visible = value
## Refresh cadence for state that changes without a dedicated signal.
@export var refresh_interval: float = 0.25
## Bound on every list this overlay renders.
@export var max_list_items: int = 12

const _ROLE_NAMES := {
	0: "offline authority", 1: "server authority", 2: "network client",
}
const _PHASE_NAMES := {
	0: "requested", 1: "validating", 2: "begun", 3: "committed",
	4: "active", 5: "ended", 6: "cancelled",
}
const _CUE_PHASE_NAMES := {
	0: "predict", 1: "confirm", 2: "correct", 3: "cancel",
	4: "authority-only", 5: "snapshot-restored",
}
const _EFFECT_LIFECYCLE_NAMES := {
	0: "applied", 1: "stack-changed", 2: "periodic", 3: "removed", 4: "expired",
}

var _label: RichTextLabel
var _timer: Timer
var _component: GameplayAbilityComponent = null
var _bridge: GameplayAbilityNetworkBridge = null

# Bounded ring buffers / maps, populated ONLY from the local component's/
# bridge's own signals -- see the class-level visibility rule.
var _tag_activity: Array = []
var _attribute_activity: Array = []
var _active_effects: Dictionary = {} # handle(int) -> {identifier, stacks, start_tick, last_period_base_tick, last_tick}
var _effect_definitions_by_identifier: Dictionary = {} # String -> GameplayEffectDefinition
var _pending_predictions: Dictionary = {} # prediction_key(int) -> {execution, phase}
var _replication_gaps: Array = []
var _diagnostics_log: Array = []
var _confirmed_sequence: int = -1
var _last_ack_sequence: int = -1
var _last_rejected_sequence: int = -1


func _ready() -> void:
	_build()
	visible = overlay_visible
	if Engine.is_editor_hint() or not is_inside_tree():
		return

	_timer = Timer.new()
	_timer.wait_time = maxf(0.02, refresh_interval)
	_timer.autostart = true
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_refresh()


## Resolves [member component_path]/[member bridge_path] and wires signals
## exactly once. Idempotent, and safe to retry: `component_path` may not
## resolve yet the first time this runs (e.g. it is set right after
## `add_child`, in the same frame `_ready` already ran -- the same "resolve
## lazily, not only once in `_ready`" convention
## [code]GameplayAbilityNetworkBridge.resolve_component()[/code] already
## uses), so [method _refresh] calls this on every tick until it succeeds.
func _ensure_wired() -> bool:
	if _component != null:
		return true
	_component = get_node_or_null(component_path) as GameplayAbilityComponent
	if _component == null:
		return false

	for resource in _component.get_effect_definitions():
		var effect_def: GameplayEffectDefinition = resource
		if effect_def != null:
			_effect_definitions_by_identifier[String(effect_def.get_identifier())] = effect_def

	_component.ability_granted.connect(_on_state_changed)
	_component.ability_revoked.connect(_on_state_changed)
	_component.activation_requested.connect(_on_state_changed)
	_component.activation_phase_changed.connect(_on_state_changed)
	_component.activation_committed.connect(_on_state_changed)
	_component.activation_ended.connect(_on_state_changed)
	_component.activation_cancelled.connect(_on_state_changed)
	_component.activation_failed.connect(_on_state_changed)
	_component.ability_snapshot_restored.connect(_on_state_changed)
	_component.attribute_changed.connect(_on_attribute_changed)
	_component.tag_changed.connect(_on_tag_changed)
	_component.effect_lifecycle_changed.connect(_on_effect_lifecycle_changed)
	_component.prediction_phase_changed.connect(_on_prediction_phase_changed)
	_component.replication_gap_detected.connect(_on_component_replication_gap)
	_component.diagnostics_reported.connect(_on_diagnostics_reported)

	if not bridge_path.is_empty():
		_bridge = get_node_or_null(bridge_path) as GameplayAbilityNetworkBridge
	if _bridge != null:
		_bridge.state_synced.connect(_on_state_synced)
		_bridge.command_acknowledged.connect(_on_command_acknowledged)
		_bridge.command_rejected.connect(_on_command_rejected)
		_bridge.replication_gap.connect(_on_bridge_replication_gap)

	return true


func _build() -> void:
	if _label != null:
		return
	custom_minimum_size = Vector2(420, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.custom_minimum_size = Vector2(400, 0)
	add_child(_label)


func toggle() -> void:
	overlay_visible = not overlay_visible


# --- Signal handlers: bounded bookkeeping only, never a core mutation ------

func _on_state_changed(_arg0: Variant = null) -> void:
	_refresh()


func _on_attribute_changed(record: Dictionary) -> void:
	_push_bounded(_attribute_activity, record)
	_refresh()


func _on_tag_changed(record: Dictionary) -> void:
	_push_bounded(_tag_activity, record)
	_refresh()


func _on_effect_lifecycle_changed(record: Dictionary) -> void:
	var handle := int(record.get("handle", 0))
	var kind := int(record.get("kind", 0))
	if handle <= 0:
		# INSTANT effects apply with no durable handle (design.md "Gameplay
		# effects": "Instant effects execute atomically and do not remain
		# active") -- nothing to track as an active effect.
		_refresh()
		return
	if kind == GameplayAbilityComponent.EFFECT_LIFECYCLE_REMOVED or kind == GameplayAbilityComponent.EFFECT_LIFECYCLE_EXPIRED:
		_active_effects.erase(handle)
		_refresh()
		return

	var entry: Dictionary = _active_effects.get(handle, {})
	var tick := int(record.get("tick", 0))
	if entry.is_empty():
		entry = {
			"identifier": String(record.get("definition_identifier", "")),
			"start_tick": tick,
			"last_period_base_tick": tick,
		}
	entry["stacks"] = int(record.get("stack_count_after", 1))
	entry["last_tick"] = tick
	entry["last_kind"] = kind
	if kind == GameplayAbilityComponent.EFFECT_LIFECYCLE_PERIODIC_EXECUTED:
		entry["last_period_base_tick"] = tick
	_active_effects[handle] = entry
	_refresh()


func _on_prediction_phase_changed(payload: Dictionary) -> void:
	var key := int(payload.get("prediction_key", 0))
	var phase := int(payload.get("phase", GameplayAbilityComponent.CUE_PREDICT))
	match phase:
		GameplayAbilityComponent.CUE_PREDICT:
			_pending_predictions[key] = {"execution": payload.get("execution", 0), "phase": phase}
		GameplayAbilityComponent.CUE_CONFIRM, GameplayAbilityComponent.CUE_CORRECT, GameplayAbilityComponent.CUE_CANCEL:
			_pending_predictions.erase(key)
		_:
			pass
	_refresh()


func _on_component_replication_gap(payload: Dictionary) -> void:
	_push_bounded(_replication_gaps, {
		"source": "component", "reason_code": payload.get("reason_code", 0), "detail": payload.get("detail", 0),
	})
	_refresh()


func _on_bridge_replication_gap(info: Dictionary) -> void:
	_push_bounded(_replication_gaps, {
		"source": "bridge", "reason_code": info.get("code", 0), "detail": info.get("detail", 0),
	})
	_refresh()


func _on_diagnostics_reported(event: Dictionary) -> void:
	_push_bounded(_diagnostics_log, event)
	_refresh()


func _on_state_synced(info: Dictionary) -> void:
	_confirmed_sequence = int(info.get("confirmed_sequence", _confirmed_sequence))
	_refresh()


func _on_command_acknowledged(result: Dictionary) -> void:
	_last_ack_sequence = int(result.get("command_sequence", _last_ack_sequence))
	_refresh()


func _on_command_rejected(result: Dictionary) -> void:
	_last_rejected_sequence = int(result.get("command_sequence", _last_rejected_sequence))
	_refresh()


func _push_bounded(list: Array, item: Variant) -> void:
	list.append(item)
	while list.size() > max_list_items:
		list.pop_front()


# --- Rendering ---------------------------------------------------------------

func _refresh() -> void:
	if _label == null:
		return
	if not _ensure_wired():
		_label.text = "GameplayAbilities diagnostics: component_path does not resolve to a GameplayAbilityComponent."
		return

	var out := PackedStringArray()
	out.append("[b]GameplayAbilities diagnostics[/b]")
	out.append("role: %s  entity: %d  owner_valid: %s  configured: %s" % [
		_ROLE_NAMES.get(_component.get_role(), "?"), _component.get_entity_id(),
		_component.is_owner_valid(), _component.is_configured()])
	var sequence_line := "tick: %d" % _component.get_current_tick()
	if _confirmed_sequence >= 0:
		sequence_line += "  confirmed_sequence: %d" % _confirmed_sequence
	if _last_ack_sequence >= 0:
		sequence_line += "  last_ack: %d" % _last_ack_sequence
	if _last_rejected_sequence >= 0:
		sequence_line += "  last_rejected: %d" % _last_rejected_sequence
	out.append(sequence_line)

	out.append("")
	out.append("[b]owned tags[/b] (%d)" % _component.owned_tags().size())
	out.append_array(_bounded_lines(_component.owned_tags(), func(tag: String) -> String: return "  %s" % tag))
	if not _tag_activity.is_empty():
		out.append("  recent activity:")
		for record in _tag_activity:
			var tag_id := int(record.get("tag", 0))
			var tag_name := _component.resolve_tag_identifier(tag_id)
			out.append("    %s  %s  count=%d  rev=%d" % [
				tag_name if not tag_name.is_empty() else "id=%d" % tag_id,
				"added" if record.get("added", false) else "removed",
				int(record.get("owner_count_after", 0)), int(record.get("revision_after", 0))])

	out.append("")
	var attribute_names := _component.get_initialized_attributes()
	out.append("[b]attributes[/b] (%d)" % attribute_names.size())
	var attr_count := 0
	for identifier in attribute_names:
		if attr_count >= max_list_items:
			out.append("  ... (%d more)" % (attribute_names.size() - attr_count))
			break
		out.append("  %s  base=%.3f  current=%.3f" % [
			identifier, _component.get_attribute_base(identifier), _component.get_attribute_current(identifier)])
		attr_count += 1
	if not _attribute_activity.is_empty():
		out.append("  recent activity:")
		for record in _attribute_activity:
			var attribute_id := int(record.get("attribute", 0))
			var attribute_name := _component.resolve_attribute_identifier(attribute_id)
			out.append("    %s  base %.3f->%.3f  current %.3f->%.3f  rev=%d" % [
				attribute_name if not attribute_name.is_empty() else "id=%d" % attribute_id,
				float(record.get("old_base", 0.0)), float(record.get("new_base", 0.0)),
				float(record.get("old_current", 0.0)), float(record.get("new_current", 0.0)),
				int(record.get("revision", 0))])

	out.append("")
	out.append("[b]active effects[/b] (%d)" % _active_effects.size())
	var effect_count := 0
	var current_tick := _component.get_current_tick()
	for handle in _active_effects.keys():
		if effect_count >= max_list_items:
			out.append("  ... (%d more)" % (_active_effects.size() - effect_count))
			break
		var entry: Dictionary = _active_effects[handle]
		var timing := _estimate_effect_timing(entry, current_tick)
		var remaining_suffix := ""
		if int(timing["remaining_duration"]) >= 0:
			remaining_suffix = "  remaining~=%d" % int(timing["remaining_duration"])
		var next_period_suffix := ""
		if int(timing["next_period"]) >= 0:
			next_period_suffix = "  next_period~=%d" % int(timing["next_period"])
		out.append("  %s  stacks=%d  handle=%d  last=%s%s%s" % [
			entry.get("identifier", "?"), int(entry.get("stacks", 1)), int(handle),
			_EFFECT_LIFECYCLE_NAMES.get(int(entry.get("last_kind", 0)), "?"),
			remaining_suffix, next_period_suffix])
		effect_count += 1

	out.append("")
	var grants := _component.granted_specs()
	out.append("[b]granted abilities[/b] (%d)" % grants.size())
	var grant_count := 0
	for spec in grants:
		if grant_count >= max_list_items:
			out.append("  ... (%d more)" % (grants.size() - grant_count))
			break
		var grant := _component.get_grant(spec)
		out.append("  %s  spec=%d  level=%d  revoked=%s" % [
			grant.get("ability_identifier", "?"), spec, int(grant.get("level", 0)), grant.get("revoked", false)])
		grant_count += 1

	out.append("")
	var executions := _component.active_executions()
	out.append("[b]active executions[/b] (%d)" % executions.size())
	var exec_count := 0
	for execution in executions:
		if exec_count >= max_list_items:
			out.append("  ... (%d more)" % (executions.size() - exec_count))
			break
		var record := _component.get_execution(execution)
		out.append("  %s  execution=%d  phase=%s" % [
			record.get("ability_identifier", "?"), execution, _PHASE_NAMES.get(int(record.get("phase", 0)), "?")])
		exec_count += 1

	out.append("")
	out.append("[b]pending predictions[/b] (%d)" % _pending_predictions.size())
	var pred_count := 0
	for key in _pending_predictions.keys():
		if pred_count >= max_list_items:
			out.append("  ... (%d more)" % (_pending_predictions.size() - pred_count))
			break
		var entry: Dictionary = _pending_predictions[key]
		out.append("  prediction_key=%d  execution=%d  phase=%s" % [
			key, int(entry.get("execution", 0)), _CUE_PHASE_NAMES.get(int(entry.get("phase", 0)), "?")])
		pred_count += 1

	out.append("")
	out.append("[b]replication gaps[/b] (%d recent)" % _replication_gaps.size())
	for gap in _replication_gaps:
		out.append("  [%s] reason_code=%d detail=%d" % [gap.get("source", "?"), int(gap.get("reason_code", 0)),
			int(gap.get("detail", 0))])

	_label.text = "\n".join(out)


func _estimate_effect_timing(entry: Dictionary, current_tick: int) -> Dictionary:
	var timing := {"remaining_duration": -1, "next_period": -1}
	var definition: GameplayEffectDefinition = _effect_definitions_by_identifier.get(entry.get("identifier", ""), null)
	if definition == null:
		return timing
	if definition.get_duration_policy() == GameplayEffectDefinition.DURATION_DURATION:
		var end_tick: int = int(entry.get("start_tick", current_tick)) + int(definition.get_duration_ticks())
		timing["remaining_duration"] = maxi(0, end_tick - current_tick)
	if definition.get_has_period():
		var next_tick: int = int(entry.get("last_period_base_tick", current_tick)) + int(definition.get_period_ticks())
		timing["next_period"] = maxi(0, next_tick - current_tick)
	return timing


func _bounded_lines(values: PackedStringArray, formatter: Callable) -> PackedStringArray:
	var lines := PackedStringArray()
	if values.is_empty():
		lines.append("  (none)")
		return lines
	var count := 0
	for value in values:
		if count >= max_list_items:
			lines.append("  ... (%d more)" % (values.size() - count))
			break
		lines.append(formatter.call(value))
		count += 1
	return lines
