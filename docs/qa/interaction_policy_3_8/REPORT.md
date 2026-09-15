# Task 3.8 — bounded proximity/line interaction policy

Bounded proximity/line policy for doors, crates, corpses, healing targets and
extraction zones. Exact 1920x1080 headless verification only.

## Provenance note

The implementation under `game/raid/interaction/` was produced across two
executor attempts that were each terminated by provider rate limits **before
writing a single test**. The seven modules therefore reached this gate having
never been executed. The contract and gate driver in this report were authored
afterwards against the already-written API, and the implementation was verified
for the first time here.

Because "untested code passed on the first run" is a claim that deserves
evidence rather than trust, the gate itself was mutation-tested (below) to
prove it can fail.

## Verification

Engine: `/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`
(`4.7.2.stable.official.ed1daf0bf`).

```sh
export GODOT_BIN=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
python3 tests/tooling/run_interaction_policy_headless_gate.py
```

```text
--- Interaction Policy contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

INTERACTION_POLICY_RESULT checks=164 failures=0
--- Interaction Policy contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

INTERACTION_POLICY_RESULT checks=164 failures=0
INTERACTION_POLICY_HEADLESS_GATE runs=2 checks=328 failures=0 diagnostics=0
```

## Gate mutation tests

Each mutation was applied to `game/raid/interaction/z_interaction_policy.gd`,
the contract re-run, and the source restored byte-identical afterwards.

| Mutation | Gate response |
| --- | --- |
| `CRATE_RANGE_WORLD_UNITS` 1.25 -> 1.30 | `failures=1` — `crate range is 1.25 world units in micro` |
| vegetation mask made to block physical reach | `failures=1` — `vegetation-only occluder does not block physical reach` |
| heal eligibility drops the `injured` requirement | `failures=2` — incl. `heal target fails closed when not injured` |

Restored source confirmed clean, gate re-run green at `checks=328 failures=0
diagnostics=0`.

## Coverage

- **Per-kind ranges, not one global radius.** Door 1.5, crate 1.25, corpse 1.5,
  heal target 2.0 world units; extraction zone declares `NO_RANGE_MICRO`.
- **Exact integer boundaries.** Every point-kind case is driven through
  `evaluate_micro` with canonical microunits, so "allowed at the authored
  boundary" and "denied one microunit beyond" are true integer boundary tests
  with no float rounding in the call. Each denial reports the real resolved
  distance.
- **Extraction is containment, not radius.** Inside/outside `zone_cells`
  checked against the real Road Gate authoring `Rect2i(36, 9, 3, 3)`. An
  adjacent-but-outside actor is denied while nearer than one world unit,
  proving containment rather than distance produced the denial.
- **Line of interaction.** A structure segment between actor and crate denies
  with `line_blocked`; vegetation-only segments do not block physical reach; a
  segment contributed by the target itself does not block reaching it; a
  degenerate segment is inert. Range is evaluated before line, so a far *and*
  blocked target reports `out_of_range`.
- **Eligibility defaults.** Door unlocked, crate/corpse lootable, extraction
  open, heal target fails closed (alive but not injured by default).
- **Identity.** Unknown id, empty id and wrong-kind requests each denied with
  their own reason; wrong-kind reports the target's real kind.
- **Determinism.** Eight repeated evaluations are identical and bit-identical
  by `ZCanonicalValue.sha256` digest; allow and denial digests differ.
- **Authored layout index.** `ZInteractionTargetIndex` resolves the three
  objective crates, service cache, corpse and Road Gate extract from task 3.11
  markers, plus both authored `role == "gate"` structures as doors. Spawn,
  patrol and encounter markers are correctly not interactable. Rebuilding
  yields identical digests; a null layout fails closed as `layout_missing`.
- **Generation and phase.** The owner registers an `INTERACTIONS_AND_WEAPONS`
  handler under a stable id. Stale-generation upsert, remove and movement-world
  attach are all rejected and mutate nothing; an invalid target state is
  refused; an actor with no authoritative pose is denied `actor_unknown`
  (presentation cannot grant reach); evaluation after teardown is denied.

## No regression

```text
MOVEMENT_AUTHORITY_HEADLESS_GATE runs=2 checks=1078 failures=0 diagnostics=0
OCCLUDER_BAKE_HEADLESS_GATE      runs=2 checks=528  failures=0 diagnostics=0
WORLD_MARKERS_HEADLESS_GATE      runs=2 checks=612  failures=0 diagnostics=0
```

## Remaining risks

- Eligibility predicates are injected flags with documented defaults because
  their owning authorities do not exist yet in the first playable: no door-lock
  authority, no container-emptied tracking, no health/injury authority, no
  objective gating for extraction. This task deliberately did not invent them.
  Wiring each real owner is later-task work, and until then a caller supplying
  no context gets the documented default.
- `heal_target` entries are never produced by `ZInteractionTargetIndex` because
  they name a live actor rather than static layout data; callers add them via
  `upsert_target`.
- Doors are derived from Obstacles-layer `role == "gate"` structures; there is
  no dedicated door marker resource and this task did not add one.
- The policy is a pure evaluator. Nothing here performs the interaction itself;
  executing an accepted interaction is later-task work.
