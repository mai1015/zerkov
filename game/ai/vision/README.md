# Authoritative Vision world

Task 6.1 owns only the Common Vision world configuration and its deterministic
tick/budget driver. `RaidVisionWorldOwner` creates one scene-owned
`OFFLINE_AUTHORITY` `CommonVisionWorld2D`, verifies the pinned package and
native artifacts, and registers its optional handler in `RaidAuthority` phase
3 (`VISION`). It has no `_process()` or delta-time API.

`ZerkovVisionConfig` seals the complete configuration as SHA-256
`9a1bf1980b873fd71bcc864dc9e4f5fc32325597ed49e419e14f9167c0122ed2`.
Startup fails closed if the record, project add-on lock, installed artifact
hashes, API `0.1.0`, protocol `1`, algorithm contract `1`, required feature
bits, Common Vision scale, `ZWorldUnits` scale, or 60 Hz `RaidClock` differs.
The lock is authoritative for the project's locally rebuilt artifacts; the
upstream release manifest remains pinned and is hash-checked as provenance.

## Fixed first-playable values

- One world unit is one 32 px tile and exactly 1,000,000 Vision microunits.
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

Task 6.2 remains responsible for registering, revision-updating, and removing
real observers and targets from authoritative transforms. Task 6.3 owns the
AI-facing projection adapter. Hearing/noise, AI behavior, Sawmill occluder
authoring, UI/debug overlays, and shared bootstrap composition are not part of
this owner.

Run the focused contract with the pinned Godot executable:

```sh
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
  --headless --path . --audio-driver Dummy \
  --script res://tests/ai/vision_world_contract.gd
```
