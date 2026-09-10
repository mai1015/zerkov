# Getting started

This guide builds one authoritative visibility world, adds walls, observers, and
targets, updates them over logical ticks, and consumes the resulting projection.
It uses only the public Godot API.

## 1. Verify the installation

The installed layout must include:

```text
res://addons/common_vision/
├── common_vision.gdextension
├── plugin.cfg
├── release_manifest.json
└── bin/
    └── <library for your platform and build type>
```

The `.gdextension` file declares several platforms, but a declaration is not a
binary. This copy includes universal macOS debug and release libraries only; you
must provide a matching build before using one of the other declared platforms.
`release_manifest.json` records release provenance and expected SHA-256 values.
If a library's current checksum differs, it has been rebuilt or replaced and the
manifest's verification history no longer describes that file. After Godot
imports the project, this check must succeed:

```gdscript
if not ClassDB.class_exists("CommonVisionWorld2D"):
	push_error("Common Vision did not load; check the native artifact and editor log")
```

The editor plugin only reports missing native classes. It creates no singleton,
node, resource, or project setting.

## 2. Choose canonical IDs, units, and ticks

Common Vision deliberately knows nothing about your scene nodes. Define stable,
positive integer IDs for:

- each visibility world;
- each observer in that world;
- each target in that world;
- each occluder segment in the current geometry set.

IDs only need to be unique within their category and world. Do not use a node's
`ObjectID`, instance allocation order, RID, or path as long-lived authority
identity.

Coordinates are integer fixed point. One convenient boundary adapter is:

```gdscript
const CV_SCALE: int = 1_000_000


static func cv_scalar(world_units: float) -> int:
	return int(round(world_units * CV_SCALE))


static func cv_point(point: Vector2) -> Dictionary:
	return {
		"x": cv_scalar(point.x),
		"y": cv_scalar(point.y),
	}
```

For networked authority, perform float-to-integer conversion on the authority;
do not have several peers independently quantize transforms and assume the
results are authoritative. If your game already simulates with integers, pass
those integers directly.

Ticks are nonnegative logical integers supplied by the game. They do not have a
fixed duration. Starting at tick `1` makes `first_seen_tick == 0` remain a useful
"not seen" sentinel in surrounding game code. Never send a lower tick than that
observer's last completed query.

## 3. Own and configure a world

Create one `CommonVisionWorld2D` for each independent game world or match. Add
it as a child so normal Godot ownership frees it with its parent.

```gdscript
var vision := CommonVisionWorld2D.new()
add_child(vision)

var configured: Dictionary = vision.configure(
	501,                                      # Positive world ID.
	CommonVisionWorld2D.SERVER_AUTHORITY,     # Or OFFLINE_AUTHORITY.
	8_000_000,                                # 8 world-unit grid cells.
	65_536,                                   # Maximum cells per broadphase query.
)
require_ok(configured, "configure vision")
```

Always call `configure()` before registration even though a newly constructed
node has internal defaults. A successful later call is a reset: it discards
geometry, registrations, projections, replica state, and the resync latch. A
rejected configuration leaves the existing world intact.

Use `OFFLINE_AUTHORITY` for a local/single-player authority and
`SERVER_AUTHORITY` for a server. Their calculation privileges are currently the
same; the separate role records intent. Use `REPLICA` only for a recipient that
applies server-produced packets.

## 4. Install the complete occluder set

Occluders are two-sided line segments. `set_occluder_segments()` atomically
replaces the whole set, so submit all current walls and a strictly increasing
geometry revision.

```gdscript
var geometry_revision: int = 1
require_ok(vision.set_occluder_segments([
	{
		"id": 1,
		"a": {"x": 6_000_000, "y": -4_000_000},
		"b": {"x": 6_000_000, "y": -1_000_000},
		"mask": 1,
		"two_sided": true,
	},
	{
		"id": 2,
		"a": {"x": 6_000_000, "y": 1_000_000},
		"b": {"x": 6_000_000, "y": 4_000_000},
		"mask": 1,
		"two_sided": true,
	},
], geometry_revision), "set vision geometry")
```

This example leaves a two-unit doorway between the segments. Segment IDs must
be positive and unique. Zero-length segments, zero masks, duplicate IDs,
out-of-range endpoints, and `two_sided == false` are rejected by algorithm
contract 1.

To change or clear geometry later, submit the complete replacement with
revision `geometry_revision + 1`. A failed replacement leaves the previous set
active.

## 5. Register observers and targets

An observer describes a view query. This one looks to the right through a
90-degree cone and remembers previously visible targets for 30 authority ticks.

```gdscript
var observer_definition: Dictionary = {
	"id": 100,
	"position": {"x": 0, "y": 0},
	"facing": {"x": 1_000_000, "y": 0},
	"range": 12_000_000,
	"cone_cos_million": 707_107,
	"full_circle": false,
	"target_mask": 0b0001,
	"occluder_mask": 0b0001,
	"memory_ticks": 30,
	"priority": 100,
	"urgent": true,
	"revision": 1,
}
require_ok(
	vision.register_observer(observer_definition),
	"register observer",
)
```

`cone_cos_million` is the cosine of the cone's **half-angle**, multiplied by
`1_000_000`. Thus `707_107` is approximately `cos(45 degrees)` and produces a
90-degree total cone. Set `full_circle` to `true` for omnidirectional sight.

