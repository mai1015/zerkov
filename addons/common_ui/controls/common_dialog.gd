@tool
class_name CommonDialog
extends CommonAnimatedScreen

## A reusable modal dialog: title, message, and confirm/cancel buttons.
##
## Ships with the addon so a consumer project has a working modal without
## building one. It is a [CommonAnimatedScreen], so pushing it onto a modal layer
## (see [CommonUIScreenRoot]) suspends the contexts beneath it, captures focus,
## routes the default [code]common_ui/confirm[/code] and [code]common_ui/back[/code]
## actions, and pops in with a subtle scale-and-fade. Games may inherit it,
## re-theme it, change [member CommonAnimatedScreen.enter_transition] /
## [member CommonAnimatedScreen.exit_transition], or replace it with their own
## scene that follows the same contract.
##
## It has two input modes. It opens in [b]quick-action mode[/b]: a hint glyph next
## to each button shows the confirm / cancel input for the active device (A / B on
## a pad, Enter / Esc on a keyboard), confirm activates the default button, and
## back dismisses. The first directional input switches to [b]focus mode[/b]: the
## hints hide, the player navigates between the buttons and confirms the focused
## one, and back moves focus to Cancel -- dismissing only when Cancel already has
## focus (so a second back cancels).

## Emitted when the player confirms (Confirm button or the confirm action).
signal confirmed
## Emitted when the player dismisses (Cancel button or the back action).
signal dismissed

@export var title_text: String = "":
	set(value):
		title_text = value
		if _title_label != null:
			_title_label.text = value
			_title_label.visible = not value.is_empty()

@export_multiline var message_text: String = "":
	set(value):
		message_text = value
		if _message_label != null:
			_message_label.text = value

@export var confirm_text: String = "OK":
	set(value):
		confirm_text = value
		if _confirm_button != null:
			_confirm_button.text = value

@export var cancel_text: String = "Cancel":
	set(value):
		cancel_text = value
		if _cancel_button != null:
			_cancel_button.text = value

## When false the dialog is a single-button alert: the cancel button is hidden
## and the back action still dismisses it.
@export var show_cancel: bool = true:
	set(value):
		show_cancel = value
		if _cancel_button != null:
			_cancel_button.visible = value
		if _cancel_glyph != null:
			_cancel_glyph.visible = value

var _panel: PanelContainer
var _title_label: Label
var _message_label: Label
var _confirm_button: CommonButton
var _cancel_button: CommonButton
## Presentation-only hints showing which input confirms / cancels, for the active
## device (A / B on a pad, Enter / Esc on a keyboard). Shown in quick-action mode,
## hidden once the player starts navigating with focus.
var _confirm_glyph: InputGlyph
var _cancel_glyph: InputGlyph
## Directional actions whose first press flips the dialog into focus mode.
const _NAV_ACTIONS := ["ui_left", "ui_right", "ui_up", "ui_down"]
## False while the player uses the A / B shortcuts; true once they navigate focus.
var _focus_navigating := false
## Supplied by the owning screen root so the dialog can suspend everything below
## it. Left empty when pushed directly.
var _lower_contexts: Array[CommonUIContextHandle] = []


func _init() -> void:
	if name.is_empty():
		name = "CommonDialog"
	# A dialog owns the screen: its own context outranks and suspends the rest.
	screen_context = &"dialog"
	context_priority = CommonUIDefaults.PRIORITY_MODAL
	suspends_lower_contexts = true
	# A modal reads best popping in and out rather than sliding.
	enter_transition = Transition.SCALE
	exit_transition = Transition.SCALE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Blocks pointer input to the screens underneath, the way a modal should.
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func _build() -> void:
	if _panel != null:
		return

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.theme_type_variation = &"CommonDialogTitle"
	_title_label.text = title_text
	_title_label.visible = not title_text.is_empty()
	box.add_child(_title_label)

	_message_label = Label.new()
	_message_label.name = "Message"
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.text = message_text
	box.add_child(_message_label)

	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)

	# Cancel first so Confirm sits on the trailing edge, the platform-neutral
	# ordering. Cancel maps to the back action; Confirm to the confirm action.
	_cancel_button = CommonButton.new()
	_cancel_button.name = "CancelButton"
	_cancel_button.text = cancel_text
	_cancel_button.show_glyph = false
	_cancel_button.visible = show_cancel
	_cancel_glyph = _hint_glyph(CommonUIDefaults.BACK)
	_cancel_glyph.visible = show_cancel
	buttons.add_child(_cancel_glyph)
	buttons.add_child(_cancel_button)

	_confirm_button = CommonButton.new()
	_confirm_button.name = "ConfirmButton"
	_confirm_button.text = confirm_text
	_confirm_button.show_glyph = false
	_confirm_glyph = _hint_glyph(CommonUIDefaults.CONFIRM)
	buttons.add_child(_confirm_glyph)
	buttons.add_child(_confirm_button)

	# Explicit two-button cycle between Cancel and Confirm, authored here rather
	# than left to the modal focus trap's generic containment: the trap only
	# redirects a path that would otherwise escape the modal, it does not invent
	# wrap-around for a control at a dead end (a design any grid-shaped modal
	# needs to navigate correctly by real spatial position, not a fixed wrap).
	# A two-button row is the one shape simple enough to just wire directly, so
	# every direction here ping-pongs between the pair.
	_cancel_button.focus_neighbor_left = _cancel_button.get_path_to(_confirm_button)
	_cancel_button.focus_neighbor_right = _cancel_button.get_path_to(_confirm_button)
	_cancel_button.focus_neighbor_top = _cancel_button.get_path_to(_confirm_button)
	_cancel_button.focus_neighbor_bottom = _cancel_button.get_path_to(_confirm_button)
	_cancel_button.focus_next = _cancel_button.get_path_to(_confirm_button)
	_cancel_button.focus_previous = _cancel_button.get_path_to(_confirm_button)
	_confirm_button.focus_neighbor_left = _confirm_button.get_path_to(_cancel_button)
	_confirm_button.focus_neighbor_right = _confirm_button.get_path_to(_cancel_button)
	_confirm_button.focus_neighbor_top = _confirm_button.get_path_to(_cancel_button)
	_confirm_button.focus_neighbor_bottom = _confirm_button.get_path_to(_cancel_button)
	_confirm_button.focus_next = _confirm_button.get_path_to(_cancel_button)
	_confirm_button.focus_previous = _confirm_button.get_path_to(_cancel_button)

	# self is the root of this detached subtree, so the path resolves even before
	# the dialog enters the scene tree.
	default_focus = get_path_to(_confirm_button)


