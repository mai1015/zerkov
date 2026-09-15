# Combat integration repair and task 7 handoff

## Scope and diagnosis

The September 15, 2026 repair addresses game-owned boundary defects, not a
proven vendor-addon defect. The codec now admits the exact revision claims
consumed by the production executor: cancel reload requires weapon revision
plus reservation identity; melee requires the reconciler equipment revision.
Inventory revision is not an alias for equipment revision. Quick-heal payloads
from the production input binding now serialize zone and treatment as strings.

The stamina-spend ability already existed in the sealed health content. The
adapter newly required its grant. The regression therefore expects 37 grants
and explicitly checks exactly one live stamina-spend grant per fixture, rather
than altering the catalog or merely suppressing a count assertion.

## Executed native baseline

Commit: `645954ab9360d9610ac7c9ba5eed87849f05ea2f`.
GitHub Actions run: `34957820359` (Combat contracts, run 21).
Engine: `4.7.2.stable.official.ed1daf0bf`, read from the checked-in lock.
Platform: macOS runner with the actual checked-in native addons, no substitutes.
Both tooling and native jobs completed successfully. Raw diagnostics and exact
source hashes are retained as short-lived workflow artifacts.

| Contract | Checks / failures |
| --- | --- |
| Combat ingress replay | 3595 / 0, twice, identical digest |
| Native ingress | 60 / 0 |
| Melee/HUD value contract | 34 / 0 |
| Native execution | 439 / 0 |
| Four body-hitbox contracts combined | 370 / 0 |
| Weapon combat adapter | 368 / 0 |
| Health ability content | 392 / 0 |
| Health consequence adapter | 467 / 0 |
| Combat content | 80 / 0 |
| Weapon instance context | 308 / 0 |
| Inventory reload | 176 / 0 |
| Player locomotion | 166 / 0 |

The integrated execution contract actually reaches cancellation and melee. It
checks real reload quantities, firearm damage and cadence, stale weapon revision
and wrong reservation cancellation, valid cancellation, stale equipment melee,
wind-up without early damage, exact active/recovery ticks, one cost and one
contact, busy rejection, production quick-heal with stale-health and
stale-inventory rejection, real medical consumption, aim-away misses, duplicate
requests and confirmed HUD values. Test failure stops before cascading missing
request-ID accesses; a watchdog rejects incomplete execution.

A producer-only fixture deliberately diverges inventory and equipment revisions
to check which claim is serialized. This is not evidence of an actual in-game
equipment custody transition. Adjacent weapon/health contracts provide their
own scoped ownership, death, rollback and teardown regressions.

## CI and gate repair

The unsafe write-enabled `combat-branch-apply.yml` was deleted first in
`b2f04be3e36c78f5eacffdf341321f094d8bcdb9`. It is not replaced by another patch
application or auto-push channel. The remaining workflow has `contents: read`,
checks out the exact PR head, and does not persist checkout credentials.
This PR introduces CI relative to main; retaining that read-only workflow is
explicitly part of the merge review scope.

Both execution entrypoints are registered in the exact-1080 inventory. The
checker now independently discovers `tools/run_*_contracts.py`, with negative
controls for omitted execution tests and omitted launchers. Running the full
gate also found existing unclassified AI entrypoints. They are registered, the
AI launcher has an explicit 1920x1080 argument, and its synthetic diagnostic
writer uses the existing immediate fail-closed physical capture guard. No
resolution, hash, retirement or PNG-write checks are disabled.

The registry has 53 headless entrypoints; registration does not mean all 53 run
in the combat job. CI runs the selected combat matrix and adjacent AI matrix,
plus the registry checker and its negative controls. The synthetic AI image is
not native encounter, combat readability or performance acceptance evidence.

## Reproduce

```sh
python3 tests/tooling/test_combat_input_runner.py
python3 tests/tooling/test_ai_runner.py
python3 tests/tooling/test_ui_first_playable_scope.py
python3 tools/check_first_playable_1080.py
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT" --native --execution
python3 tools/run_ai_contracts.py --godot "$ZERKOV_GODOT" --native
```

Use the exact engine lock and a host with the shipped native libraries. On a
host without those libraries, isolated value/ingress tests are useful but do not
replace native execution. Native import failures and nonzero/missing contract
results are failures, not passing skips.

## Task 7 handoff and non-claims

The reported codec/executor blocker is resolved and the native combat baseline
supports beginning task 7 implementation after review. This is not a blanket
completion claim for all tasks 5.* or a full first-playable acceptance.

- Reuse `RaidAuthority` lifecycle/generation checks and its canonical clock for
  7.1/7.3 instead of adding parallel mutable state.
- For 7.2, build the prepared roster from an immutable profile generation and
  persist the raid/settlement identity before deployment. Do not use the test
  roster seed or generate fallback ammunition.
- For 7.4-7.7, connect ordered audit events to the raid task graph and extraction
  controller; preserve same-tick death, cancellation and exactly-once rules.
- For 7.8/7.10-7.13, settle canonical inventory and weapon state under the approved
  loss/retention policy. Release combat consumers without erasing externally
  owned inventories, and prove crash/relaunch behavior independently.

Normal-launch composition, concrete AI action handoff and durable settlement
are not supplied by these combat tests. Tasks 5.12 and 5.13 still need recorded
encounter tuning and blind human playtests; provisional readability targets
are not measured acceptance. The spec checkboxes remain subject to their full
review and evidence requirements. No merge or task 7 implementation is performed
by this repair.
