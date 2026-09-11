extends SceneTree
## Every catalog route must reflow repeatedly at the exact first-playable canvas
## without replacing its screen or authored controls, accumulating layout hosts,
## or retaining a cropped texture.
const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)

var app: Control
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("UI_REFLOW: " + message)

func settle() -> void:
	for i in range(12): await process_frame

func resize_to(dimensions: Vector2i, mode: String) -> void:
	app.ui_layout_mode = mode
	root.size = dimensions
	app._sync_window_scale()
	await settle()
	app.screen.reflow(root.get_visible_rect().size)
	await settle()

func run() -> void:
	root.size = FIRST_PLAYABLE_SIZE
	app = load("res://ui/main.tscn").instantiate()
	app.name = "ReflowHost"
	root.add_child(app)
	app.qa_mode = true
	await settle()
	for route in ZRouteCatalog.ROUTES:
		await resize_to(FIRST_PLAYABLE_SIZE, "desktop")
		app.navigate(route, false)
		await settle()
		var screen: Control = app.screen
		var authored: Array = screen.find_children("*", "Control", true, false)
		# Dynamic slots/lists may legitimately change; only saved scene nodes are
		# part of the retained authored contract.
		authored = authored.filter(func(node): return node.owner != null)
		var textures := {}
		for node in authored:
			if node is TextureRect: textures[node] = node.texture
		var authored_count := -1
		for cycle in range(3):
			await resize_to(FIRST_PLAYABLE_SIZE, "desktop")
			var label := "%s cycle %d at 1920x1080" % [route, cycle]
			check(app.screen == screen, label + " retains screen")
			var retained := true
			for node in authored:
				if not is_instance_valid(node) or not screen.is_ancestor_of(node): retained = false
			check(retained, label + " retains authored controls")
			var count := screen.find_children("*", "Control", true, false).size()
			if cycle == 0: authored_count = count
			else: check(count == authored_count, label + " does not accumulate controls")
			var restored := true
			for node in textures:
				if is_instance_valid(node) and node.texture != textures[node]: restored = false
			check(restored, label + " restores desktop textures")
	print("UI_REFLOW_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