## A presentation-only glyph that shows the active-device binding for an action.
## It registers nothing, so it never affects routing.
func _hint_glyph(action: StringName) -> InputGlyph:
	var glyph := InputGlyph.new()
	glyph.action = action
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return glyph


## Sets the dialog's copy in one call. Returns self so a caller can chain before
## pushing.
func configure(p_title: String, p_message: String, p_confirm := "OK",
		p_cancel := "Cancel", p_show_cancel := true) -> CommonDialog:
	title_text = p_title
	message_text = p_message
	confirm_text = p_confirm
	cancel_text = p_cancel
	show_cancel = p_show_cancel
	return self


## Contexts opened by screens below this dialog, supplied by the screen root so
## activation can suspend them. See [method CommonUIScreenRoot.open_dialog].
func set_lower_contexts(handles: Array[CommonUIContextHandle]) -> void:
	_lower_contexts = handles


func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
	return _lower_contexts


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Connected once here rather than in _on_activated, which runs again on
	# every re-activation (e.g. a modal pushed above this dialog closing). A
	# lambda compares by reference, so reconnecting a fresh one each time --
	# even with CONNECT_REFERENCE_COUNTED -- would add a second, independent
	# connection and fire `confirmed` / `dismissed` twice per press. Named
	# methods connected once in _ready avoid that entirely.
	_confirm_button.triggered.connect(_on_confirm_button_triggered)
	_cancel_button.triggered.connect(_on_cancel_button_triggered)


func _on_confirm_button_triggered() -> void:
	confirmed.emit()


func _on_cancel_button_triggered() -> void:
	dismissed.emit()


func _on_activated() -> void:
	if Engine.is_editor_hint():
		return
	# Every dialog opens in quick-action mode: the A / B hints are shown and Back
	# dismisses directly. The first directional input switches to focus mode.
	_focus_navigating = false
	_update_hint_visibility()

	# Confirm accepts; Back dismisses. Both stop routing so nothing beneath the
	# dialog sees the same press.
	register_action(CommonUIDefaults.CONFIRM, func(event: Dictionary) -> int:
		if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
			return CommonUIRuntime.ROUTE_UNHANDLED
		# The confirm input is also `ui_accept`, so a focused button already
		# activates from it (confirm, or dismiss when Cancel is focused). Stepping
		# in here too would fire a second time -- confirming while Cancel dismisses.
		# Only confirm from the framework action when focus is off the buttons.
		var focused := get_viewport().gui_get_focus_owner()
		if focused is BaseButton and is_ancestor_of(focused):
			return CommonUIRuntime.ROUTE_UNHANDLED
		confirmed.emit()
		return CommonUIRuntime.ROUTE_HANDLED)
	register_action(CommonUIDefaults.BACK, func(event: Dictionary) -> int:
		if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
			return CommonUIRuntime.ROUTE_UNHANDLED
		# In focus mode a Back first highlights Cancel so the player sees what they
		# are about to do; pressing it again -- now with Cancel focused -- dismisses.
		# Quick-action mode and a single-button alert dismiss on the first Back.
		if _focus_navigating and _cancel_button.visible \
				and get_viewport().gui_get_focus_owner() != _cancel_button:
			_cancel_button.grab_focus()
		else:
			dismissed.emit()
		return CommonUIRuntime.ROUTE_HANDLED)


## The first directional input while the dialog is open switches it from
## quick-action mode (A / B hint shortcuts) to focus mode (navigate, then confirm
## the focused button). Observed, never consumed, so focus navigation still runs.
func _input(event: InputEvent) -> void:
	if _focus_navigating or Engine.is_editor_hint() or not is_routing_active():
		return
	for nav in _NAV_ACTIONS:
		if event.is_action_pressed(nav):
			_focus_navigating = true
			_update_hint_visibility()
			return


func _update_hint_visibility() -> void:
	if _confirm_glyph != null:
		_confirm_glyph.visible = not _focus_navigating
	if _cancel_glyph != null:
		_cancel_glyph.visible = show_cancel and not _focus_navigating
