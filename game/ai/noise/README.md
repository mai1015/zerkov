# Raid hearing (task 6.7)

`RaidNoiseService` is a game-owned, synchronous hearing service. It has no
Vision, audio-server, UI, navigation, behavior-tree, or native-extension dependency.
It accepts only committed gameplay events from its trusted raid owner; calling
`record_committed` is not proof that an action was authorized. Never pass the
service itself to UI, remote peers, or an individual AI. Give each AI only its
resolved observations.

## Integration contract

1. The raid composition creates one service and calls `configure` with the
   canonical `ZRaidId` string and current authority generation.
2. After each committed gunshot, impact, sprint noise, or interaction, its
   game-owned producer calls `record_committed` with the canonical consequence
   and source entity keys, tick, captured authoritative position, category,
   intensity (1..1000), and `radial_distance_v1` policy. Convert positions through
   `ZWorldUnits.godot_to_canonical` and check the conversion result first.
3. Once per tick, after consequences/due work and before publication, the owner
   calls `resolve_tick` in `TASKS_AND_AUDIT`. Pass all currently eligible
   listeners as `{entity_id: String, position_raw: Vector2i,
   minimum_strength_milli: int}`. Empty ticks must also be resolved.
4. During tick T+1 AI decisions, obtain `observations_for(generation, actor_key,
   T+1)` from the completed tick T. Do not invoke the service on render frames.
5. Release the owner during raid teardown. A new raid needs a new service.
   All rejected operations return false/empty with `last_error`; production
   composition must handle failures, not silently drop authoritative noise.

Facts contain the event's time, category, received strength, propagation policy,
raid/generation, one-decision-tick validity, and a historical one-world-unit
origin region. They never include the source identity, exact origin, live target
handle, health, velocity, or a visual confirmation. Facts and arrays are
read-only. Retained values are historical; AI memory belongs to task 6.4.

## Initial policy and limits

Squared-distance falloff uses integer arithmetic. Maximum radii are 24 world
units for gunshots, 8 for impacts, 6 for sprinting, and 3 for interactions.
These are initial tuning values, not accepted acoustics. This explicit radial
policy ignores walls; it does not reuse visual occlusion or claim wall/portal
propagation. Local cosmetic audio creates no event by itself.

There are at most 64 events and 64 listeners per tick (4096 pair evaluations),
and 8192 lifetime event fingerprints. Identities are deduplicated for the raid:
exact retries succeed without re-emitting; conflicting reuse fails. Capacity
exhaustion fails explicitly and never evicts deduplication records. Resolution
orders events/listeners by stable identity, expires the prior frame, and
validates the full listener batch before consuming a tick. Opposite coordinate
extremes are subtracted as 64-bit scalars rather than overflowing Vector2i.

## Verification and remaining work

Run `godot --headless --path . --script res://tests/ai/noise_service_contract.gd`
after project import. Require `NOISE_SERVICE_RESULT` with zero failures and
clean diagnostics. The focused contract runs without native add-ons when these
files and the unchanged `ZIdentityRules`, `ZWorldUnits`, and `ZUnitConversion`
dependencies are placed in an isolated Godot project.

The service and its contract are implemented. Production event-producer hooks,
raid phase registration, and consumption by actual Scav/mutant decisions remain
integration work; no task checkbox is changed. No task 3 files, shared bootstrap,
existing authority, addon lock, or UI file is modified by this component.
