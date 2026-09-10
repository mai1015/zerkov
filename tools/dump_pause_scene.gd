extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1920, 1080)
	var app: Control = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	app.navigate("pause", false)
	await process_frame
	await process_frame
	# Authored scenes must store serializable StyleBoxFlat resources. The
	# runtime helpers wrap these in PixelStyle for compact rendering, but that
	# adapter's transient source is intentionally not packed by Godot.
	app.screen.theme = null
	_unwrap_styles(app.screen)
	_set_owner(app.screen, app.screen)
	var packed := PackedScene.new()
	var error := packed.pack(app.screen)
	print("PACK_ERROR ", error)
	print("CHILDREN ", app.screen.find_children("*", "", true, false).size())
	print("SAVE_ERROR ", ResourceSaver.save(packed, "res://tools/generated_pause.tscn"))
	quit()

func _set_owner(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner(child, owner)

func _unwrap_styles(node: Node) -> void:
	if node is Control:
		var control: Control = node as Control
		for style_name in ["panel", "normal", "hover", "pressed", "focus", "disabled"]:
			if not control.has_theme_stylebox_override(style_name):
				continue
			var style: StyleBox = control.get_theme_stylebox(style_name)
			var source: Variant = style.get("source") if style != null else null
			if source is StyleBoxFlat:
				control.add_theme_stylebox_override(style_name, source)
	for child in node.get_children():
		_unwrap_styles(child)
