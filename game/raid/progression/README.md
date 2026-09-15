# Task 7 — raid progression and recoverable settlement

This workstream is stacked on the validated combat branch, not on an assumed
merge into main. It composes existing RaidAuthority, ProfileStore, Inventory,
Health, movement/interaction and the installed native Level Task bridge. It
adds no second clock, inventory authority implementation, or save-file format.

## Lifecycle and write boundaries

| State / boundary | Trigger and effect | Retry / cancellation |
| --- | --- | --- |
| Selected profile | Root chooses an immutable generation containing native `zerkov.inventory.loadout` and `zerkov.inventory.stash` records. | Wrong generation, malformed records or another active raid reject before deployment. |
| Deployment committed | `RaidSettlementService.deploy()` reserves unique raid/settlement IDs and records active escrow in one ProfileStore CAS write. | Same request returns the original identity; it never authorizes a second live instance. A completed request cannot deploy again. |
| Preparing | `RaidDeployment.begin()` instantiates the verified native records, then SessionCoordinator/RaidAuthority. The session scope includes the raid identity. | Partial startup leaves the recorded deployment recoverable; there is no invisible loadout recreation or fallback item seed. |
| Active | Root finishes combat, movement, interaction and task composition, then activates existing RaidAuthority. | Stale actors, generations and phases remain subject to existing admission. |
| Extracting | All three distinct crate searches completed, current native inventory holds the supply crate, actor is inside the authored Road Gate, and a start intent is admitted. | Damage, leaving the zone, losing eligibility or explicit cancel stops the countdown. Re-entry requires a new start. |
| Terminal pending | After health commits, canonical tick policy chooses death before timeout before extraction completion. | Exactly one terminal decision; no further gameplay ticks. |
| Settling | Root calls `after_tick()` outside phase dispatch, releases other owners in order, then `finish()`. Combat flushes reservations and weapon state before capture. | A failed write remains SETTLING. Retry does not replay combat or regenerate equipment. |
| Prepared | Native inventory plan and outcome receipt are stored with a pending loadout domain. | Not a final summary. Restart replays this plan, not a new calculation from UI state. |
| Committed | One ProfileStore CAS replaces loadout and persists task result, health consequences and raid history together. | Same settlement returns the stored receipt with no second item/reward mutation. |
| Completed / summary | Controller records the settlement reference, releases its handlers, then terminalizes the raid. `RaidSummaryView` reads only the committed receipt. | Reopening or repeating finish cannot change the result. |

`after_tick()` is mandatory after every successful `advance_one()`. The next
progression phase rejects a missing closeout. UI snapshots publish only after
that closeout; a later failed phase cannot expose a new clock/result as committed.
The weapon-context phase guard is untouched: progression reads the local
movement owner's already-published same-tick snapshot instead.

## Root composition

The production root supplies a ProfileStore configured with the fixed production
adapter, a validated profile generation, and a stable user deployment request ID.
`RaidDeployment.begin(parent, store, request_id, generation, seed)` persists first
and exposes `raid`, `inventory`, and `settlement` only after preparation succeeds.
Then construct the existing combat roster and single interaction-policy owner.

```gdscript
var progression := RaidProgression.new()
var ok := progression.bind(raid, inventory, combat, interaction_policy,
    crate_inventory_ids, raid_limit_ticks, extraction_ticks, player_movement)
# Handle failure before enabling input; do not assert-and-continue in production.
```

`crate_inventory_ids` maps the three authored Sawmill objective-marker IDs to
three different native world-crate inventory IDs. Reuse the task-3 target index
and occluder bake. Player movement is the exact local actor's existing owner,
not a position from presentation. Use one `RaidGameplayInput` (a subclass of the
combat encoder) for movement, combat and progression to preserve one sequence
allocator per actor/source. Interaction payloads name only the supported target;
`raid_cancel` has no payload. Existing CommonUI/context filtering remains owned
by the input root. This PR does not install a parallel physical input poller.

Use `progression.raid_view()` for the existing typed RaidView. It contains the
canonical timer and extraction state; combine it with confirmed combat data at
the established presentation boundary. `RaidSummaryView.from_committed()` returns
null before settlement and an immutable value projection afterward. It does not
open a route or fabricate an unavailable monetary valuation.

## Native Supply Run and discovery

