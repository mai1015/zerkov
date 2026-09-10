extends CommonActivatableScreen
## Developer route catalog. Its popup context suspends every active lower layer.
signal selected(route: String)
signal dismissed
var current_route := ""
var lower_contexts: Array[CommonUIContextHandle] = []

func _init() -> void:
	screen_context = &"ui/catalog"
	context_priority = CommonUIDefaults.PRIORITY_POPUP
	suspends_lower_contexts = true
	handles_back = false

func _ready() -> void:
	theme = ZKit.make_theme()
	ZThemeAdapter.apply_controls(self)
	var buttons: Array[Control] = []
	for route in ZRouteCatalog.ROUTES:
		var button: ZerkovButton = preload("res://ui/components/controls/zerkov_button.tscn").instantiate()
		button.text = ZRouteCatalog.ROUTES[route][0]
		button.custom_minimum_size = Vector2(0, 48)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.variant = "primary" if route == current_route else "secondary"
		button.triggered.connect(func(): selected.emit(route))
		$Panel/ScreenCatalog/Entries.add_child(button)
		buttons.append(button)
		if route == current_route: default_focus = get_path_to(button)
	for i in range(buttons.size()):
		buttons[i].focus_next = buttons[i].get_path_to(buttons[(i + 1) % buttons.size()])
		buttons[i].focus_previous = buttons[i].get_path_to(buttons[posmod(i - 1, buttons.size())])
	if default_focus.is_empty(): default_focus = get_path_to(buttons[0])
	resize_to_view(get_viewport_rect().size)

func resize_to_view(view: Vector2) -> void:
	if not is_node_ready(): return
	var extent := Vector2(minf(1320, view.x - 48), minf(844, view.y - 48))
	$Panel.position = (view - extent) / 2
	$Panel.size = extent
	$Panel/ScreenCatalog.size = Vector2(extent.x - 48, extent.y - 180)
	$Panel/ScreenCatalog/Entries.columns = maxi(2, int((extent.x - 64) / 340))
	$Panel/Footer.position.y = extent.y - 48
	$Panel/Footer.size.x = extent.x - 64

func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
	return lower_contexts.duplicate()

func _on_activated() -> void:
	register_action(CommonUIDefaults.BACK, _back)

func _back(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED: return CommonUIRuntime.ROUTE_UNHANDLED
	dismissed.emit()
	return CommonUIRuntime.ROUTE_HANDLED
