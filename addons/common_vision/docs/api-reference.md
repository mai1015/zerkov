# Godot API reference

The addon registers two native Godot classes:

- `CommonVisionWorld2D : Node` — mutable authority world or read-only replica;
- `CommonVisionVersion : RefCounted` — static compatibility and feature queries.

There are no signals, exported properties, autoloads, or automatically processed
methods in API `0.1.0`. All `CommonVisionWorld2D` operations return a Dictionary.
Check its `ok` field before reading operation-specific fields. Successful
projection Dictionaries contain `ok` but omit `code`, `diagnostic`, and `detail`;
failures and status-oriented operations include all four status fields.

## CommonVisionWorld2D

### Roles

| Constant | Value | Use |
| --- | ---: | --- |
| `OFFLINE_AUTHORITY` | `0` | Local/single-player canonical calculation |
| `SERVER_AUTHORITY` | `1` | Server-owned canonical calculation |
| `REPLICA` | `2` | Apply and read recipient projection packets only |

Offline and server authority have the same public calculation permissions in
this version. The distinction communicates intended deployment. Replica role is
enforced.

### Method overview

| Method | Offline/server authority | Replica | Effect |
| --- | :---: | :---: | --- |
| `configure(...)` | yes | yes | Reset and configure this node's native world |
| `set_occluder_segments(...)` | yes | rejected | Atomically replace all geometry |
| `register_observer(...)` | yes | rejected | Add observer definition |
| `update_observer(...)` | yes | rejected | Revision-checked full replacement |
| `remove_observer(...)` | yes | rejected | Remove observer, memory, and projection |
| `register_target(...)` | yes | rejected | Add target definition |
| `update_target(...)` | yes | rejected | Revision-checked full replacement |
| `remove_target(...)` | yes | rejected | Remove target and queue disclosed tombstones |
| `query_observer(...)` | yes | rejected | Calculate and publish one observer now |
| `advance(...)` | yes | rejected | Budget-schedule all observers |
| `get_projection(...)` | yes | no canonical view | Read latest authority projection |
| `encode_snapshot(...)` | yes | rejected | Encode latest recipient projection |
| `encode_delta(...)` | yes | rejected | Encode an exact successor projection |
| `decode_snapshot(...)` | yes | yes | Inspect bytes without mutation |
| `decode_delta(...)` | yes | yes | Inspect bytes without mutation |
| `apply_snapshot(...)` | rejected | yes | Atomically replace replica projection |
| `apply_delta(...)` | rejected | yes | Atomically apply exact successor |
| `request_resync()` | rejected | yes | Latch resync and build a request descriptor |
| `get_replica_projection()` | rejected | yes | Read last good replica projection |

`get_projection()` does not expose replica packet state. Use
`get_replica_projection()` on a replica.

### `configure`

```gdscript
configure(
	world_id: int,
	role: CommonVisionWorld2D.AuthorityRole,
	spatial_cell_size: int = 8_000_000,
	max_visited_cells: int = 65_536,
) -> Dictionary
```

Requirements:

- `world_id > 0`;
- role is one of the three constants above;
- `spatial_cell_size > 0`;
- `0 < max_visited_cells <= 65_536`.

Success returns only the standard status fields. Configuration replaces the
whole native world and clears all prior authority or replica state.

### `set_occluder_segments`

```gdscript
set_occluder_segments(segments: Array, geometry_revision: int) -> Dictionary
```

Replaces the full geometry set if every segment is valid and
`geometry_revision` is greater than the current geometry revision. An empty
Array with a fresh positive revision clears geometry. Failure is atomic.

Segment Dictionary:

| Key | Type | Default | Contract |
| --- | --- | ---: | --- |
| `id` | `int` | `0` | Required, positive, unique in this set |
| `a` | `Dictionary{x:int,y:int}` | `{0,0}` | First bounded canonical endpoint |
| `b` | `Dictionary{x:int,y:int}` | `{0,0}` | Second bounded endpoint; must differ from `a` |
| `mask` | `int` | `1` | Nonzero unsigned 32-bit layer mask |
| `two_sided` | `bool` | `true` | Must be true in algorithm contract 1 |