Targets have a base position, a layer mask, and one or more occlusion samples:

```gdscript
var target_definition: Dictionary = {
	"id": 200,
	"position": {"x": 9_000_000, "y": 0},
	"mask": 0b0001,
	"sample_policy": 0, # ANY_SAMPLE
	"sample_offsets": [
		{"x": 0, "y": -500_000},
		{"x": 0, "y": 500_000},
	],
	"revision": 1,
}
require_ok(vision.register_target(target_definition), "register target")
```

With `ANY_SAMPLE` (`0`), one clear sample makes the target visible. With
`ALL_SAMPLES` (`1`), every sample must be clear. The base position—not the
offset samples—is used for broadphase, range, and cone filtering. Samples only
control line-of-sight testing after that filter passes.

## 6. Query and consume a projection

For one or a few critical observers, query directly:

```gdscript
const UNKNOWN := 0
const REMEMBERED := 1
const VISIBLE := 2

var authority_tick: int = 1
var projection: Dictionary = vision.query_observer(100, authority_tick)
require_ok(projection, "query observer")

for record: Dictionary in projection.get("records", []):
	match int(record.get("state", UNKNOWN)):
		VISIBLE:
			show_current_target(int(record["target_id"]))
		REMEMBERED:
			var last_position: Dictionary = record["last_known_position"]
			show_last_known_marker(int(record["target_id"]), last_position)
		UNKNOWN:
			# UNKNOWN is only emitted for a one-shot expiry/removal transition.
			hide_target_knowledge(int(record["target_id"]))
```

Never-seen, masked, out-of-range, and occluded targets are absent rather than
listed as `UNKNOWN`. Treat a missing ID as unknown. Do not use a hidden actor's
live scene transform while presenting a `REMEMBERED` record; use only
`last_known_position` when `has_last_known_position` is true.

`query_observer()` returns and publishes the same projection. Later calls to
`get_projection(observer_id)` return a fresh Dictionary copy of the latest
successful publication. Mutating a returned Dictionary does not mutate native
authority state.

## 7. Apply full-definition updates

Observer and target updates are compare-and-swap replacements, not patches.
Pass the current revision separately as `expected_revision`, and put exactly
`expected_revision + 1` in the complete new definition.

```gdscript
func move_target(new_position: Vector2) -> void:
	var next_definition: Dictionary = target_definition.duplicate(true)
	var expected_revision: int = int(target_definition["revision"])
	next_definition["position"] = cv_point(new_position)
	next_definition["revision"] = expected_revision + 1

	var result: Dictionary = vision.update_target(
		next_definition,
		expected_revision,
	)
	if result.get("ok", false):
		target_definition = next_definition
	else:
		report_cv_error("update target", result)
```

Use the same pattern with `update_observer(definition, expected_revision)`.
Missing keys receive registration defaults, so a partial update can
accidentally reset fields. Keep the accepted full definition as your game-side
configuration value.

Successful updates change canonical state immediately, but visibility memory
and projections change only after the next successful query.

## 8. Schedule many observers

When many observers share a per-tick budget, call `advance()` once instead of
querying each one yourself:

```gdscript
authority_tick += 1
var metrics: Dictionary = vision.advance(authority_tick, 100_000)
require_ok(metrics, "advance vision")

var latest: Dictionary = vision.get_projection(100)
if latest.get("ok", false) and \
		int(latest.get("completed_tick", 0)) == authority_tick:
	consume_current_projection(latest)
else:
	# This observer was deferred; retain the previous presentation/read model.
	pass
```

The scheduler publishes only complete observers. A deferred observer retains
its previous projection and memory. Always compare `completed_tick` with the
tick you expected; `get_projection()` can legitimately return older data.

Scheduling order is deterministic: urgent observers first, then least recently
completed, then higher priority, then lower observer ID. See
[How it works](how-it-works.md#scheduled-queries-and-work-units) for budget
semantics and [Performance and diagnostics](performance-and-diagnostics.md) for
tuning.

## 9. Remove lifecycle entries

```gdscript
require_ok(vision.remove_target(200), "remove target")
require_ok(vision.remove_observer(100), "remove observer")
```

Removing an observer immediately removes its memory and projection. Removing a
target queues a position-free `REMOVED` tombstone for every observer that still
retains its disclosed visible/remembered record. Each tombstone appears in that
observer's next successful projection and is then omitted. If that observer's
memory had already expired and been purged, removal discloses nothing.

## Reusable error helpers

```gdscript
func require_ok(result: Dictionary, operation: String) -> void:
	if not result.get("ok", false):
		report_cv_error(operation, result)
		assert(false, "Common Vision operation failed")


func report_cv_error(operation: String, result: Dictionary) -> void:
	push_error(
		"%s: code=%d diagnostic=%d detail=%d" % [
			operation,
			int(result.get("code", -1)),
			int(result.get("diagnostic", -1)),
			int(result.get("detail", 0)),
		]
	)
```

The numeric mappings and recovery guidance are in the
[API reference](api-reference.md#status-dictionaries) and
[diagnostics guide](performance-and-diagnostics.md#status-first-error-handling).

Next: [How Common Vision works](how-it-works.md).
