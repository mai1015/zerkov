extends SceneTree

## Task 8.9 visual evidence. Every case mounts an existing authored screen in
## an explicit fixture-provider session, focuses one real gated control, and
## activates it through a real input event. The guarded callback must show the
## typed prototype status and leave fixture state, route and modal ownership
## unchanged. Native evidence is read directly from a dedicated 1920x1080
## renderer-backed SubViewport; no root framebuffer resampling or alternate-
## size output is permitted.
##
## Run headless for source/visibility assertions:
## godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd
##
## Run natively for evidence:
## godot --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd -- --capture-dir=res://docs/qa/feature_gates_8_9

const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)
const DEFAULT_CAPTURE_DIR := "res://docs/qa/feature_gates_8_9"
const CONTACT_CROP_SIZE := Vector2i(960, 216)
const CASES: Array[Dictionary] = [
	{
		"id": &"bunker",
		"route": "bunker",
		"path": "Stations/Row1/Hit",
		"file": "bunker",
		"input": &"keyboard_enter",
		"upper": Rect2i(0, 72, 960, 216),
		"lower": Rect2i(480, 864, 960, 216),
	},
	{
		"id": &"crafting",
		"route": "crafting",
		"path": "DetailPanel/CraftNow",
		"file": "crafting",
		"input": &"mouse_primary",
		"upper": Rect2i(0, 72, 960, 216),
		"lower": Rect2i(480, 864, 960, 216),
	},
	{
		"id": &"friends",
		"route": "join_friend",
		"path": "FilterAll",
		"file": "friends",
		"input": &"keyboard_enter",
		"upper": Rect2i(0, 64, 960, 216),
		"lower": Rect2i(480, 864, 960, 216),
	},
	{
		"id": &"insurance",
		"route": "summary_solo",
		"path": "Reinsure",
		"file": "insurance",
		"input": &"keyboard_enter",
		"upper": Rect2i(960, 864, 960, 216),
		"lower": Rect2i(480, 864, 960, 216),
	},
	{
		"id": &"marketplace",
		"route": "inventory",
		"path": "InventoryContent/PostRaidBar/SellJunk",
		"file": "marketplace",
		"input": &"mouse_primary",
		"upper": Rect2i(960, 48, 960, 216),
		"lower": Rect2i(480, 864, 960, 216),
	},
]

var checks: int = 0
var failures: int = 0
var capture_dir: String = DEFAULT_CAPTURE_DIR
var frames: Array[Image] = []
var target: SubViewport
var app: Control
var capture_aborted: bool = false
var exact_cli_resolution: bool = false


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			capture_dir = argument.trim_prefix("--capture-dir=")
	exact_cli_resolution = _has_exact_cli_resolution()
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		capture_aborted = true
		push_error("FEATURE_GATES_8_9_VISUAL: " + message)


func settle(frames_to_wait: int = 6) -> void:
	for _index in range(frames_to_wait):
		await process_frame


func _has_exact_cli_resolution() -> bool:
	# Godot consumes --resolution before OS.get_cmdline_args(). Inspect only this
	# process's real argv through ps; never accept a forwarded user-argument
	# claim as proof of the engine flag. Unsupported hosts fail before mounting.
	# https://docs.godotengine.org/en/stable/classes/class_os.html#class-os-method-get-cmdline-args
	if OS.get_name() not in ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return false
	var output: Array = []
	var status := OS.execute("/bin/ps",
		PackedStringArray(["-ww", "-p", str(OS.get_process_id()), "-o", "command="]), output)
	if status != 0 or output.size() != 1:
		return false
	var engine_command := str(output[0]).strip_edges().split(" -- ", true, 1)[0]
	var expression := RegEx.new()
	if expression.compile("(?:^|[[:space:]])--resolution(?:[[:space:]]+|=)([^[:space:]]+)") != OK:
		return false
	var matches := expression.search_all(engine_command)
	return matches.size() == 1 and matches[0].get_string(1) == "1920x1080"


func _new_render_target() -> SubViewport:
	var result := SubViewport.new()
	result.name = "Task89Exact1920RenderTarget"
	result.disable_3d = true
	result.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	result.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	result.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	result.snap_2d_transforms_to_pixel = true
	result.size = FIRST_PLAYABLE_SIZE
	root.add_child(result)
	var input_router := CommonUIViewportRouter.new()
	input_router.name = "Task89Exact1920InputRouter"
	result.add_child(input_router)
	return result


