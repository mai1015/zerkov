extends RefCounted
## Called by the registered isolated driver. Synthetic pixels prove mechanics,
## not player-art approval, integrated gameplay, or a native visual review.

const State = preload("res://game/presentation/art/player_animation_state.gd")
const Presenter = preload("res://game/presentation/art/layered_player_presenter.gd")
var checks: int = 0
var failures: int = 0
var replay_digest: String = ""


func run() -> Dictionary:
	_test_state()
	_test_replay()
	_test_presenter()
	_test_compiled_resources()
	print("ART_MODULE_RESULT checks=%d failures=%d digest=%s" % [checks, failures, replay_digest])
	return {"checks": checks, "failures": failures, "digest": replay_digest}


func expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		print("ART_ASSERTION_FAILED: " + label)


func clips() -> Dictionary:
	var result: Dictionary = {}
	for name: String in ["idle", "walk", "attack", "grenade", "death"]:
		result[name] = {"frame_count": 9 if name == "death" else 6,
			"ticks_per_frame": 10 if name == "idle" else (5 if name == "attack" else 6),
			"loop": name == "idle" or name == "walk"}
	return result


func event(kind: String, sequence: int, tick: int, generation: int = 1) -> Dictionary:
	var result := {"generation": generation, "sequence": sequence, "tick": tick,
		"kind": kind, "committed": true}
	if kind == "locomotion":
		result["moving"] = true
	return result


func _test_state() -> void:
	var state := State.new()
	expect(state.snapshot().is_empty(), "unbound is unavailable")
	expect(not state.configure(clips(), 0), "reject zero generation")
	var data := clips()
	expect(state.configure(data, 1), "configure")
	data["idle"]["frame_count"] = 1
	expect(state.snapshot()["frame"] == 0, "initial idle")
	expect(state.advance_to(10), "advance")
	expect(state.snapshot()["frame"] == 1, "detached configuration")
	expect(state.snapshot().is_read_only(), "read-only publication")
	expect(state.consume(event("locomotion", 1, 10)), "start moving")
	expect(state.advance_to(16), "walk clock")
	expect(state.snapshot()["state"] == "walk" and state.snapshot()["frame"] == 1, "walk frame")
	var before := state.snapshot()
	var rejected: Array[Dictionary] = [event("locomotion", 1, 10), event("attack", 2, 17),
		event("attack", 2, 16, 2), event("hit", 2, 16), event("death", 2, -1)]
	for field: String in ["generation", "sequence", "tick"]:
		var bad := event("attack", 2, 16)
		bad[field] = float(bad[field])
		rejected.append(bad)
	for committed: Variant in [false, 1, "true"]:
		var bad := event("attack", 2, 16)
		bad["committed"] = committed
		rejected.append(bad)
	var extra := event("attack", 2, 16)
	extra["damage"] = 100
	rejected.append(extra)
	var invalid_move := event("locomotion", 2, 16)
	invalid_move["moving"] = 1
	rejected.append(invalid_move)
	for bad: Dictionary in rejected:
		expect(not state.consume(bad), "reject malformed/stale/uncommitted event")
		expect(state.snapshot() == before, "rejected event is mutation-free")
	expect(not state.advance_to(15), "clock cannot regress")
	expect(not state.advance_to(State.MAX_TICK + 1), "bounded clock")
	expect(state.consume(event("attack", 2, 16)), "valid event survives negative probes")
	expect(state.snapshot()["state"] == "attack", "attack entered")
	expect(state.advance_to(46), "action expiry")
	expect(state.snapshot()["state"] == "walk", "return to resolved locomotion")
	expect(state.consume(event("death", 3, 46)), "death accepted")
	expect(state.advance_to(1000), "death hold")
	expect(state.snapshot()["state"] == "death" and state.snapshot()["frame"] == 8, "death clamps")
	expect(state.snapshot()["terminal"], "terminal flag")
	expect(not state.consume(event("locomotion", 4, 1000)), "no resurrection by presentation event")
	before = state.snapshot()
	for field: String in ["frame_count", "ticks_per_frame"]:
		for invalid: Variant in [0, -1, true, 1.000001, "6", INF, NAN, 2147483648]:
			var candidate := clips()
			candidate["idle"][field] = invalid
			expect(not state.configure(candidate, 2), "reject malformed clip metadata")
			expect(state.snapshot() == before, "configuration failure is atomic")
	var missing := clips()
	missing.erase("death")
	expect(not state.configure(missing, 2), "required death clip")
	expect(not state.configure(clips(), 1), "generation cannot be reused")
	expect(state.configure(clips(), 2), "fresh generation")
	expect(not state.consume(event("attack", 1, 0, 1)), "old generation event")
	state.release()
	expect(state.snapshot().is_empty() and not state.advance_to(1), "release unavailable")
	expect(not state.consume(event("death", 1, 0, 2)), "late callback after release")
	expect(not state.configure(clips(), 2), "release retains generation floor")
	expect(state.configure(clips(), 3), "explicit replacement")


