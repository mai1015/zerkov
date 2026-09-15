extends SceneTree
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
const Scene = preload("res://game/presentation/map_studies/map_studies.tscn")
const EXACT := Vector2i(1920,1080)
var checks:int=0
var failures:int=0
var output:String=""

func _initialize() -> void:
	call_deferred("run")

func check(value:bool,label:String) -> void:
	checks+=1
	if not value:failures+=1;push_error("MAP_STUDY_ASSERTION: "+label)

func frames(count:int=3) -> void:
	for i:int in range(count):await process_frame
	await RenderingServer.frame_post_draw

func click(at:Vector2) -> void:
	var move:=InputEventMouseMotion.new();move.position=at;move.global_position=at;Input.parse_input_event(move)
	for pressed:bool in [true,false]:
		var event:=InputEventMouseButton.new();event.position=at;event.global_position=at;event.button_index=MOUSE_BUTTON_LEFT;event.pressed=pressed;Input.parse_input_event(event);await process_frame
	await frames()

func physical_key(code:int) -> void:
	for pressed:bool in [true,false]:
		var event:=InputEventKey.new();event.physical_keycode=code;event.keycode=code;event.pressed=pressed;Input.parse_input_event(event);await process_frame
	await frames()

func capture(view:Control,name:String) -> void:
	view.get_viewport().gui_release_focus()
	var move:=InputEventMouseMotion.new();move.position=Vector2(1880,995);move.global_position=move.position;Input.parse_input_event(move)
	await frames(4)
	var image:=root.get_texture().get_image()
	if not Exact1080CaptureGuard.accepts(root, root, image):
		check(false,"physical capture guard")
		return
	check(image.save_png(output.path_join(name))==OK,"native PNG saved "+name)

func run() -> void:
	for arg:String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):output=arg.trim_prefix("--output=")
	if output.is_empty() or DisplayServer.get_name()=="headless":
		print("MAP_STUDY_BLOCKED: graphical renderer and explicit output required");quit(2);return
	root.borderless=true;root.size=EXACT
	await process_frame
	check(root.size==EXACT,"exact physical root")
	DirAccess.make_dir_recursive_absolute(output)
	var view=Scene.instantiate();root.add_child(view);await frames()
	check(view.maps.size()==2,"two authored environments")
	check(view.surface.size==Vector2i(640,360),"locked world surface")
	check(view.camera.zoom==Vector2.ONE,"source-pixel camera")
	check(view.world.active_id=="northline","depot default")
	check(view.world.get_node("AuthoredLayoutCollision").get_child_count()>40,"native authored collider shapes")
	await click(Vector2(1700,40));check(view.world.active_id=="mercury","actual mouse map switch")
	await click(Vector2(397,110));check(view.point_index==1,"actual sector button")
	await click(Vector2(1770,1045));check(view.tactical,"route-study toggle")
	await click(Vector2(1770,1045));check(not view.tactical,"route-study toggle off")
	root.gui_release_focus();await physical_key(KEY_1);check(view.world.active_id=="northline","keyboard map switch")
	await physical_key(KEY_E);check(view.point_index==1,"keyboard sector")
	view.pan(Vector2(-10000,-10000));check(view.camera.position==Vector2(320,180),"camera minimum clamp")
	view.pan(Vector2(10000,10000));check(view.camera.position==Vector2(352,268),"camera maximum clamp")
	for map_i:int in range(2):
		view.select_map(map_i);await frames()
		for i:int in range(3):
			view.select_point(i);await frames()
			check(view.world.props_root.get_child_count()>=40,"native prop objects, not a background image")
			var name:String=str(view.maps[map_i]["id"])+"-"+str(view.maps[map_i]["camera_points"][i]["id"])+"-1080.png"
			await capture(view,name)
	view.select_map(0);view.select_point(0);view.toggle_tactical();await frames()
	check(view.world.tactical,"tactical geometry enabled")
	await capture(view,"northline-route-study-1080.png")
	# Prove repeated map replacement does not retain old prop roots.
	for i:int in range(8):view.select_map(i%2);await frames(1)
	check(view.world.get_child_count()<50,"bounded map replacement children")
	view.queue_free();await frames(2)
	print("MAP_STUDY_NATIVE_RESULT checks=%d failures=%d maps=2 captures=7 output=1920x1080 world=640x360 scale=3" % [checks,failures])
	quit(0 if failures==0 else 1)