func run() -> void:
	if DisplayServer.get_name() != "headless" and not await _native_output_preflight():
		print("FEATURE_GATES_8_9_VISUAL_RESULT checks=0 failures=1 size=1920x1080 frames=0 preflight=rejected")
		quit(2)
		return
	check(exact_cli_resolution,
		"screen-producing CLI explicitly requests --resolution 1920x1080")
	if not exact_cli_resolution:
		quit(2)
		return
	root.size = FIRST_PLAYABLE_SIZE
	check(root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"orchestration root is exact 1920x1080")
	if root.get_visible_rect().size != Vector2(FIRST_PLAYABLE_SIZE):
		quit(2)
		return

	target = _new_render_target()
	check(target.size == FIRST_PLAYABLE_SIZE,
		"dedicated renderer target requests exact 1920x1080")
	check(target.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"dedicated renderer target visible rect is exact 1920x1080")
	var target_texture := target.get_texture()
	check(target_texture != null and target_texture.get_size() == Vector2(FIRST_PLAYABLE_SIZE),
		"dedicated renderer target texture is exact 1920x1080")
	if target.size != FIRST_PLAYABLE_SIZE \
			or target.get_visible_rect().size != Vector2(FIRST_PLAYABLE_SIZE) \
			or target_texture == null \
			or target_texture.get_size() != Vector2(FIRST_PLAYABLE_SIZE):
		_capture_abort("renderer target did not establish exact 1920x1080 before writes")
		_cleanup()
		quit(2)
		return

	app = load("res://ui/main.tscn").instantiate() as Control
	app.prototype_fixture_mode = true
	target.add_child(app)
	app.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	app.position = Vector2.ZERO
	app.size = Vector2(FIRST_PLAYABLE_SIZE)
	await settle()
	var initial_context: ZUIContext = null
	if app.screen is ZScreen:
		initial_context = (app.screen as ZScreen).app
	check(app.prototype_fixture_mode and initial_context != null
			and initial_context.has_fixture_provider(),
		"visual evidence uses an explicit fixture provider")
	check(app.size == Vector2(FIRST_PLAYABLE_SIZE),
		"UI logical root size is exact 1920x1080")
	check(app.get_viewport_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"UI logical root viewport is exact 1920x1080")
	check(app.get_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"UI logical root visible rect is exact 1920x1080")
	if initial_context == null or not initial_context.has_fixture_provider():
		_capture_abort("explicit fixture provider was not established")
		_cleanup()
		quit(2)
		return

	for specification in CASES:
		await _exercise_case(specification)
		if capture_aborted:
			break

	if DisplayServer.get_name() == "headless":
		print("HEADLESS_EVIDENCE_CAPTURE_SKIPPED dummy renderer has no native framebuffer")
	elif not capture_aborted:
		_save_contact_sheet()
	_cleanup()
	await settle(3)
	print("FEATURE_GATES_8_9_VISUAL_RESULT checks=", checks,
		" failures=", failures, " size=1920x1080 frames=", frames.size())
	quit(0 if failures == 0 else 1)


func _native_output_preflight() -> bool:
	# Fullscreen may be supplied by the launcher on a 1920x1080 display. Never
	# relabel a clamped physical window by assigning a logical root size.
	await settle()
	if not exact_cli_resolution or not _native_window_is_exact():
		push_error("FEATURE_GATES_8_9_VISUAL: physical window/root preflight rejected before UI mount")
		return false
	await RenderingServer.frame_post_draw
	var texture := root.get_texture()
	if texture == null or texture.get_size() != Vector2(FIRST_PLAYABLE_SIZE):
		push_error("FEATURE_GATES_8_9_VISUAL: physical root texture rejected before UI mount")
		return false
	var image := texture.get_image()
	if image == null or image.get_size() != FIRST_PLAYABLE_SIZE or not _native_window_is_exact():
		push_error("FEATURE_GATES_8_9_VISUAL: physical root readback rejected before UI mount")
		return false
	print("EXACT_1920_NATIVE_PREFLIGHT physical_window=1920x1080 root=1920x1080",
		" root_texture=1920x1080 raw_root_image=1920x1080 ui_mounted=false")
	return true


func _native_window_is_exact() -> bool:
	return DisplayServer.window_get_size(root.get_window_id()) == FIRST_PLAYABLE_SIZE \
		and root.size == FIRST_PLAYABLE_SIZE \
		and root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE)


