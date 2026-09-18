extends SceneTree
## Explicit authoring/CI command for immutable native-map preview/navigation data.
## Runtime never invokes this script and never writes source resources.
const MAP_IDS: Array[String] = ["northline", "blackwater"]

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["--check", "--write"]:
		push_error("LIVE_MAP_CACHE_USAGE: expected --check or --write")
		quit(2)
		return
	var mode: String = args[0].trim_prefix("--")
	var pending: Dictionary = {}
	for map_id: String in MAP_IDS:
		var record := NativeRaidMap.rebuild_cache_record(map_id)
		if record.is_empty():
			push_error("LIVE_MAP_CACHE_BUILD_FAILED: %s %s" % [map_id, NativeRaidMap.last_error])
			quit(1)
			return
		pending[NativeRaidMap.CACHE_PATHS[map_id]] = JSON.stringify(record, "", true, true) + "\n"
	if mode == "check":
		for path: String in pending:
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if not parsed is Dictionary:
				push_error("LIVE_MAP_CACHE_INVALID: " + path)
				quit(1)
				return
			var expected: Variant = JSON.parse_string(String(pending[path]))
			var current := JSON.stringify(parsed, "", true, true)
			var canonical_expected := JSON.stringify(expected, "", true, true)
			if current != canonical_expected:
				push_error("LIVE_MAP_CACHE_STALE: " + path)
				quit(1)
				return
	else:
		for path: String in pending:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file == null:
				push_error("LIVE_MAP_CACHE_WRITE_FAILED: " + path)
				quit(1)
				return
			file.store_string(pending[path])
			file.close()
	print("LIVE_MAP_CACHE_RESULT maps=", MAP_IDS.size(), " mode=", mode, " failures=0")
	quit(0)
