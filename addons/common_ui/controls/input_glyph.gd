@tool
class_name InputGlyph
extends HBoxContainer

## Presentation-only widget for one action's input glyph.
##
## It translates the logical glyph identifier the native subsystem reports into
## a project-supplied texture or localized text. It never inspects physical
## input and never resolves binding conflicts; changing what it shows never
## changes an action definition or a binding.

## Emitted when a requested glyph is missing from [member glyph_set]. Non-fatal:
## the widget shows the resolver-provided fallback instead.
signal glyph_missing(glyph_id: StringName)

@export var action: StringName = &"":
	set(value):
		action = value
		_refresh()

## 0 for the primary binding, 1 for the secondary.
@export_range(0, 1) var slot: int = 0:
	set(value):
		slot = value
		_refresh()

## Maps a logical glyph identifier to a Texture2D.
@export var glyph_set: Dictionary = {}:
	set(value):
		glyph_set = value
		_refresh()

## Shown when the glyph set has no asset for the resolved identifier.
@export var text_fallback: String = "":
	set(value):
		text_fallback = value
		_refresh()

@export var glyph_size: Vector2i = Vector2i(24, 24):
	set(value):
		glyph_size = value
		_refresh()

var _texture_rect: TextureRect
var _label: Label
var _resolved_glyph: StringName = &""
## (action, modality) signature the last [signal glyph_missing] was emitted for,
## so a widget with no glyph_set (the default) does not re-emit on every single
## refresh -- only when the missing action or the active modality actually
## changes. Cleared whenever the current resolution is not missing.
var _last_missing_signature: String = ""


func _ready() -> void:
	_build()
	if Engine.is_editor_hint():
		_refresh()
		return
	var runtime := _get_runtime()
	if runtime != null:
		runtime.input_modality_changed.connect(_on_modality_changed)
		var registry := runtime.get_binding_registry()
		if registry != null:
			registry.bindings_changed.connect(_refresh)
	_refresh()


func _get_runtime() -> CommonUIRuntime:
	# An absolute path is only resolvable while inside the tree; nodes that are
	# tearing down must not try to reach the autoload.
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _build() -> void:
	if _texture_rect != null:
		return
	# Presentation-only: this widget never handles pointer input itself, so it
	# must never sit in front of one that does. Every Control defaults to
	# MOUSE_FILTER_STOP, which is exactly why an unnamed InputGlyph auto-added
	# to the top-left of a CommonButton (or any other interactive control it is
	# parented to) used to swallow clicks meant for the control beneath it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_texture_rect = TextureRect.new()
	_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_texture_rect)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)


func get_resolved_glyph() -> StringName:
	return _resolved_glyph


## The text currently shown, or "" when hidden or when a texture is shown
## instead. Public for diagnostics and tests.
func get_display_text() -> String:
	if not is_visible_in_tree():
		return ""
	return _label.text if _label != null and _label.visible else ""


func _on_modality_changed(_modality: int, _device: int) -> void:
	_refresh()


func _refresh() -> void:
	if _texture_rect == null or _label == null:
		return
	_texture_rect.custom_minimum_size = glyph_size

	var runtime := _get_runtime()
	_resolved_glyph = runtime.resolve_glyph(action, slot) if runtime != null else &""

	var texture: Texture2D = null
	var is_missing := false
	if not String(_resolved_glyph).is_empty():
		if glyph_set.has(_resolved_glyph):
			texture = glyph_set[_resolved_glyph]
		else:
			is_missing = true

	if is_missing:
		# The resolver produced an identifier this project has no art for.
		# Signature, not a plain per-call emit: bindings_changed and modality
		# changes can both trigger _refresh() repeatedly while nothing about the
		# missing state actually changed, and each would otherwise re-emit.
		var modality := runtime.get_input_modality() if runtime != null else -1
		var signature := "%s#%d" % [String(action), modality]
		if signature != _last_missing_signature:
			_last_missing_signature = signature
			glyph_missing.emit(_resolved_glyph)
	else:
		_last_missing_signature = ""

	_texture_rect.texture = texture
	_texture_rect.visible = texture != null

	var fallback := text_fallback
	if fallback.is_empty() and texture == null:
		fallback = _readable_binding(runtime)
	_label.text = fallback
	_label.visible = texture == null and not fallback.is_empty()


## Human-readable label for the current binding, shown when the project ships no
## glyph texture for the resolved identifier. Falls back to the raw glyph id so
## something is always visible.
func _readable_binding(runtime: CommonUIRuntime) -> String:
	if runtime != null:
		var registry := runtime.get_binding_registry()
		if registry != null:
			# Prefer the binding for the active device, so a controller shows its
			# button and a keyboard shows its key; fall back to this glyph's slot.
			var text := _binding_for_modality(registry, runtime.get_input_modality())
			if text.is_empty():
				text = CommonBindingText.describe(
					registry.get_effective_binding(action, slot as CommonInputBindingRegistry.Slot))
			if not text.is_empty():
				return text
	return String(_resolved_glyph)


## Checks this widget's own [member slot] first -- the same one [method _refresh]
## passes to [method CommonUIRuntime.resolve_glyph] for the texture path -- and
## only then the other slot. Both are still considered (a widget showing a
## quick-action hint has no fixed slot preference of its own and needs whichever
## binding matches the active device, e.g. Enter on keyboard vs. A on a pad, to
## keep working), but when more than one binding matches the current modality,
## the widget's own slot wins instead of always favouring
## [constant CommonInputBindingRegistry.SLOT_PRIMARY] regardless of `slot`.
func _binding_for_modality(registry: CommonInputBindingRegistry, modality: int) -> String:
	var own_slot := slot as CommonInputBindingRegistry.Slot
	var other_slot := CommonInputBindingRegistry.SLOT_SECONDARY \
		if own_slot == CommonInputBindingRegistry.SLOT_PRIMARY else CommonInputBindingRegistry.SLOT_PRIMARY
	for candidate_slot in [own_slot, other_slot]:
		var binding := registry.get_effective_binding(action, candidate_slot)
		if binding != null and binding.is_valid_binding() and _matches_modality(binding, modality):
			return CommonBindingText.describe(binding)
	return ""


func _matches_modality(binding: CommonUIBinding, modality: int) -> bool:
	var kind := binding.get_device_kind()
	match modality:
		CommonUIRuntime.MODALITY_GAMEPAD:
			return kind == CommonUIBinding.DEVICE_GAMEPAD_BUTTON or kind == CommonUIBinding.DEVICE_GAMEPAD_AXIS
		CommonUIRuntime.MODALITY_TOUCH:
			return kind == CommonUIBinding.DEVICE_TOUCH
		_:
			return kind == CommonUIBinding.DEVICE_KEYBOARD or kind == CommonUIBinding.DEVICE_MOUSE