func _exercise_case(specification: Dictionary) -> void:
	var action_id: StringName = specification["id"]
	var route: String = str(specification["route"])
	var path: String = str(specification["path"])
	var file_stem: String = str(specification["file"])
	app.navigate(route, false)
	await settle()
	var screen := app.screen as ZScreen
	var control := screen.get_node_or_null(path) as Control if screen != null else null
	check(screen != null and app.current_route == route,
		"authored route mounts through CommonUI: " + route)
	check(control != null and control.is_visible_in_tree(),
		"real gated control is visible: " + String(action_id))
	check(control is BaseButton and not (control as BaseButton).disabled,
		"real gated control is enabled for ordinary activation: " + String(action_id))
	if capture_aborted:
		return
	check(control.get_meta("z_feature_action", &"") == action_id,
		"control metadata names typed action: " + String(action_id))
	check(control.get_meta("z_feature_status", &"") == &"prototype",
		"fixture control is explicitly prototype-only: " + String(action_id))
	check(control.get_meta("z_feature_status_label", &"") == "PROTOTYPE ONLY"
			and control.tooltip_text.contains("PROTOTYPE ONLY"),
		"control exposes visible prototype wording: " + String(action_id))
	control.grab_focus()
	await settle(2)
	var focus := target.gui_get_focus_owner() as Control
	check(is_instance_valid(focus) and screen.is_ancestor_of(focus)
			and focus == control,
		"CommonUI focus remains on the authored gated control: " + String(action_id))
	# Any prior toast is cleared so only the actual activation can satisfy the
	# disclosure assertion. No notification or pressed callback is injected.
	app.toast_timer.stop()
	app.toast_label.hide()
	app.toast_label.text = ""
	if not _assert_render_contract(String(action_id) + " before input"):
		return
	var state_before := _state_signature()
	var route_before: String = str(app.current_route)
	var modal_before: Variant = app.modal
	var pressed_count := {"value": 0}
	var pressed_observer := func() -> void: pressed_count["value"] += 1
	if control is BaseButton:
		(control as BaseButton).pressed.connect(pressed_observer)
	_activate_real_input(control, StringName(specification["input"]))
	await settle()
	if control is BaseButton and (control as BaseButton).pressed.is_connected(pressed_observer):
		(control as BaseButton).pressed.disconnect(pressed_observer)
	var toast: Label = app.toast_label
	var expected_name: String = str(ZUIFeatureGateView.ACTION_LABELS.get(String(action_id), ""))
	check(pressed_count["value"] == 1,
		"real input activates the existing gated control once: " + String(action_id))
	check(app.current_route == route_before,
		"prototype input does not navigate: " + String(action_id))
	check(app.modal == modal_before,
		"prototype input does not open a modal: " + String(action_id))
	check(_state_signature() == state_before,
		"prototype input does not mutate fixture state: " + String(action_id))
	check(target.gui_get_focus_owner() == control,
		"ordinary activation preserves the authored focus owner: " + String(action_id))
	check(toast != null and toast.visible
			and toast.text.contains("PROTOTYPE ONLY")
			and toast.text.contains(expected_name),
		"real callback toast visibly identifies prototype gate: " + String(action_id))
	print("FEATURE_GATE_VISIBLE action=", action_id,
		" status=PROTOTYPE ONLY input=", specification["input"],
		" route=", route, " control=", path,
		" pressed=", pressed_count["value"], " state_unchanged=", _state_signature() == state_before,
		" modal_unchanged=", app.modal == modal_before,
		" toast=", toast.text if toast != null else "")
	if capture_aborted or DisplayServer.get_name() == "headless":
		return
	var image := await _capture_frame(String(action_id))
	if image == null or capture_aborted:
		return
	frames.append(image)
	var relative_path := capture_dir.path_join(
		"feature_gate_%s_1920x1080.png" % file_stem)
	_write_exact_png(image, relative_path, String(action_id))


func _activate_real_input(control: Control, modality: StringName) -> void:
	if modality == &"mouse_primary":
		var position := control.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = position
		motion.global_position = position
		target.push_input(motion)
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.position = position
		mouse.global_position = position
		mouse.pressed = true
		target.push_input(mouse)
		mouse = mouse.duplicate()
		mouse.pressed = false
		target.push_input(mouse)
		return
	# Physical controller acceptance belongs to Task 8.13. Enter and primary
	# pointer events here exercise the existing BaseButton input path.
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.physical_keycode = KEY_ENTER
	key.pressed = true
	target.push_input(key)
	key = key.duplicate()
	key.pressed = false
	target.push_input(key)


