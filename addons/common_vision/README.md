# Common Vision

Common Vision is a deterministic, bounded 2D visibility runtime for Godot 4.7
and newer. It answers one gameplay question: **what is this observer allowed to
know at this authority tick?**

The addon owns no autoload and does not inspect the scene tree. Your game creates
a `CommonVisionWorld2D`, gives it stable integer IDs and fixed-point geometry,
then explicitly asks it to produce observer-specific projections. Those
projections can drive AI, fog-of-war presentation, interest management, or the
built-in snapshot/delta codec.

Common Vision provides:

- isolated offline/server authority worlds and read-only replica worlds;
- range, cone, layer-mask, multi-sample, and exact segment-occlusion tests;
- per-observer visible/remembered/unknown state and last-known positions;
- deterministic, work-budgeted scheduling for many observers;
- recipient-specific, bounded snapshot/delta packets;
- hard limits and structured status dictionaries on every world operation.

It does **not** render fog, discover nodes, assign entity IDs, advance itself,
send RPCs, authenticate peers, or depend on the Gameplay Abilities addon. Those
remain game-level responsibilities.

This is a pre-1.0 API. The package currently reports API `0.1.0`, protocol `1`,
and algorithm contract `1`; check these at startup when binary compatibility is
important.

## Start here

1. Copy this directory to `res://addons/common_vision/` without changing its
   layout.
2. Ensure `bin/` contains the native artifact for the current platform and build
   type. This copy bundles universal macOS debug and release libraries; the
   additional platform entries in `common_vision.gdextension` are declarations,
   not bundled binaries. `release_manifest.json` records release provenance and
   checksums—verify the current file against its listed SHA-256 before relying on
   that release's verification results.
3. Reimport or restart Godot. Enabling **CommonVision** under **Project Settings
   > Plugins** is recommended for its missing-native-class warning, but it adds
   no autoload and is not required for world ownership.
4. Confirm `ClassDB.class_exists("CommonVisionWorld2D")` before constructing a
   world.

The smallest useful authority flow is:

```gdscript
extends Node

const CV_SCALE: int = 1_000_000

var vision: CommonVisionWorld2D
var authority_tick: int = 0


func _ready() -> void:
	vision = CommonVisionWorld2D.new()
	add_child(vision)

	_expect_ok(vision.configure(
		1001,
		CommonVisionWorld2D.OFFLINE_AUTHORITY,
	))
	_expect_ok(vision.register_observer({
		"id": 10,
		"position": {"x": 0, "y": 0},
		"facing": {"x": CV_SCALE, "y": 0},
		"range": 12 * CV_SCALE,
		"cone_cos_million": 707_107, # 90-degree total cone.
		"memory_ticks": 30,
		"revision": 1,
	}))
	_expect_ok(vision.register_target({
		"id": 20,
		"position": {"x": 4 * CV_SCALE, "y": 0},
		"revision": 1,
	}))

	authority_tick += 1
	var projection: Dictionary = vision.query_observer(10, authority_tick)
	_expect_ok(projection)
	for record: Dictionary in projection.get("records", []):
		if int(record.get("state", 0)) == 2: # VISIBLE
			print("Visible target: ", record["target_id"])


func _expect_ok(result: Dictionary) -> void:
	assert(
		result.get("ok", false),
		"Common Vision failed: code=%s diagnostic=%s detail=%s" % [
			result.get("code", -1),
			result.get("diagnostic", -1),
			result.get("detail", 0),
		],
	)
```

All positions, ranges, and sample offsets are signed integer microunits:
`1_000_000` Common Vision units equal one Godot world unit by convention. Ticks
are caller-owned logical integers, not seconds. A world performs no work until
you call `query_observer()` or `advance()`.

## Documentation map

- [Getting started](docs/getting-started.md) — installation, an end-to-end
  authority setup, updates, occluders, and projection consumption.
- [How it works](docs/how-it-works.md) — the query pipeline, deterministic
  units, ticks, revisions, memory, geometry, and scheduling model.
- [Godot API reference](docs/api-reference.md) — every public method, input
  dictionary, output field, enum value, and hard limit.
- [Authority and replicas](docs/networking.md) — recipient-safe packet flow,
  sequence handling, resynchronization, and the security boundary.
- [Performance and diagnostics](docs/performance-and-diagnostics.md) — budget
  tuning, failure handling, and symptom-based troubleshooting.

For the most common integration, read **Getting started**, then **How it works**.
The API reference is intended to replace source-code lookup during normal use.

## Compatibility check

```gdscript
func check_common_vision_binary() -> bool:
	if not ClassDB.class_exists("CommonVisionVersion"):
		push_error("Common Vision native library did not load")
		return false
	if CommonVisionVersion.get_api_version() != "0.1.0":
		push_error("Unsupported Common Vision API")
		return false
	if CommonVisionVersion.get_protocol_version() != 1:
		push_error("Unsupported Common Vision protocol")
		return false
	if CommonVisionVersion.get_algorithm_contract_version() != 1:
		push_error("Visibility rules differ from this game build")
		return false
	return true
```

`CommonVisionVersion.get_coordinate_scale()` returns `1_000_000`. Feature flags
are also exposed; see the [API reference](docs/api-reference.md#commonvisionversion).

## Full-source reference material

When this addon is viewed inside its full source checkout, the repository also
contains the normative [behavior contract](../../docs/vision/contracts.md),
[Godot API notes](../../docs/vision/godot-api.md), and
[presentation contract](../../docs/vision/DESIGN.md). The guides in this folder
are self-contained so a copied `addons/common_vision/` package remains usable.

License and third-party notices are in `LICENSE` and `THIRD_PARTY_LICENSES.md`.
