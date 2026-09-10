# Performance and diagnostics

Common Vision makes cost and failure explicit. There is no time-based budget,
silent truncation, or partially published observer. This guide explains how to
size the world, interpret metrics, and recover from each failure class.

## Status-first error handling

Every public operation returns a Dictionary with `ok`. Failures and
status-oriented results also contain `code`, `diagnostic`, and `detail`;
successful projections omit those three fields. Never infer success from the
presence of another key.

```gdscript
func cv_error(operation: String, result: Dictionary) -> String:
	return "%s: code=%d diagnostic=%d detail=%d" % [
		operation,
		int(result.get("code", -1)),
		int(result.get("diagnostic", -1)),
		int(result.get("detail", 0)),
	]


func checked(result: Dictionary, operation: String) -> bool:
	if result.get("ok", false):
		return true
	push_error(cv_error(operation, result))
	return false
```

Use `code` for the recovery branch and log the other fields. `detail` is
diagnostic-specific: it may contain an ID, count, requested budget, current
revision, or zero. The complete numeric mapping is in
[Status dictionaries](api-reference.md#status-dictionaries).

## Recovery by status code

| Code | Response |
| --- | --- |
| `INVALID_ARGUMENT` | Fix the submitted definition. Check positive IDs/revisions/ranges, nonzero masks, cone bounds, and point Dictionary keys. |
| `NOT_FOUND` | Register the entity first. For projections, complete the observer's first query before reading/encoding. |
| `ALREADY_EXISTS` | Do not register the same ID twice; use a revision-checked update or choose another ID. |
| `LIMIT_EXCEEDED` | Reduce counts/range/samples/geometry, enlarge grid cells, raise only a locally configured lower limit, or increase a work budget up to the compiled cap. |
| `ARITHMETIC_ERROR` | Reject the update/query and inspect position plus sample-offset sums; never clamp a received wire value silently. |
| `REVISION_MISMATCH` | Reload your game-side accepted definition/sequence and retry with the exact next revision, or send a snapshot for a wire gap. |
| `ROLE_VIOLATION` | Route the call to the authority or replica node appropriate for the operation. |
| `SNAPSHOT_REQUIRED` | Stop dependent deltas and deliver a strictly newer complete snapshot. |
| `INCOMPATIBLE` | Reject the packet/session. Check world, observer binding, protocol, and algorithm versions. |
| `INTERNAL_ERROR` | Treat as an addon/runtime defect; preserve the failing inputs and version information. |

Mutations, direct queries, and packet applications are transactional for the
documented failure cases: keep using the prior accepted state rather than
trying to repair a partial result.

`advance()` is the exception at the whole-call level: each observer publishes
atomically, but a later observer can fail after earlier observers have completed.
The returned failure Dictionary still contains the metrics accumulated before
the error. Prevent tick failures by using one global nondecreasing authority
tick and never scheduling below an observer tick used by a direct query; prevent
query-time arithmetic failures by rejecting out-of-range position-plus-sample
sums at your authoring boundary.

## Understanding query cost

Actual `work_units` are deterministic counts, not microseconds:

```text
1 unit for each target returned by the broadphase square
+
1 unit for each mask-eligible occluder segment tested against a sample ray
```

Range/cone/mask rejection still costs the candidate unit but avoids sample rays.
Occluder-mask rejection costs no segment-test unit. A blocker, `ANY_SAMPLE`
success, or `ALL_SAMPLES` failure may end work early.

The scheduler uses a deliberately conservative estimate before admitting an
observer:

```text
candidate_count
+ matching-target sample_count × total_segment_count
```

It counts all segments in that estimate even if occluder masks will skip some,
and it assumes every sample/segment may be needed. Therefore:

- `requested` can be much larger than `consumed`;
- a query can be deferred even when its likely real cost seems small;
- the admission decision is reproducible and never depends on machine speed.

## Choosing grid settings

Default configuration uses eight-world-unit cells and a `65_536`-cell query
limit. Observer validation considers the inclusive cell rectangle covered by
`position ± range`, even when the grid contains no targets.

If observer registration reports `LIMIT_EXCEEDED / COUNT_LIMIT_EXCEEDED`:

1. verify that range was supplied in microunits rather than raw world units or
   vice versa;
2. enlarge `spatial_cell_size` so the view square spans fewer cells;
3. reduce observer range if it exceeds actual gameplay need;
4. raise `max_visited_cells` only if you configured it below `65_536`.

You cannot raise the hard limit above `65_536`. Reconfiguring to change grid
settings clears the world, so choose settings before registering content or
explicitly rebuild all state afterward.

Very large cells reduce cell visits but collect more out-of-range candidates.
Very small cells reduce candidate spill but can reject large observer ranges.
Measure both `work_units` and broadphase-limit failures with representative
entity density.

## Reducing occlusion work

The target grid indexes targets, not walls. Every sample that reaches occlusion
may walk the sorted segment list until blocked or exhausted.

High-impact optimizations are:

- remove duplicate or invisible authored edges before submission;
- merge collinear wall pieces when doing so preserves exact endpoint/corner
  behavior;
- use occluder masks to skip categories irrelevant to an observer;
- keep target sample counts small and meaningful;
- use `ANY_SAMPLE` when one visible point is sufficient;
- use coarse target masks to reject entire categories before rays;
- divide logically independent maps into separate worlds;
- budget background observers through `advance()` and reserve direct queries
  for genuinely critical observers.

Be careful when merging segments: isolated endpoint touches are clear while
positive-length overlaps block. Changing endpoints can therefore change the
algorithm-contract result even when rendered walls look similar.

## Budgeting a production tick

A common pattern is to give urgent player observers priority and let background
AI age fairly:

```gdscript
var metrics: Dictionary = vision.advance(authority_tick, vision_budget)
if not checked(metrics, "advance vision"):
	return

if int(metrics.get("deferred", 0)) > 0:
	print_verbose(
		"Vision deferred %d observers; requested=%d consumed=%d" % [
			int(metrics["deferred"]),
			int(metrics["requested"]),
			int(metrics["consumed"]),
		]
	)
```

The order is urgent first, then oldest completed tick, then higher priority,
then lower ID. An expensive observer that does not fit is skipped; a later
cheaper one may still complete. This avoids one large observer blocking all
remaining work while keeping ordering reproducible.

After `advance()`, freshness is per observer:

```gdscript
var view: Dictionary = vision.get_projection(observer_id)
var is_current := (
	view.get("ok", false)
	and int(view.get("completed_tick", -1)) == authority_tick
)
```

Choose explicitly what each consumer does with stale data. A visual fog mask
might retain the last good projection; an attack validator might fail closed.
Do not interpret `advance().ok` as “every observer completed.”

The current `invalidated` metric is reserved and remains zero. Use `deferred`
and per-projection `completed_tick` for current scheduling decisions.

## Memory sizing and behavior

Each observer may publish at most `16_384` records. Memory contains only targets
that observer actually saw, plus pending one-shot removals. Never-seen canonical
targets consume no per-observer memory record.

When record capacity is full, queued removal tombstones take priority over a
newly visible identity. The new identity may be disclosed by a later query after
tombstones are emitted. This preserves removal delivery and the wire bound.

Long `memory_ticks` increases how long disclosed records remain. It does not
continuously copy hidden target updates: a remembered record keeps its last
visible position and target revision. Memory advances only on completed
observer queries; a deferred observer does not age until it is queried at a
later tick.

## Common symptoms

### Native classes do not exist

- Confirm the directory is exactly `res://addons/common_vision/`.
- Check that the `.gdextension` library path has a matching file in `bin/`.
- Check the current platform, CPU architecture, and debug/release build type.
- Read `release_manifest.json`; declared platforms without bundled artifacts
  are not usable until you provide a matching build.
- Restart/reimport and inspect the editor log. Enabling the editor plugin adds a
  focused warning but cannot manufacture a missing binary.

### A query succeeds but `records` is empty

Check, in order:

1. target and observer are registered in the same world;
2. positions and range use microunits;
3. target and observer target masks overlap and are nonzero;
4. the target base position is inside the exact range;
5. `full_circle` is true, or facing/cone includes the base position;
6. at least one sample is clear for `ANY_SAMPLE`, or every sample for
   `ALL_SAMPLES`;
7. you are not expecting never-seen hidden targets to appear as `UNKNOWN`.

Missing `facing` defaults to +X. `cone_cos_million: 0` still covers only the
forward half-plane; use `full_circle: true` for omnidirectional sight.

### `get_projection()` returns `NOT_FOUND`

Registration alone does not create a projection. Successfully call
`query_observer()` or give `advance()` enough budget to complete the observer.
If it was scheduled, check `completed`/`deferred`.

### Projection data is older than the current game tick

The observer was deferred or has not been queried. Compare `completed_tick`, not
`world_revision`, to your requested tick. Increase budget, reduce cost, mark the
observer urgent, raise its priority, or query it directly if gameplay requires
an immediate result.

### An update returns `REVISION_MISMATCH`

Updates are full compare-and-swap replacements. If stored revision is `N`, pass
`expected_revision == N` and submit `definition.revision == N + 1`. Only advance
your game-side cached definition/revision after `ok == true`.

Geometry is different: it has one whole-set revision that must simply be
strictly greater than the previous accepted geometry revision.

### A remembered target seems to move while hidden

Common Vision does not update the record's hidden position. The leak is likely
in presentation or another replication channel. Use only
`last_known_position` from the projection, and only when
`has_last_known_position` is true.

### Memory expires one tick later than expected

Expiry uses:

```text
current_tick - last_seen_tick > memory_ticks
```

At an equal difference it is still remembered. Expiry is evaluated only on a
successful query. `MEMORY_EXPIRED` appears once; the ID is absent next time.

### A wall endpoint does not block sight

That is algorithm contract 1: an isolated endpoint touch is clear. A proper
crossing, positive-length overlap, or target sample on a wall blocks. Author
adjacent boundaries with this exact rule in mind and version-gate the algorithm
contract.

## Network and replica failures

### `encode_delta()` returns `SNAPSHOT_REQUIRED`

The supplied predecessor is not exactly one less than the current observer
`result_revision`. Send `encode_snapshot()` instead. Track sequence separately
for every recipient/observer.

### `apply_delta()` returns `SNAPSHOT_REQUIRED`

The replica has no base snapshot, saw a gap, or is already resync-latched. Keep
the last good view, call `request_resync()`, and obtain a strictly newer
snapshot. Do not keep applying dependent deltas.

### A recovery snapshot is rejected as stale

An initialized replica accepts only a snapshot whose sequence is greater than
its last good sequence. Complete a newer authority query, encode that snapshot,
and resend it.

### A packet decodes but will not apply

Decode validates packet shape and compatibility but does not bind it to a
replica. Apply additionally checks configured world, bound observer, freshness,
and sequence continuity. Log both decode/apply statuses and verify you routed
the correct recipient's bytes.

### A malformed packet changed the view

It should not. Snapshot and delta application validate into temporary native
state and commit only on success. Preserve the bytes, API/protocol/algorithm
versions, and returned status as a defect report; meanwhile continue using the
last good projection or fail closed according to the consumer.

## Useful diagnostic snapshot

When reporting an integration issue, capture values—not the whole canonical
target list. This authority-side helper uses `get_projection()`. For a replica,
call `get_replica_projection()` instead and take the observer ID from the
returned view:

```gdscript
func vision_diagnostic(world: CommonVisionWorld2D, observer_id: int) -> Dictionary:
	var projection: Dictionary = world.get_projection(observer_id)
	return {
		"api": CommonVisionVersion.get_api_version(),
		"protocol": CommonVisionVersion.get_protocol_version(),
		"algorithm": CommonVisionVersion.get_algorithm_contract_version(),
		"scale": CommonVisionVersion.get_coordinate_scale(),
		"projection_status": {
			"ok": projection.get("ok", false),
			"code": projection.get("code", 0),
			"diagnostic": projection.get("diagnostic", 0),
			"detail": projection.get("detail", 0),
		},
		"observer_id": projection.get("observer_id", observer_id),
		"world_revision": projection.get("world_revision", 0),
		"geometry_revision": projection.get("geometry_revision", 0),
		"observer_revision": projection.get("observer_revision", 0),
		"result_revision": projection.get("result_revision", 0),
		"completed_tick": projection.get("completed_tick", 0),
		"work_units": projection.get("work_units", 0),
		"record_count": (projection.get("records", []) as Array).size(),
	}
```

Avoid logging recipient records in production unless your privacy policy allows
it; they can contain target IDs and last-known positions.
