@tool
class_name ZTopChrome
extends Panel
## One resource header: explicit values and badges, shared across breakpoints.
signal menu_requested
signal world_back_requested

@export_enum("bunker", "build", "crafting", "session") var variant := "bunker":
	set(value):
		variant = value
		_sync()
@export var title := "THE BUNKER":
	set(value):
		title = value
		_sync()
@export var level := "LVL 3":
	set(value):
		level = value
		_sync()
@export var world_status := "■  WORLD OPEN · INVITE ONLY · 2 / 4":
	set(value):
		world_status = value
		_sync()
@export var money := "$ 125,000":
	set(value):
		money = value
		_sync()
var _authored: Dictionary = {}
## MenuLabel is a grandchild, so the authored-rect sweep below never sees it.
## Compact rewrites its box, and desktop has to be able to put it back.
var _authored_menu_label := Rect2()
var _compact := false

func _ready() -> void:
	for node in get_children():
		if node is Control: _authored[node.name] = Rect2(node.position, node.size)
	_authored_menu_label = Rect2($MenuRim/MenuLabel.position, $MenuRim/MenuLabel.size)
	ZThemeAdapter.apply_controls(self)
	_sync()
	if not Engine.is_editor_hint():
		$MenuButton.triggered.connect(func(): menu_requested.emit())
		$WorldBadge/WorldBack.triggered.connect(func(): world_back_requested.emit())

func _sync() -> void:
	if not is_node_ready(): return
	$Title.text = title
	$Meta.text = level
	$Money.text = money
	$WorldBadge/WorldStatus.text = world_status
	$BuildBadge.visible = variant == "build" and not _compact
	$WorldBadge.visible = variant == "session" and not _compact
	for key in ["Water", "WaterStatus", "Crafting", "CraftingCount"]:
		get_node(NodePath(key)).visible = variant != "session" and not _compact
	if not _compact:
		_rect("Power", Rect2(1410 if variant == "session" else 1200, 20, 120, 16))
		_rect("Stash", Rect2(1536 if variant == "session" else 1418, 20, 126 if variant == "session" else 130, 16))
		_rect("Meta", Rect2(350 if variant == "session" else 332, 19, 150, 18))

func layout_for(view: Vector2) -> void:
	_compact = view.x < 1920 or view.y < 1080
	custom_minimum_size.x = 0
	size = Vector2(view.x, 56)
	for key in _authored: _rect(str(key), _authored[key])
	$Divider.visible = not _compact
	_sync()
	# One dismiss-label contract across every shell: "ESC · <VERB>", single
	# spaces either side of the separator. Only the box geometry reflows.
	$MenuRim/MenuLabel.text = "ESC · MENU"
	if _compact:
		_rect("Logo", Rect2(16, 18, 101, 20))
		_rect("Title", Rect2(136, 17, 188, 22))
		$Title.clip_text = true
		_rect("Meta", Rect2(332, 19, 80, 18))
		_rect("Power", Rect2(view.x - 472, 20, 120, 20))
		_rect("Stash", Rect2(view.x - 352, 20, 140, 20))
		_rect("Money", Rect2(view.x - 224, 18, 112, 22))
		_rect("MenuRim", Rect2(view.x - 104, 12, 88, 32))
		_rect("MenuButton", Rect2(view.x - 104, 12, 88, 32))
		$MenuRim/MenuLabel.position = Vector2.ZERO
		$MenuRim/MenuLabel.size = Vector2(88, 32)
	else:
		$MenuRim/MenuLabel.position = _authored_menu_label.position
		$MenuRim/MenuLabel.size = _authored_menu_label.size

func get_menu_action() -> CommonButton:
	return $MenuButton

func get_world_action() -> CommonButton:
	return $WorldBadge/WorldBack

func _rect(key: String, rect: Rect2) -> void:
	var node: Control = get_node(NodePath(key))
	node.position = rect.position
	node.size = rect.size
