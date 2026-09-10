# Task 4.9 independent Astra checkpoint gate — REJECT

Reviewed on 2026-09-10 against parent checkpoint 0f102f7 and the seven untracked production/test files in reviewed_hashes.json. Validator: fresh GPT-6 Astra. Human approval: **false**. No production code, promoted test code, add-on source, spec, task ledger, or commit was changed by this validator.

The serialized loose-ammunition reload flow passes, but task 4.9 cannot be accepted because the canonical AKM magazine cannot materialize its provided ammunition container. The implementation explicitly prioritizes that container as a reload source; it is currently unreachable through the real approved catalog.

## Blocking finding

**P1 — the magazine source path is unusable with the canonical catalog.**

game/content/zerkov_inventory_catalog.gd:337 creates the ordered-list magazine container with default allow_nesting=false and max_nesting_depth=0. Native provider materialization (addons/inventory_system/native/core/inv_runtime_state.cpp:681) requires the provided container at child depth 1. Consequently, inserting one zerkov.item.magazine.akm_30 at (0,0) in an empty player backpack returns accepted=false with status code=6, diagnostic=115, detail=1.

Diagnostic 115 is NESTING_DEPTH_EXCEEDED. Inventory revision stays 0 and no magazine ammunition container is created. This is a pre-existing catalog integration defect exposed by the new reload source policy, not ammunition duplication in the passing loose-ammo path. InventoryWeaponAdapter.AKM_CONTAINER_PRIORITY promises the magazine source first, and task 4.9 explicitly covers ammunition/magazine reservation. The lack of physical magazine-object swapping is an accepted limitation; inability to create or consume ammunition from the declared magazine container is a different issue.

Minimal reproduction: magazine_probe.gd, magazine_probe.log, magazine_probe_results.json, magazine_run.json. Result: **5 checks, 2 failures**. Repair must enable canonical magazine materialization and then prove actual magazine-contained source selection, reservation isolation, commit/cancel, and conservation. Do not weaken the test to a custom catalog or relabel this source branch as tested.

## Executed evidence

All executions used /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot (4.7.2.stable.official.ed1daf0bf).

| Current evidence | Checks | Failures |
| --- | ---: | ---: |
| Promoted reload contract | 148 | 0 |
| Inventory authority | 79 | 0 |
| Inventory catalog | 504 | 0 |
| Equipped-item reconciliation | 123 | 0 |
| Combat content | 79 | 0 |
| Session lifecycle | 44 | 0 |
| Authority replay | 81 | 0 |
| Identity | 18,442 | 0 |
| Inventory intent adapter | 162 | 0 |
| Inventory mutation routing | 146 | 0 |
| Inventory projection | 99 | 0 |
| Combined add-on smoke | 155 | 0 |
| **Baseline suite subtotal** | **20,062** | **0** |
| Independent real-add-on headless flow | 1,310 | 0 |
| Same flow in native Compatibility window, plus capture checks | 1,312 | 0 |
| Minimal real-magazine integration probe | 5 | 2 |

The headless/native flow executions share assertions and must not be presented as independent test breadth. Raw assertions across current variants total 22,689 / 2. Clean editor import and git diff --check pass. Named result lines, exit codes and diagnostic scans are recorded in the runner JSON files.

## Continuous real-add-on flow/playthrough

The validator independently authored flow_playthrough.gd; it does not call or subclass the promoted test. It creates a trusted admission, real InventoryAuthority with equipped AKM, real sealed WeaponAuthority, and the actual reload port/adapter. The successful fixture uses **45 loose rounds** (two rig stacks and one pocket stack) plus 6 initially loaded rounds. It intentionally makes no successful magazine-container claim.

