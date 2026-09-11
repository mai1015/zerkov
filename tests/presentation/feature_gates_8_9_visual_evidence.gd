extends SceneTree

## Task 8.9 visual evidence. Every case mounts an existing authored screen in
## an explicit fixture-provider session, focuses one real gated control, and
## shows that screen's CommonUI toast with the typed feature status. The native
## runner writes full-size source frames plus a contact sheet; it never creates
## a replacement screen or production fixture fallback.
##
## Run headless for source/visibility assertions:
## godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd
##
## Run natively for evidence:
## godot --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_visual_evidence.gd -- --capture-dir=res://docs/qa/feature_gates_8_9

const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)
const DEFAULT_CAPTURE_DIR := "res://docs/qa/feature_gates_8_9"
const CASES: Array[Dictionary] = [
	{"id": &"bunker", "route": "bunker", "path": "Stations/Row1/Hit", "file": "bunker"},
	{"id": &"crafting", "route": "crafting", "path": "DetailPanel/CraftNow", "file": "crafting"},
	{"id": &"friends", "route": "join_friend", "path": "FilterAll", "file": "friends"},
	{"id": &"insurance", "route": "summary_solo", "path": "Reinsure", "file": "insurance"},
	{"id": &"marketplace", "route": "inventory", "path": "InventoryContent/PostRaidBar/SellJunk", "file": "marketplace"},
]

var checks: int = 0
var failures: int = 0
var capture_dir: String = DEFAULT_CAPTURE_DIR
var frames: Array[Image] = []


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			capture_dir = argument.trim_prefix("--capture-dir=")
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("FEATURE_GATES_8_9_VISUAL: " + message)


func settle(frames_to_wait: int = 6) -> void:
	for _index in range(frames_to_wait):
		await process_frame


func run() -> void:
	root.size = FIRST_PLAYABLE_SIZE
	check(root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"visual evidence root is exact 1920x1080")
	if root.get_visible_rect().size != Vector2(FIRST_PLAYABLE_SIZE):
		quit(2)
		return

	var app := load("res://ui/main.tscn").instantiate() as Control
	app.prototype_fixture_mode = true
	root.add_child(app)
	await settle()
	var initial_context: ZUIContext = null
	if app.screen is ZScreen:
		initial_context = (app.screen as ZScreen).app
	check(app.prototype_fixture_mode and initial_context != null
			and initial_context.has_fixture_provider(),
		"visual evidence uses an explicit fixture provider")
	if initial_context == null or not initial_context.has_fixture_provider():
		quit(2)
		return

	for specification in CASES:
		await _exercise_case(app, specification)

	if DisplayServer.get_name() != "headless":
		_save_contact_sheet()
	else:
		print("HEADLESS_EVIDENCE_CAPTURE_SKIPPED dummy renderer has no native framebuffer")
	app.queue_free()
	await settle(3)
	print("FEATURE_GATES_8_9_VISUAL_RESULT checks=", checks,
		" failures=", failures, " size=1920x1080 frames=", frames.size())
	quit(0 if failures == 0 else 1)


func _exercise_case(app: Control, specification: Dictionary) -> void:
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
	if control == null or not control.is_visible_in_tree():
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
	var focus := root.get_viewport().gui_get_focus_owner() as Control
	check(is_instance_valid(focus) and screen.is_ancestor_of(focus),
		"CommonUI focus remains within authored route: " + String(action_id))
	screen.notify_feature_action(action_id)
	await process_frame
	var toast: Label = app.toast_label
	var expected_name: String = str(ZUIFeatureGateView.ACTION_LABELS.get(String(action_id), ""))
	check(toast != null and toast.visible
			and toast.text.contains("PROTOTYPE ONLY")
			and toast.text.contains(expected_name),
		"CommonUI toast visibly identifies prototype gate: " + String(action_id))
	print("FEATURE_GATE_VISIBLE action=", action_id,
		" status=PROTOTYPE ONLY route=", route,
		" control=", path,
		" toast=", toast.text if toast != null else "")
	if DisplayServer.get_name() == "headless":
		return
	var image := await _capture_frame()
	check(image != null and image.get_size() == FIRST_PLAYABLE_SIZE,
		"captured source frame is exact 1920x1080: " + String(action_id))
	if image == null:
		return
	frames.append(image)
	var absolute := ProjectSettings.globalize_path(
		capture_dir.path_join("feature_gate_%s_1920x1080.png" % file_stem))
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS,
		"evidence directory exists: " + String(action_id))
	check(image.save_png(absolute) == OK,
		"full-size evidence frame saves: " + String(action_id))


func _capture_frame() -> Image:
	await RenderingServer.frame_post_draw
	var texture := root.get_texture()
	if texture == null:
		return null
	var source := texture.get_image()
	if source == null:
		return null
	var image: Image = source.duplicate()
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		print("NATIVE_FRAMEBUFFER_SIZE=", image.get_size(),
			" logical=1920x1080")
		image.resize(FIRST_PLAYABLE_SIZE.x, FIRST_PLAYABLE_SIZE.y,
			Image.INTERPOLATE_NEAREST)
	return image


func _save_contact_sheet() -> void:
	check(frames.size() == CASES.size(),
		"contact sheet has one source frame per gated action")
	if frames.size() != CASES.size():
		return
	var sheet := Image.create(FIRST_PLAYABLE_SIZE.x, FIRST_PLAYABLE_SIZE.y,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Color("0a0b0a"))
	var tile_size := Vector2i(640, 360)
	var positions: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(640, 0), Vector2i(1280, 0),
		Vector2i(0, 360), Vector2i(640, 360),
	]
	for index in range(frames.size()):
		var thumb: Image = frames[index].duplicate()
		thumb.resize(tile_size.x, tile_size.y, Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(thumb, Rect2i(Vector2i.ZERO, tile_size), positions[index])
	var absolute := ProjectSettings.globalize_path(
		capture_dir.path_join("feature_gates_contact_sheet_1920x1080.png"))
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS,
		"contact-sheet directory exists")
	check(sheet.save_png(absolute) == OK,
		"labeled exact-1920 contact sheet saves")