func _state_signature() -> String:
	return JSON.stringify(app.fixture_state_for_test())


func _capture_frame(label: String) -> Image:
	if not _assert_render_contract(label + " before draw"):
		return null
	await RenderingServer.frame_post_draw
	if not _assert_render_contract(label + " after draw"):
		return null
	var texture := target.get_texture()
	if texture == null:
		_capture_abort("missing exact renderer target texture for " + label)
		return null
	var image := texture.get_image()
	if image == null:
		_capture_abort("missing exact renderer target image for " + label)
		return null
	if not _assert_render_contract(label + " captured", image):
		return null
	return image


func _assert_render_contract(label: String, image: Image = null) -> bool:
	var valid := true
	if DisplayServer.get_name() != "headless":
		var physical_ok := _native_window_is_exact()
		check(physical_ok, label + " physical window and root remain exact 1920x1080")
		valid = physical_ok and valid
	var cli_ok := _has_exact_cli_resolution()
	check(cli_ok, label + " CLI remains explicitly --resolution 1920x1080")
	valid = cli_ok and valid
	var orchestration_ok := root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
	check(orchestration_ok, label + " orchestration root visible rect is exact 1920x1080")
	valid = orchestration_ok and valid
	var target_size_ok := target != null and target.size == FIRST_PLAYABLE_SIZE
	check(target_size_ok, label + " render-target size is exact 1920x1080")
	valid = target_size_ok and valid
	var target_rect_ok := target != null \
			and target.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
	check(target_rect_ok, label + " render-target visible rect is exact 1920x1080")
	valid = target_rect_ok and valid
	var texture_ok := target != null and target.get_texture() != null \
			and target.get_texture().get_size() == Vector2(FIRST_PLAYABLE_SIZE)
	check(texture_ok, label + " render-target texture is exact 1920x1080")
	valid = texture_ok and valid
	var root_size_ok := app != null and app.size == Vector2(FIRST_PLAYABLE_SIZE)
	check(root_size_ok, label + " UI logical root size is exact 1920x1080")
	valid = root_size_ok and valid
	var target_owner_ok := app != null and app.get_viewport() == target
	check(target_owner_ok, label + " authored UI belongs to the dedicated render target")
	valid = target_owner_ok and valid
	var viewport_ok := app != null \
			and app.get_viewport_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
	check(viewport_ok, label + " UI logical viewport is exact 1920x1080")
	valid = viewport_ok and valid
	var visible_ok: bool = app != null \
			and app.get_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
	check(visible_ok, label + " UI logical visible rect is exact 1920x1080")
	valid = visible_ok and valid
	var screen := app.screen as Control if app != null else null
	var screen_ok := screen != null and screen.get_rect().size == Vector2(FIRST_PLAYABLE_SIZE) \
			and screen.get_viewport_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
	check(screen_ok, label + " authored screen and visible rect are exact 1920x1080")
	valid = screen_ok and valid
	if image != null:
		var image_ok := image.get_size() == FIRST_PLAYABLE_SIZE
		check(image_ok, label + " captured Image is exact 1920x1080")
		valid = image_ok and valid
	if not valid:
		_capture_abort("exact 1920x1080 render contract failed: " + label)
	return valid