| Step | Tick | Inventory rounds | Loaded | Total | Inventory / weapon revision | Holds |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Initial equipped AKM | 0 | 45 | 6 | 51 | 4 / 0 | 0 |
| Reserve and begin | 10 | 45 | 6 | 51 | 4 / 1 | 1 |
| Before due | 81 | 45 | 6 | 51 | 4 / 1 | 1 |
| Cancel ordered at due tick | 82 | 45 | 6 | 51 | 4 / 2 | 0 |
| Reserve again | 83 | 45 | 6 | 51 | 4 / 3 | 1 |
| Unrelated accepted inventory mutation | 84 | 45 | 6 | 51 | 5 / 3 | 1 |
| Due commit | 155 | 21 | 30 | 51 | 6 / 4 | 0 |
| Original request replay and late sweep | 156 | 21 | 30 | 51 | 6 / 4 | 0 |

Every recorded step asserts exact state and conservation. Native reservation stages are HELD=1, RELEASED=3, PUBLISHED=4. Held ammunition removal is rejected. At inventory publication, observers see both committed domains. Completion notifications are exactly inventory -> weapon; recursive publish_reload replays the terminal record without a second signal. Adapter mutation during publication is rejected. Successful teardown leaves no hold or pending record.

The independent adversarial cases also pass: death, equipment swap and explicit adapter teardown at the exact due tick; exact native external cancellation proof; externally loaded weapon quarantine; cleared and replaced port with live hold; forged syntactically valid IDs backed by a real native weapon; synchronous owner teardown during a rejected begin; 300 malformed requests during an active pinned receipt; 270 repeated real begin/cancel cycles; evicted old request replay rejected by current revision.

The separate out-of-band completion fixture deliberately violates the single-writer contract. It proves conservation of *spendable* ammunition while quarantined: 45 inventory - 24 held + 30 loaded = 51 initial. The held reservation remains associated with the recovery record, and new reload, death refund and ordinary release are blocked. The fixture is disposed through owner teardown. This demonstrates fail-stop quarantine, not a production recovery or restart workflow.

## Native visual evidence

[Native ordered timeline](native_flow_1280x720.png) is an actual native Compatibility viewport capture, inspected by this validator. It displays the eight ordered states above, aligned columns, conserved totals, quarantine accounting, and explicit **VALIDATION HARNESS / NOT PRODUCTION UI** disclosure. It is readable at 1280x720 and has no clipped rows or columns. This single-frame ordered timeline is the compact evidence sheet; machine assertions remain the authority. It is not gameplay presentation, combat-feel approval, input routing, or a human playtest.

## Native capability and limits

native_api.json records the installed binary's callable reload methods and confirms **no public weapon rollback method**. Source inspection confirms:

- Inventory prepare holds without decrement/revision; silent commit decrements with one revision; rollback restores the immediate predecessor only while unpublished and at the expected successor revision; publish finalizes before notifications.
- Weapon commit_due_reload performs internal prepare/commit/publish before returning and emits no completion signal. Its public publish_reload_completion is a notification method only.
- The actual supported scope remains synchronous in-memory offline single-writer/no-yield coordination. It is not crash/restart-safe symmetric two-phase commit. Weapon lifecycle task 5.2, input task 5.7, human gates, whole-game completion and release gates remain open.

## Integrity, diagnostics and footprint

reviewed_hashes.json names the exact seven reviewed files. dependency_hashes.json covers catalog, native semantics, the installed macOS debug binaries and pinned Godot. packet_hashes.sha256 seals this packet. gate_result.json records final source-hash verification, current-log diagnostics, diff check, and process cleanup.

Passing current suites and both successful continuous flow runs contain no ERROR, SCRIPT ERROR, assertion, stack-overflow, ObjectDB/RID/resource/font leak diagnostics. The minimal magazine probe intentionally emits the two blocking assertion errors. Earlier authoring attempts are retained under authoring_history: one harness syntax error, a broad magazine fixture whose dependent expectations necessarily failed after provider rejection, and earlier evidence reruns. They are not included in current acceptance totals and do not supersede the isolated blocker.

No validator-owned Godot process remains. Unrelated PID 49133 was left untouched. Editor import generated an untracked tests/raid/inventory_weapon_reload_contract.gd.uid; no hand-authored production/promoted-test edits were made. The gate remains **REJECT** pending the magazine integration repair and a fresh independent checkpoint validation.