At most `131_072` segments are accepted. The runtime sorts accepted segments by
ID.

### Observer registration and update

```gdscript
register_observer(definition: Dictionary) -> Dictionary
update_observer(definition: Dictionary, expected_revision: int) -> Dictionary
remove_observer(observer_id: int) -> Dictionary
```

Observer Dictionary:

| Key | Type | Default | Contract |
| --- | --- | ---: | --- |
| `id` | `int` | `0` | Required positive ID |
| `position` | point Dictionary | `{0,0}` | Canonical observer origin |
| `facing` | point Dictionary | `{1_000_000,0}` | Nonzero direction; missing or `{0,0}` becomes +X |
| `range` | `int` | `10_000_000` | Positive, at most `4_000_000_000_000`; grid rectangle must fit configured visit limit |
| `cone_cos_million` | `int` | `0` | Cosine of half-angle in `[0,1_000_000]`; `0` still excludes exactly sideways and behind |
| `full_circle` | `bool` | `false` | Ignore cone threshold when true |
| `target_mask` | `int` | `4_294_967_295` | Nonzero unsigned 32-bit target layers |
| `occluder_mask` | `int` | `4_294_967_295` | Nonzero unsigned 32-bit blocker layers |
| `memory_ticks` | `int` | `0` | Nonnegative memory duration |
| `priority` | `int` | `0` | Signed 32-bit scheduler priority; higher runs first after age |
| `urgent` | `bool` | `false` | Urgent scheduler class |
| `revision` | `int` | `1` | Positive definition revision |

At most `4_096` observers may be registered. Duplicate IDs return
`ALREADY_EXISTS`.

For update, `expected_revision` must equal the stored revision and the new
Dictionary's `revision` must equal `expected_revision + 1`. The full accepted
definition replaces the old definition; visibility memory remains until future
queries transition it. `remove_observer()` permanently removes that observer's
definition, memory, pending removals, and latest projection.

### Target registration and update

```gdscript
register_target(definition: Dictionary) -> Dictionary
update_target(definition: Dictionary, expected_revision: int) -> Dictionary
remove_target(target_id: int) -> Dictionary
```

Target Dictionary:

| Key | Type | Default | Contract |
| --- | --- | ---: | --- |
| `id` | `int` | `0` | Required positive ID |
| `position` | point Dictionary | `{0,0}` | Canonical base position and spatial-grid location |
| `mask` | `int` | `1` | Nonzero unsigned 32-bit target layers |
| `sample_policy` | `int` | `0` | `0 ANY_SAMPLE`, `1 ALL_SAMPLES` |
| `sample_offsets` | `Array[point Dictionary]` | `[{0,0}]` | One to eight offsets; empty also becomes center sample |
| `revision` | `int` | `1` | Positive definition revision |

At most `16_384` targets may be registered. An update has the same exact
compare-and-swap rule as an observer update and replaces the complete
definition. The target's spatial-grid entry moves atomically with an accepted
update.

Removing a target queues a one-shot tombstone only for observers that still
retain its disclosed visible/remembered record. The tombstone is published by
each affected observer's next successful query. A target whose memory already
expired is no longer retained and produces no tombstone.

### `query_observer`

```gdscript
query_observer(observer_id: int, tick: int) -> Dictionary
```

Runs one observer with the compiled `10_000_000` work-unit maximum. `tick` must
be nonnegative and not lower than this observer's last completed tick. Equal
ticks are accepted, but each successful call still advances the observer's
`result_revision`.

Success returns a projection Dictionary directly. On failure it returns only a
status Dictionary and does not publish partial memory or a projection.

### `advance`

```gdscript
advance(tick: int, work_budget: int) -> Dictionary
```