The packaged Level Task README describes an older bridge. The installed native
`LevelTaskRuntimeBridge` supports compile/start, typed facts, event injection,
step, explicit request acknowledge/reject, summary and trace. The authored graph
uses accept -> three event objectives -> all-gate -> extraction request -> reward
request -> success, with a native failure objective. The host acknowledges only
verified game-owned transitions. The reward is a persisted completion token;
no unconfigured money, experience or loot is minted.

The task host sees typed facts and committed audit events, never inventory,
health or scene objects. Distinct crate searches are deduplicated. Supply-item
eligibility is refreshed from the authoritative inventory snapshot every tick;
a remembered pickup cannot authorize extraction after the item is lost.

Search uses native Inventory discovery: a complete crate search requires the
sealed 900 ms. Consecutive 60 Hz ticks contribute differences of integer cumulative
milliseconds, not render delta. Range/occlusion and cancellation use the existing
interaction owner. Searching does not transfer loot. Actual item transfer stays
with the existing inventory intent/authority path. There is no client "reveal"
or "complete objective" operation.

No native Level Task snapshot/restore surface was verified. Persistent mid-raid
resume is therefore disabled, not emulated by replaying arbitrary UI/task state.

## Outcome and persistence policy

Extraction preserves the complete native loadout record, including item-owned
components and nested state. Death/timeout applies one native settlement plan:
items rooted in the secure container retain their ownership subtree; other root
items and their subtrees leave the profile. Root equipment is not protected merely
because it is equipped. The native inventory core validates the complete batch;
there are no manual item-removal loops editing snapshots.

A crash before preparing settlement is `abandoned`: apply loss to the persisted
**deployment escrow**, not an unrecorded mid-raid inventory or fabricated duration.
Initially secured items remain; uncommitted acquired loot is not restored. A
prepared settlement instead recovers its exact saved plan. This policy makes the
deployment commit the equipment-at-risk boundary, including interrupted loading.

Terminal health, body-zone injuries, task outcome, statistics, retained/lost item
groups, stable IDs and audit digest are in the same committed receipt. The audit
digest covers the journal through terminal selection; the subsequent settlement
reference is not included recursively in its own digest. Unknown value/currency
catalogs are reported as unavailable, with no invented valuation or rewards.

Health consequences are persisted as `project.last_raid_health` and in the receipt.
This does **not** rehydrate a live GAS actor for the next raid. Between-raid health
restoration/reset and its normal-launch wiring remain an explicit integration
boundary; do not treat a stored health summary as a restored component. Normal
Bunker-to-raid and summary-route binding are also not supplied by headless tests.

ProfileStore remains the only storage implementation. Active profile generations
and escrow checksums cannot silently drift. Malformed semantic state is rejected
even when the outer ProfileStore checksum is valid. History is bounded to 128
receipts; capacity rejects before a new deployment rather than evicting dedup
history. Existing codec/native inventory bounds still apply; storage migration
and account-scale history are not part of this first-playable slice.

There is no claim of interprocess multi-writer locking or power-loss durability:
the inherited file adapter flushes files and performs same-directory replacement,
but Godot provides no directory-fsync guarantee. The process-restart contract tests
actual files under a runner-generated isolated namespace, never a user's profile.

## Verification

```sh
python3 tests/tooling/test_raid_progression_runner.py
python3 tests/tooling/test_ui_first_playable_scope.py
python3 tools/check_first_playable_1080.py
python3 tools/run_raid_progression_contracts.py --godot "$ZERKOV_GODOT"
python3 tools/run_raid_progression_contracts.py --godot "$ZERKOV_GODOT" --native
```

Both runner modes import temporary copies. Pure mode uses the real ProfileStore
and codec with explicitly named fake filesystem/inventory ports, covering all
three write checkpoints, failures before/after replacement, duplicate receipts,
malformed state, countdown precedence and immutable summaries. Native mode adds
real task graphs, native inventory retention, combat-backed health, actual timed
discovery, interaction policy, extraction and settlement. The restart contract
uses three distinct Godot processes plus isolated cleanup. Missing native classes,
script errors, timeout or a missing zero-failure marker is a failure, not a skip.

Native fixture placements use the movement owner's placement API; they are not
an input-driven Sawmill traversal or graphical playtest. Test-only inventory seeds
are confined to contracts. The normal root never seeds a loadout. No task checkbox
is promoted solely from these component tests; final-head results and limitations
belong in the PR review record. The CI workflow is read-only and never pushes code.
