extends Node2D
## View/inspection controls only. The saved sector scene owns every tile/prop.
## No source-image rebuilding, terrain generation, gameplay authority or save I/O.
const EXACT := Vector2i(1920,1080)
const DETAIL_ZOOM := Vector2(3,3)
@onready var sector: Node2D = $FreightSector
@onready var camera: Camera2D = $Camera2D
@onready var walker: CharacterBody2D = $FreightSector/WorldProps/ReviewWalker
var walking := false
var dragging := false

func _ready() -> void:
	$HUD/Top/Reset.pressed.connect(reset_camera)
	$HUD/Top/Inspection.pressed.connect(inspect_annex)
	$HUD/Top/Walk.pressed.connect(toggle_walk)
	# The level is already present in the PackedScene before this script runs.
	# Camera and controls must never reconstruct it or overwrite editor changes.
	refresh()

func bounds() -> Rect2:
	return sector.get_meta("authored_world_bounds")

func frame_at(at: Vector2) -> void:
	var half := Vector2(EXACT)/DETAIL_ZOOM/2.0
	var area := bounds()
	camera.position = at.clamp(area.position+half,area.end-half).round()
	camera.force_update_scroll()

func reset_camera() -> void:
	set_walking(false)
	frame_at($FreightSector/Anchors/EntranceCamera.position)

func inspect_annex() -> void:
	set_walking(false)
	frame_at($FreightSector/Anchors/InspectionCamera.position)

func toggle_walk() -> void:
	set_walking(not walking)

func set_walking(value: bool) -> void:
	walking=value
	walker.enabled=value
	walker.animate=value
	walker.visible=value
	refresh()

func refresh() -> void:
	$HUD/Top/Walk.text="P  CAMERA" if walking else "P  WALK"
	$HUD/Bottom/Help.text="WASD: %s   |   Home: freight entrance   End: inspection annex   |   48px source tile = 48 screen pixels   |   EDITABLE ENVIRONMENT, NOT LIVE RAID" % ("walk (Shift: faster)" if walking else "pan / drag")

func _process(delta: float) -> void:
	if walking:
		frame_at(walker.position)
	elif not dragging:
		var motion := Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
		if motion != Vector2.ZERO:
			frame_at(camera.position+motion.normalized()*delta*180.0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_P: toggle_walk()
			KEY_HOME: reset_camera()
			KEY_END: inspect_annex()
			_: return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and not walking:
		dragging=event.pressed
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and dragging and not walking:
		frame_at(camera.position-event.relative/DETAIL_ZOOM)
		get_viewport().set_input_as_handled()