Schedules all registered observers using a deterministic order and a total
budget in `[0, 10_000_000]`. Success adds:

| Key | Meaning |
| --- | --- |
| `requested` | Sum of conservative per-observer estimates |
| `consumed` | Actual work charged by observers attempted this call |
| `completed` | Observers that atomically published a projection |
| `invalidated` | Reserved; currently zero |
| `deferred` | Observers not published because their estimate/work did not fit |

The method can return `ok == true` while some or all observers are deferred.
Inspect the metrics and each projection's `completed_tick`.

Completion is atomic per observer, not across the whole call. If a later
observer fails—for example because its tick regresses or a position-plus-sample
sum is out of range—earlier observers may already have published. The failure
result still includes the metrics accumulated before the error. Use one global
nondecreasing tick, especially when mixing `query_observer()` and `advance()`,
and reject invalid sample sums at your authoring boundary.

### `get_projection`

```gdscript
get_projection(observer_id: int) -> Dictionary
```

Returns the latest successful authority projection. Before the first completed
query—or for an unknown observer—it returns `NOT_FOUND`. The returned Dictionary
is a value copy and is safe to index or duplicate in game code.

## Projection shape

`query_observer()`, `get_projection()`, decoded packet projections, and
`get_replica_projection()` use this shape:

| Key | Type | Meaning |
| --- | --- | --- |
| `ok` | `bool` | Always true for a returned projection |
| `observer_id` | `int` | Recipient observer |
| `world_revision` | `int` | Canonical world revision captured |
| `geometry_revision` | `int` | Whole-geometry revision captured |
| `observer_revision` | `int` | Observer definition revision captured |
| `result_revision` | `int` | Per-observer successful-query sequence |
| `completed_tick` | `int` | Caller tick of this completed query |
| `work_units` | `int` | Actual candidate plus eligible segment tests |
| `records` | `Array[Dictionary]` | Sorted observer-visible records |

Replica projections add `sequence` and `resync_required` at this same top
level. The sequence must equal `result_revision`.

Visibility record:

| Key | Type | Meaning |
| --- | --- | --- |
| `target_id` | `int` | Disclosed stable target ID |
| `state` | `int` | Visibility state below |
| `transition` | `int` | Transition below |
| `first_seen_tick` | `int` | First recorded visibility tick |
| `last_seen_tick` | `int` | Most recent visible tick |
| `has_last_known_position` | `bool` | Whether position is permitted/meaningful |
| `last_known_position` | point Dictionary | Last disclosed position, or `{0,0}` when flag is false |
| `geometry_revision` | `int` | Geometry revision recorded for this state |
| `target_revision` | `int` | Last disclosed target revision |

Always obey `has_last_known_position`; the position key is present even when its
value is deliberately invalidated.

### Visibility state values

| Name | Value | Meaning |
| --- | ---: | --- |
| `UNKNOWN` | `0` | No retained knowledge; only present for a terminal transition |
| `REMEMBERED` | `1` | Historical last-known information |
| `VISIBLE` | `2` | Currently confirmed by this completed query |

### Transition values

| Name | Value | Meaning |
| --- | ---: | --- |
| `NONE` | `0` | No transition |
| `BECAME_VISIBLE` | `1` | Hidden/absent/remembered to visible |
| `REMAINED_VISIBLE` | `2` | Visible on consecutive completed queries |
| `BECAME_REMEMBERED` | `3` | Visible to remembered |
| `REMAINED_REMEMBERED` | `4` | Still within memory window |
| `MEMORY_EXPIRED` | `5` | One-shot, position-free terminal record |
| `REMOVED` | `6` | One-shot, position-free removal tombstone |

These values are not exposed as `CommonVisionWorld2D` constants in API `0.1.0`;
define named constants in your integration rather than scattering numbers.

## Snapshot and delta methods

### Authority encoding

