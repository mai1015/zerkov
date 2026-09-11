# Authoritative Vision world

Task 6.1 owns only the Common Vision world configuration and its deterministic
tick/budget driver. `RaidVisionWorldOwner` retains one `OFFLINE_AUTHORITY`
`CommonVisionWorld2D` solely as inaccessible lexical state in an opaque
Callable. No owner Object/Resource property retains the native node, and the
Callable never returns it. `NOTIFICATION_PREDELETE` invalidates the shared
lexical state synchronously even when a configured owner was never placed in a
scene tree.

`RaidAuthority` owns one reserved phase-3 (`VISION`) slot. Generic handler
registration rejects that identity and cannot exhaust its reserved capacity;
the typed owner API derives the callback
instead of accepting a caller-supplied ID or Callable. Registration, dispatch,
and release authenticate the exact checked-in base-script owner object plus
owner/raid generations; configured subclasses cannot claim the production slot.
Direct, forged, and replayed callbacks—including calls through a reflectively
retained opaque Callable—are inert. The owner has no `_process()`, delta-time
API, or public direct-tick driver.

Owner release has two deliberately different contracts. Explicit teardown is
fail-atomic: while a PREPARING consumer depends on the reserved slot, rejection
leaves the owner, native runtime, slot, and dependency graph unchanged. Object
destruction cannot obey that contract because `NOTIFICATION_PREDELETE` must
finish. A dependency-free PREPARING destruction releases the slot for a fresh
owner; otherwise an exact predelete-only proof makes `RaidAuthority` enter
`FAILED`, synchronously seal the native runtime, and clear the reserved slot
and every dependent handler together. If destruction occurs inside a tick,
the already-consumed tick is finalized as failed and no later callback runs.

`ZerkovVisionConfig` seals the complete configuration as SHA-256
`3ead6e826bfd2552aa1396a4d266de3603524355c56620033cb1bd84b6df58f3`.
Startup fails closed if the record, project add-on lock, installed artifact
hashes, API `0.1.0`, protocol `1`, algorithm contract `1`, required feature
bits, Common Vision scale, `ZWorldUnits` scale, or 60 Hz `RaidClock` differs.
The accepted-record fingerprint covers the locked Git head, release revision,
source repository/package paths, package dirty state/count/tree digest,
manifest schema/digest, integration flags, and each artifact's platform,
architecture, build, status, digest, manifest digest, and manifest-match
label. Unknown fields and selected-field Dictionary replacements are rejected;
the returned fingerprint hashes the complete normalized accepted record. The
lock is authoritative for the project's locally rebuilt artifacts; the
upstream release manifest remains pinned and hash-checked as provenance.

## Fixed first-playable values

- One world unit is one 32 px tile and exactly 1,000,000 Vision microunits.
- Shared `ZWorldUnits` scalar conversions retain their accepted symmetric
  `+/-1,048,576 px` (`+/-32,768,000,000` raw) domain for weapon, tile, and
  inventory contracts. Vision point conversions use the narrower exact
  `+/-65,536 px` (`+/-2,048,000,000` raw) boundary required before
  `Vector2i` construction. One pixel/raw unit outside the Vision point bound is
  rejected without wrap or partial conversion.
- The target grid uses four-tile cells and rejects a query rectangle above 256
  visited cells. The 18-tile maximum authored range occupies at most 121 cells
  at an adverse cell boundary.
- Vision evaluates on authority ticks `1, 4, 7, ...` (20 Hz). Intervening 60 Hz
  raid ticks request zero native work and retain the last complete projection.
- Each evaluation supplies exactly 16,384 work units to the add-on scheduler.
  With the three-sample actor profile and 128 authored segments, 42 matching
  targets conservatively request 16,170 units and fit; 43 request 16,555 and
  deterministically defer as one whole observer. This is an admission bound,
  not a promised NPC/content count or a substitute for task 3.10's segment
  budget validation.
- Telemetry retains 64 evaluation records (3.2 seconds at 20 Hz), contains no
  recipient records, and saturates cumulative counters rather than wrapping.
  A native whole-call failure records the attempted tick and exact bounded
  metric prefix, quarantines the owner, synchronously destroys native state,
  and permits only teardown followed by a fresh owner/generation.
- Scav sight is 18 tiles, a 120-degree total cone, and 180 memory ticks (three
  seconds). Mutant sight is 12 tiles, a 160-degree total cone, and 120 memory
  ticks (two seconds). Memory expiry follows Common Vision's exact rule:
  `current_tick - last_seen_tick > memory_ticks`, evaluated only on a completed
  cadence query.
- Actor targets use `ANY_SAMPLE` with center and vertical quarter-tile samples
  (`0`, `-250,000`, `+250,000` microunits). Three samples stay below the native
  cap of eight while permitting partial-cover sight checks.
- Player, Scav, and mutant target masks are bits 0, 1, and 2. Structure and
  vegetation occluders are bits 0 and 1 in the separate occluder-mask domain.

The production owner exposes no observer, target, occluder, transform, or
projection operation. Native fixtures in the focused contract are isolated
under `tests/` and cannot exist in a normally configured production owner.
Task 6.2 remains responsible for the concrete capability and real actor
identity, registration/update/removal lifecycle, transform revisions, and
liveness. Task 6.3 owns the AI-facing projection adapter. Hearing/noise, AI
behavior, Sawmill occluder authoring, UI/debug overlays, and shared bootstrap
composition are not part of this owner.

Run the focused contract with the pinned Godot executable:

```sh
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
  --headless --path . --audio-driver Dummy \
  --script res://tests/ai/vision_world_contract.gd
```