func _test_replay() -> void:
	var first := State.new()
	var second := State.new()
	expect(first.configure(clips(), 1) and second.configure(clips(), 1), "replay configure")
	var sequence: int = 0
	var trace := PackedStringArray()
	for tick: int in range(1000):
		expect(first.advance_to(tick) and second.advance_to(tick), "replay advance")
		var kind: String = ""
		if tick == 999:
			kind = "death"
		elif tick % 41 == 0:
			kind = "grenade"
		elif tick % 17 == 0:
			kind = "attack"
		elif tick % 8 == 0:
			kind = "locomotion"
		if not kind.is_empty():
			sequence += 1
			var input := event(kind, sequence, tick)
			if kind == "locomotion":
				input["moving"] = tick % 16 == 0
			expect(first.consume(input) and second.consume(input.duplicate(true)), "replay event")
		expect(first.snapshot() == second.snapshot(), "bit-equivalent replay publication")
		trace.append(JSON.stringify(first.snapshot()))
	replay_digest = "\n".join(trace).sha256_text()


func fixture_manifest() -> Dictionary:
	var source := {"filter": "nearest", "regions": [
		{"rect": [0, 0, 4, 4]}, {"rect": [4, 0, 4, 4]}]}
	return {"schema_version": 1, "sources": {"body": source, "arms": source.duplicate(true)},
		"clips": {"idle": {"layers": ["body", "arms"], "pivot": [2, 4], "frame_count": 2}}}


func _test_presenter() -> void:
	var image := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	var textures := {"body": texture, "arms": texture}
	var presenter := Presenter.new()
	presenter.position = Vector2(77, 99)
	var manifest := fixture_manifest()
	expect(presenter.configure(manifest, textures, 1), "presenter configure")
	manifest["clips"]["idle"]["pivot"] = [0, 0]
	expect(presenter.get_child_count() == 8, "fixed eight-layer pool")
	var sample := {"generation": 1, "sequence": 1, "tick": 1, "state": "idle", "frame": 1}
	expect(presenter.present(sample), "present frame")
	var body := presenter.get_child(0) as Sprite2D
	expect(body.region_rect == Rect2(4, 0, 4, 4), "explicit atlas coordinates")
	expect(body.position == Vector2(-2, -4), "detached pivot")
	expect(body.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "nearest is CanvasItem policy")
	expect((presenter.get_child(1) as Sprite2D).visible and not (presenter.get_child(2) as Sprite2D).visible, "only selected layers visible")
	expect(presenter.present(sample, true), "same publication supports facing presentation")
	expect(body.scale.x == -1 and body.position.x == 2, "mirror around foot anchor")
	expect(presenter.position == Vector2(77, 99), "no root transform mutation")
	for field: String in ["generation", "tick", "sequence", "frame"]:
		for invalid: Variant in [-1, 2147483648, 1.0, true]:
			var bad := sample.duplicate(true)
			bad[field] = invalid
			expect(not presenter.present(bad), "reject invalid publication")
			expect(body.region_rect == Rect2(4, 0, 4, 4), "rejection retains visible frame")
	for mode: String in ["linear", "layers", "count", "bounds", "pivot", "geometry", "schema"]:
		var bad := fixture_manifest()
		match mode:
			"linear": bad["sources"]["body"]["filter"] = "linear"
			"layers": bad["clips"]["idle"]["layers"] = ["body", "body"]
			"count": bad["clips"]["idle"]["frame_count"] = 1
			"bounds": bad["sources"]["body"]["regions"][1]["rect"] = [8, 0, 4, 4]
			"pivot": bad["clips"]["idle"]["pivot"] = [5, 4]
			"geometry": bad["sources"]["arms"]["regions"][0]["rect"] = [0, 0, 3, 4]
			"schema": bad["schema_version"] = 2
		expect(not presenter.configure(bad, textures, 2), "reject invalid binding: " + mode)
		expect(presenter.present(sample), "failed binding leaves prior generation usable")
	for tick: int in range(2, 1002):
		sample["tick"] = tick
		sample["frame"] = tick % 2
		expect(presenter.present(sample), "pooled sample stress")
	expect(presenter.get_child_count() == 8, "no per-frame pool growth")
	presenter.release()
	expect(not presenter.present(sample), "released presenter rejects late publication")
	for child: Node in presenter.get_children():
		var sprite := child as Sprite2D
		expect(not sprite.visible and sprite.texture == null, "release drops all texture references")
	expect(not presenter.configure(fixture_manifest(), textures, 1), "generation reuse rejected")
	expect(presenter.configure(fixture_manifest(), textures, 2), "presenter replacement")
	expect(presenter.get_child_count() == 8, "replacement reuses fixed pool")
	presenter.free()


func _test_compiled_resources() -> void:
	var atlas = load("res://game/content/art/slices/fixture.sheet/frame_0001.tres")
	expect(atlas is AtlasTexture, "native generated AtlasTexture loads")
	if atlas is AtlasTexture:
		expect(atlas.region == Rect2(4, 0, 4, 4) and atlas.filter_clip, "generated region and clip")
		expect(atlas.atlas.get_size() == Vector2(8, 4), "unchanged PNG dimensions")
		var image: Image = atlas.atlas.get_image()
		expect(not image.has_mipmaps(), "native import disables mipmaps")
		var pixel := image.get_pixel(7, 3)
		expect(pixel.r8 == 210 and pixel.g8 == 180 and pixel.b8 == 128, "lossless native import")