```gdscript
encode_snapshot(observer_id: int) -> Dictionary
encode_delta(observer_id: int, predecessor_sequence: int) -> Dictionary
```

Both encode only the latest completed native projection for that observer.

Snapshot success adds:

- `bytes: PackedByteArray`
- `sequence: int`

Delta success adds:

- `bytes: PackedByteArray`
- `predecessor_sequence: int`
- `successor_sequence: int`

The first publication must be a snapshot because delta predecessors must be
positive. A delta succeeds only when the current result revision equals
`predecessor_sequence + 1`; otherwise it returns `SNAPSHOT_REQUIRED`. A Common
Vision delta contains the complete successor projection, not a field-level
diff—it is “delta” in its exact-successor sequencing contract.

### Packet inspection

```gdscript
decode_snapshot(bytes: PackedByteArray) -> Dictionary
decode_delta(bytes: PackedByteArray) -> Dictionary
```

These bounded, read-only methods are valid on any role and do not apply data.
Snapshot decode success returns `world_id`, `sequence`, and nested `projection`.
Delta decode success returns `world_id`, `predecessor_sequence`,
`successor_sequence`, and nested `projection`.

### Replica application

```gdscript
apply_snapshot(bytes: PackedByteArray) -> Dictionary
apply_delta(bytes: PackedByteArray) -> Dictionary
request_resync() -> Dictionary
get_replica_projection() -> Dictionary
```

`apply_snapshot()` and `apply_delta()` return the standard status plus:

- `applied: bool`
- `resync_required: bool`
- `last_sequence: int`

Snapshot application validates protocol/algorithm, signed Godot bounds, world,
observer binding, and freshness before replacing state. Once a first snapshot
binds an observer, a different observer is rejected. A replacement snapshot for
an initialized replica must have a strictly newer sequence.

Delta application requires an existing snapshot and its exact next sequence. A
gap returns `SNAPSHOT_REQUIRED`, latches `resync_required`, and preserves the
last good view. Further deltas remain blocked until a newer valid snapshot is
applied.

`request_resync()` latches the same state and returns:

- `requested: true`
- `world_id`
- `observer_id` (`0` before a first snapshot)
- `last_sequence` (`0` before a first snapshot)

It does not send anything. `get_replica_projection()` returns the last good
projection plus `sequence` and `resync_required`, or `NOT_FOUND` before the
first snapshot.

See [Authority and replicas](networking.md) for an end-to-end flow.

## Status dictionaries

Every failure result and every status-oriented result contains:

| Key | Type | Meaning |
| --- | --- | --- |
| `ok` | `bool` | `code == OK` |
| `code` | `int` | Broad result category |
| `diagnostic` | `int` | More specific stable diagnostic for this build |
| `detail` | `int` | Diagnostic-specific count, ID, budget, or revision; often zero |

A successful projection returned by `query_observer()`, `get_projection()`, or
`get_replica_projection()` has `ok == true` and projection fields instead of the
other three status fields.

Status codes:

| Name | Value |
| --- | ---: |
| `OK` | `0` |
| `INVALID_ARGUMENT` | `1` |
| `NOT_FOUND` | `2` |
| `ALREADY_EXISTS` | `3` |
| `LIMIT_EXCEEDED` | `4` |
| `ARITHMETIC_ERROR` | `5` |
| `REVISION_MISMATCH` | `6` |
| `ROLE_VIOLATION` | `7` |
| `SNAPSHOT_REQUIRED` | `8` |
| `INCOMPATIBLE` | `9` |
| `INTERNAL_ERROR` | `10` |

Diagnostic IDs:

