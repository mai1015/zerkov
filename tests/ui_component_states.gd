extends SceneTree
## Native component-state capture and one-activation-per-input acceptance.
const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)

var app: Control
var gallery: Control
var checks := 0
var failures := 0
var output := "/tmp/zerkov-component-states"

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("UI_COMPONENT_STATES: " + message)

func settle() -> void:
	for i in range(6): await process_frame

func capture(label: String) -> void:
	await settle()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var rendered := root.get_texture().get_image()
		var root_exact := root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
		if not root_exact:
			check(false, "exact 1920x1080 framebuffer before capture " + label)
			push_error("UI_COMPONENT_STATES: nonexact framebuffer rejected before write")
			quit(2)
			return
		var exact_frame := rendered != null \
			and rendered.get_size() == FIRST_PLAYABLE_SIZE
		check(exact_frame, "exact 1920x1080 framebuffer before capture " + label)
		if not exact_frame:
			push_error("UI_COMPONENT_STATES: nonexact framebuffer rejected before write")
			quit(2)
			return
		check(rendered.save_png(output.path_join(label + ".png")) == OK, "capture " + label)

func mouse(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(event)
	await settle()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): output = arg.trim_prefix("--capture-dir=")
	root.size = FIRST_PLAYABLE_SIZE
	await process_frame
	if DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(true)
		var preflight := root.get_texture().get_image()
		var root_exact := root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
		if not root_exact:
			check(false, "exact 1920x1080 framebuffer before paths or component setup")
			push_error("UI_COMPONENT_STATES: nonexact framebuffer rejected before paths or writes")
			quit(2)
			return
		var exact_preflight := preflight != null and preflight.get_size() == FIRST_PLAYABLE_SIZE
		check(exact_preflight, "exact 1920x1080 framebuffer before paths or component setup")
		if not exact_preflight:
			push_error("UI_COMPONENT_STATES: nonexact framebuffer rejected before paths or writes")
			quit(2)
			return
		DirAccess.make_dir_recursive_absolute(output)
	app = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	app.qa_mode = true
	await settle()
	app.navigate("main_menu", false)
	await settle()
	app.screen.hide()
	for dimensions in [FIRST_PLAYABLE_SIZE]:
		app.ui_layout_mode = "desktop"
		root.size = FIRST_PLAYABLE_SIZE
		app._sync_window_scale()
		await settle()
		root.grab_focus()
		gallery = Control.new()
		gallery.size = Vector2(dimensions)
		gallery.theme = ZKit.make_theme()
		root.add_child(gallery)
		var backdrop := ColorRect.new()
		backdrop.color = ZKit.BG
		backdrop.size = gallery.size
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gallery.add_child(backdrop)
		var buttons: Array[Button] = []
		for variant in ["secondary", "primary", "flat", "destructive"]:
			var button: ZerkovButton = load("res://ui/components/controls/zerkov_button.tscn").instantiate()
			button.variant = variant
			button.text = variant.to_upper()
			button.position = Vector2(24 + buttons.size() * 220, 24)
			button.size = Vector2(200, 48)
			gallery.add_child(button)
			buttons.append(button)
		var card: ZMenuActionCard = load("res://ui/screens/frontflow/components/menu_action_card.tscn").instantiate()
		card.card_title = "CONTINUE"
		card.card_subtitle = "OAK'S BUNKER · Bunker LVL 3 · LVL 14"
		card.position = Vector2(24, 96)
		card.size.x = minf(800, dimensions.x - 48)
		gallery.add_child(card)
		var row: ZWorldRow = load("res://ui/screens/frontflow/components/world_row.tscn").instantiate()
		row.world = {"id": "oak", "name": "OAK'S BUNKER", "difficulty": "STANDARD", "bunker": "LVL 3", "character": "LVL 14", "playtime": "14 h", "last": "2 h ago"}
		row.position = Vector2(24, 200)
		gallery.add_child(row)
		row.layout_for(minf(1264, dimensions.x - 48), false)
		var empty: Control = load("res://ui/screens/frontflow/components/new_world_row.tscn").instantiate()
		empty.position = Vector2(24, 320)
		empty.size.x = row.size.x
		gallery.add_child(empty)
		var activations: Array[String] = []
		card.activated.connect(func(): activations.append("card"))
		row.activated.connect(func(id, _index): activations.append(str(id)))
		var prefix := str(dimensions.x) + "-"
		await capture(prefix + "default")
		var motion := InputEventMouseMotion.new()
		motion.position = card.position + Vector2(40, 30)
		motion.global_position = motion.position
		Input.warp_mouse(motion.position)
		Input.parse_input_event(motion)
		await capture(prefix + "hover")
		await mouse(motion.position, true)
		check(card.get_focus_target().get_draw_mode() == BaseButton.DRAW_PRESSED, prefix + "native pressed state")
		await capture(prefix + "pressed")
		if DisplayServer.get_name() != "headless":
			var rendered := root.get_texture().get_image()
			if rendered.get_size() != FIRST_PLAYABLE_SIZE:
				push_error("UI_COMPONENT_STATES: nonexact framebuffer rejected before pixel sampling")
				quit(2)
				return
			check(rendered.get_pixel(30, 100).r > ZKit.BG.r + 0.08, prefix + "pressed background is visibly rendered")
		await mouse(motion.position, false)
		check(activations == ["card"], prefix + "card click activates once: " + str(activations))
		row.selected = true
		card.active_accent = true
		card.get_focus_target().grab_focus()
		await capture(prefix + "selected-focus")
		await mouse(row.position + Vector2(40, 30), true)
		await mouse(row.position + Vector2(40, 30), false)
		check(activations == ["card", "oak"], prefix + "world click emits stable ID once: " + str(activations))
		row.world = {"id": "oak", "name": "RENAMED WORLD", "difficulty": "HARDCORE", "cloud": "pending"}
		card.disabled = true
		row.disabled = true
		check(card.get_focus_target().get_theme_stylebox("disabled").bg_color.a == 0.0, prefix + "disabled hit target does not obscure card content")
		for button in buttons: button.disabled = true
		await capture(prefix + "updated-disabled")
		await mouse(motion.position, true)
		await mouse(motion.position, false)
		check(activations.size() == 2, "disabled card does not activate")
		gallery.queue_free()
		await settle()
		app.screen.show()
		app.screen.app.confirm(
			"UI confirmation",
			"Shared modal with keyboard focus and an explicit cancel action.",
			func(): pass
		)
		await capture(prefix + "dialog")
		app._close_overlay(app.modal)
		await settle()
		app.screen.app.prompt("Rename world", "OAK'S BUNKER", func(_value): pass)
		await capture(prefix + "prompt")
		app._close_overlay(app.modal)
		await settle()
		app.screen.hide()
	print("UI_COMPONENT_STATES_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