func _write_exact_png(image: Image, relative_path: String, label: String) -> bool:
	# All pre-write checks happen before directory creation or a file write.
	var exact_frame := image != null and image.get_size() == FIRST_PLAYABLE_SIZE
	check(exact_frame, label + " raw Image is exact 1920x1080 before encoding")
	if not exact_frame:
		_capture_abort("missing or nonexact Image before write: " + label)
		return false
	if capture_aborted or not _assert_render_contract(label + " before path creation"):
		return false
	check(image.get_size() == FIRST_PLAYABLE_SIZE,
		label + " raw Image remains exact 1920x1080 before path creation")
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		_capture_abort("nonexact Image before path creation: " + label)
		return false
	var absolute := ProjectSettings.globalize_path(relative_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var directory_ok := directory_error == OK or directory_error == ERR_ALREADY_EXISTS
	check(directory_ok, label + " evidence directory exists")
	if not directory_ok:
		_capture_abort("evidence directory creation failed: " + label)
		return false
	if not _assert_render_contract(label + " immediately before file write"):
		return false
	check(image.get_size() == FIRST_PLAYABLE_SIZE,
		label + " raw Image remains exact 1920x1080 immediately before file write")
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		_capture_abort("nonexact Image immediately before file write: " + label)
		return false
	var save_error := image.save_png(absolute)
	check(save_error == OK, label + " exact PNG write succeeds")
	if save_error != OK:
		_capture_abort("exact PNG write failed: " + label)
		return false
	if not _assert_render_contract(label + " immediately after file write", image):
		return false
	var encoded := image.save_png_to_buffer()
	var encoded_ok := not encoded.is_empty()
	check(encoded_ok, label + " PNG encoding buffer is non-empty")
	if not encoded_ok:
		_capture_abort("PNG encoding failed after write: " + label)
		return false
	var decoded_buffer := Image.new()
	var decode_buffer_error := decoded_buffer.load_png_from_buffer(encoded)
	var decoded_buffer_ok := decode_buffer_error == OK \
			and decoded_buffer.get_size() == FIRST_PLAYABLE_SIZE
	check(decoded_buffer_ok,
		label + " decoded PNG buffer is exact 1920x1080 after write")
	if not decoded_buffer_ok:
		_capture_abort("decoded PNG buffer was not exact after write: " + label)
		return false
	var decoded_file := Image.new()
	var decode_file_error := decoded_file.load(absolute)
	var decoded_file_ok := decode_file_error == OK \
			and decoded_file.get_size() == FIRST_PLAYABLE_SIZE
	check(decoded_file_ok,
		label + " decoded PNG file is exact 1920x1080 immediately after write")
	if not decoded_file_ok:
		_capture_abort("decoded PNG file was not exact after write: " + label)
		return false
	if not _assert_render_contract(label + " decoded file verified", decoded_file):
		return false
	check(decoded_file.get_data() == image.get_data(),
		label + " PNG preserves the raw Image pixels without resampling")
	if capture_aborted:
		return false
	print("EXACT_1920_PNG_VERIFIED action=", label,
		" cli=1920x1080 root=1920x1080 ui=1920x1080 target=1920x1080",
		" image=1920x1080 decoded_png=1920x1080 raw_pixels_preserved=true")
	return true


func _save_contact_sheet() -> void:
	check(frames.size() == CASES.size(),
		"contact sheet has one exact source frame per gated action")
	if frames.size() != CASES.size():
		_capture_abort("contact sheet source frame count mismatch")
		return
	var sheet := Image.create(FIRST_PLAYABLE_SIZE.x, FIRST_PLAYABLE_SIZE.y,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Color("0a0b0a"))
	for index in range(frames.size()):
		var source := frames[index]
		var specification: Dictionary = CASES[index]
		var upper: Rect2i = specification["upper"]
		var lower: Rect2i = specification["lower"]
		check(source.get_size() == FIRST_PLAYABLE_SIZE,
			"contact source remains exact 1920x1080: " + str(specification["id"]))
		check(upper.size == CONTACT_CROP_SIZE and lower.size == CONTACT_CROP_SIZE
				and upper.position.x >= 0 and upper.position.y >= 0
				and upper.end.x <= FIRST_PLAYABLE_SIZE.x
				and upper.end.y <= FIRST_PLAYABLE_SIZE.y
				and lower.position.x >= 0 and lower.position.y >= 0
				and lower.end.x <= FIRST_PLAYABLE_SIZE.x
				and lower.end.y <= FIRST_PLAYABLE_SIZE.y,
			"contact crop stays inside exact source: " + str(specification["id"]))
		if capture_aborted:
			return
		var position := Vector2i(0, index * CONTACT_CROP_SIZE.y)
		# The sheet is a 1:1 crop composition from each exact source Image. It
		# deliberately performs no resize, upscale, downscale, or resampling.
		# Five rows pair authored controls/details with their complete gate toast.
		sheet.blit_rect(source, upper, position)
		sheet.blit_rect(source, lower,
			position + Vector2i(CONTACT_CROP_SIZE.x, 0))
	check(sheet.get_size() == FIRST_PLAYABLE_SIZE,
		"contact sheet Image is exact 1920x1080 before write")
	if sheet.get_size() != FIRST_PLAYABLE_SIZE:
		_capture_abort("contact sheet Image size mismatch")
		return
	_write_exact_png(sheet,
		capture_dir.path_join("feature_gates_contact_sheet_1920x1080.png"),
		"contact sheet")


func _capture_abort(reason: String) -> void:
	if not capture_aborted:
		failures += 1
	capture_aborted = true
	push_error("FEATURE_GATES_8_9_VISUAL_ABORT: " + reason)


func _cleanup() -> void:
	if is_instance_valid(target):
		target.queue_free()
	target = null
	app = null
