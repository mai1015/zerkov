extends RefCounted
## Native resource and presenter verification with the actual user-supplied PNGs.
## Not an integrated encounter, graphical capture, or full-character approval.

const State = preload("res://game/presentation/art/player_animation_state.gd")
const Presenter = preload("res://game/presentation/art/layered_player_presenter.gd")
var checks: int = 0
var failures: int = 0
var poses: int = 0


func expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		print("ART_ASSERTION_FAILED: " + label)


func run() -> Dictionary:
	var manifest_value: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://game/content/art/runtime_art.json"))
	var recipe_value: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://game/content/art/player_recipe.json"))
	expect(manifest_value is Dictionary and recipe_value is Dictionary, "actual manifests readable")
	if not manifest_value is Dictionary or not recipe_value is Dictionary:
		return _result()
	var manifest: Dictionary = manifest_value
	var recipe: Dictionary = recipe_value
	var textures: Dictionary = {}
	expect(recipe["sources"].size() == 20, "exact twenty player source files")
	for source: Dictionary in recipe["sources"]:
		var id: String = source["id"]
		var path: String = "res://assets/original/" + source["path"]
		expect(FileAccess.get_sha256(path) == source["sha256"], "actual source hash: " + id)
		var texture: Texture2D = load(path) as Texture2D
		expect(texture != null, "native PNG resource: " + id)
		if texture == null:
			continue
		textures[id] = texture
		expect(texture.get_width() == int(source["size"][0]) and texture.get_height() == int(source["size"][1]), "native dimensions: " + id)
		expect(not texture.get_image().has_mipmaps(), "no native mipmaps: " + id)
	var presenter := Presenter.new()
	presenter.position = Vector2(123, 456)
	expect(presenter.configure(manifest, textures, 1), "actual layered binding")
	expect(presenter.get_child_count() == 8, "actual fixed layer pool")
	var sample_tick: int = 0
	for clip_name: String in ["idle", "walk", "attack", "grenade", "death"]:
		var clip: Dictionary = manifest["clips"][clip_name]
		var count: int = int(clip["frame_count"])
		expect(count == (9 if clip_name == "death" else 6), "authored frame count: " + clip_name)
		for frame: int in range(count):
			for face_left: bool in [false, true]:
				sample_tick += 1
				var sample := {"generation": 1, "sequence": sample_tick, "tick": sample_tick, "state": clip_name, "frame": frame}
				expect(presenter.present(sample, face_left), "actual sampled pose")
				poses += 1
				for layer: int in range(4):
					var sprite := presenter.get_child(layer) as Sprite2D
					var id: String = clip["layers"][layer]
					var rect: Array = manifest["sources"][id]["regions"][frame]["rect"]
					expect(sprite.visible and sprite.texture == textures[id], "actual ordered layer")
					expect(sprite.region_rect == Rect2(rect[0], rect[1], rect[2], rect[3]), "actual region")
					expect(sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "native pixel filter")
					expect(sprite.scale.x == (-1.0 if face_left else 1.0), "actual facing mirror")
					expect(sprite.position == Vector2(clip["pivot"][0] if face_left else -clip["pivot"][0], -clip["pivot"][1]), "explicit foot pivot")
				expect(presenter.position == Vector2(123, 456), "presentation never moves root body")
	expect(poses == 66, "all thirty-three authored frames in both mirror states")
	var state := State.new()
	expect(state.configure(manifest["clips"], 1), "state accepts actual compiled clips")
	expect(state.consume({"generation": 1, "sequence": 1, "tick": 0, "kind": "death", "committed": true}), "actual death event")
	expect(state.advance_to(1000), "sample past actual death duration")
	expect(state.snapshot()["state"] == "death" and state.snapshot()["frame"] == 8, "nine-frame death terminal hold")
	expect(not manifest["clips"].has("hit"), "unprovided hit reaction remains unavailable")
	presenter.release()
	for child: Node in presenter.get_children():
		var sprite := child as Sprite2D
		expect(not sprite.visible and sprite.texture == null, "real texture references released")
	presenter.free()
	state.release()
	return _result()


func _result() -> Dictionary:
	print("ART_REAL_PLAYER_RESULT checks=%d failures=%d sources=20 poses=%d" % [checks, failures, poses])
	return {"checks": checks, "failures": failures}