| Name | Value | Typical meaning |
| --- | ---: | --- |
| `NONE` | `0` | No specific diagnostic |
| `INVALID_IDENTITY` | `1` | Zero/negative, missing, duplicate, or wrong-bound identity |
| `NON_POSITIVE_RANGE` | `2` | Invalid range/radius |
| `INVALID_DIRECTION` | `3` | Invalid zero direction in native contract |
| `INVALID_CONE` | `4` | Cone cosine outside accepted range |
| `INVALID_MASK` | `5` | Zero or out-of-range mask |
| `INVALID_SAMPLE_POLICY` | `6` | Sample policy not `0` or `1` |
| `COUNT_LIMIT_EXCEEDED` | `7` | Collection or grid-visit bound exceeded |
| `COORDINATE_OUT_OF_RANGE` | `8` | Coordinate/cell-size input outside contract |
| `COORDINATE_OVERFLOW` | `9` | Checked arithmetic or Godot signed conversion failed |
| `ZERO_LENGTH_SEGMENT` | `10` | Segment endpoints are identical |
| `DUPLICATE_SEGMENT` | `11` | Repeated segment ID |
| `GEOMETRY_REVISION_STALE` | `12` | Geometry revision did not increase |
| `WORLD_REVISION_STALE` | `13` | Regressing tick or stale/gapped wire sequence, depending on operation |
| `OBSERVER_REVISION_STALE` | `14` | Observer compare-and-swap failed |
| `TARGET_REVISION_STALE` | `15` | Target compare-and-swap failed |
| `WORK_BUDGET_EXCEEDED` | `16` | Requested/consumed query work limit |
| `PROJECTION_STALE` | `17` | Packet sequence and projection revision disagree |
| `PROTOCOL_VERSION_DIFFERS` | `18` | Packet protocol incompatible |
| `ALGORITHM_VERSION_DIFFERS` | `19` | Visibility contract incompatible |
| `TRUNCATED_PAYLOAD` | `20` | Packet ended before required data |
| `PAYLOAD_TOO_LARGE` | `21` | Packet exceeds 16 MiB |
| `INVALID_ENUM` | `22` | Invalid encoded enum or unsupported one-sided segment |
| `ROLE_IS_REPLICA` | `23` | Canonical operation attempted on replica |

Use `code` for the main recovery branch and log `diagnostic` plus `detail`.
`detail` is operation-specific; do not assume it always names an entity.

## CommonVisionVersion

All methods are static:

| Method | Current result | Purpose |
| --- | --- | --- |
| `get_api_version() -> String` | `"0.1.0"` | Godot/native API contract |
| `get_protocol_version() -> int` | `1` | Snapshot/delta wire compatibility |
| `get_algorithm_contract_version() -> int` | `1` | Exact visibility-rule compatibility |
| `get_coordinate_scale() -> int` | `1_000_000` | Canonical microunits per conventional world unit |
| `get_supported_features() -> int` | feature bit set | Inspect all supported features |
| `has_feature(feature: int) -> bool` | varies | Test that every requested bit is present |

Feature constants:

| Constant | Value |
| --- | ---: |
| `FEATURE_FIXED_POINT_LOS` | `1` |
| `FEATURE_VISIBILITY_MEMORY` | `2` |
| `FEATURE_BUDGET_SCHEDULER` | `4` |
| `FEATURE_SNAPSHOT_DELTA` | `8` |
| `FEATURE_DEDICATED_SERVER` | `16` |

Example:

```gdscript
var supports_wire := CommonVisionVersion.has_feature(
	CommonVisionVersion.FEATURE_SNAPSHOT_DELTA
)
```

## Compiled hard limits

These limits are part of the current binary contract:

| Limit | Value |
| --- | ---: |
| observers per world | `4_096` |
| targets per world | `16_384` |
| occluder segments | `131_072` |
| samples per target | `8` |
| memory/projection records per observer | `16_384` |
| visited broadphase cells per query | `65_536` maximum; may configure lower |
| work units per direct query/advance call | `10_000_000` |
| absolute canonical coordinate | `4_000_000_000_000` |
| encoded snapshot/delta bytes | `16 MiB` |

Limits are checked before untrusted allocation or iteration where applicable.
A limit failure does not publish partial observer state.
