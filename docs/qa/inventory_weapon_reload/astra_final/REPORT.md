# Task 4.9 fresh independent Astra checkpoint — ACCEPT

Historical evidence notice: every runner, generator, independent probe, and
command named in this retained packet is disabled for current use. The entry
points fail closed before setup or writes. Use the current promoted contract
documented in the parent README; do not rerun or regenerate this packet before
task 11.8 or a later approved display-support proposal.

**ACCEPT FOR DOCS/STAGING. Human approval: false.**

Reviewed 2026-09-10 against parent commit
`0f102f75d9c53ab54f04314f75d2cfc5d2a76e1b`. The current task 4.9 surface passes
the independent real-addon flow, canonical magazine capacity challenge, native
capture review, promoted tests, related regressions, and integrity checks.
This validator changed only this new `astra_final` QA packet. No production,
promoted test, add-on, spec ledger, task checkbox, staging, or commit was changed.

## Review scope and outcome

The approved proposal, full design, task ledger and inventory-equipment
Atomic Reload Reservation requirement were read, together with the earlier
[REJECT report](../astra_gate/REPORT.md). All ten current production/test/UID
files in [reviewed_hashes.json](reviewed_hashes.json) were inspected. The relevant
InventoryAuthority and WeaponAuthority public facades, native quantity
participant, provider materialization, weapon completion implementation,
content configuration, and inventory owner were also inspected. CodeGraph was
unavailable and uninitialized; no index was created.

The earlier diagnostic 115 blocker is resolved. The canonical AKM magazine now
creates its child list at depth one. The catalog bounds that list to one stack
and 489000 mg, exactly 30 of the only compatible ammunition definition at
16300 mg each. The independent fixture uses the unchanged canonical catalog
and real native authorities. It never imports, invokes, or subclasses a
promoted test.

The coordinator preserves exact held item identities, permits an unrelated
accepted inventory revision, commits inventory silently before the weapon,
and publishes inventory then weapon only after both canonical states agree.
The port caches its terminal publication state before calling signal listeners,
so recursive publication replays the receipt with one completion signal.
No blocking finding remains within this checkpoint's stated scope.

## Executed gates

Every Godot execution used exactly
`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`, version
`4.7.2.stable.official.ed1daf0bf`. No validator command invoked the Homebrew
Godot. All current runs exited 0 and passed a diagnostic scan; none had an
assertion, ERROR, SCRIPT ERROR, stack overflow, RID/ObjectDB/resource/font leak,
warning, timeout, or unexplained hang.

| Gate | Checks | Failures |
| --- | ---: | ---: |
| Promoted inventory catalog | 537 | 0 |
| Promoted inventory weapon reload | 159 | 0 |
| Inventory authority | 79 | 0 |
| Identity | 18442 | 0 |
| Equipped-item reconciliation | 123 | 0 |
| Combat content | 79 | 0 |
| Session lifecycle | 44 | 0 |
| Authority replay | 81 | 0 |
| Units and clock | 29 | 0 |
| Inventory projection | 99 | 0 |
| Inventory intent adapter | 162 | 0 |
| Inventory mutation routing | 146 | 0 |
| Inventory UI binding | 138 | 0 |
| Inventory multi-controller | 23 | 0 |
| Combined add-on smoke | 155 | 0 |
| **15-suite subtotal** | **20296** | **0** |
| Independent canonical capacity challenge | 33 | 0 |
| Independent real-addon headless flow | 208 | 0 |
| Same flow in native Compatibility window | 213 | 0 |
| **Raw current assertions** | **20750** | **0** |

The headless/native flow runs repeat the same five scenarios and the same 208
core assertions. Native adds five window/renderer/capture checks. There are
**five unique independent real-addon flow cases, ten executions**, and one
eight-state continuous timeline executed twice. Across the whole packet there
are 17 distinct test programs and 18 test execution variants. Removing the
208 directly repeated native core assertions leaves 20542 assertion executions;
this is not a claim that every remaining assertion is a distinct invariant.

Clean editor import, strict spec validation, and `git diff --check` also pass.
The spec toolkit reports `valid: true`, with zero errors and warnings. These
three command gates add no assertion count.

Exact argument arrays, named result lines, exits, elapsed times, PIDs, timeout
status and diagnostics are recorded in [suites_suite.json](suites_suite.json),
[capacity_runner.json](capacity_runner.json), [flow_runner.json](flow_runner.json),
and [native_runner.json](native_runner.json). Each gate has its own raw log.
[run_validation.py](run_validation.py) records the former `capacity`, `flow`,
`native`, and `suites` command modes for historical provenance only. Those
modes are disabled, and the wrapper now terminates before imports or work.

## Continuous real-addon playthrough

[independent_flow.gd](independent_flow.gd) creates a trusted session admission,
canonical player raid InventoryAuthority, equipped AKM, actual magazine shell
and provided child list, 11 contained rounds, 8 loose rig rounds, and 19 pocket
rounds. The real sealed WeaponAuthority starts with 3 loaded rounds. The actual
WeaponAuthorityReloadPort and InventoryWeaponAdapter coordinate all reload work.

| State | Tick | Magazine / rig / pocket | Loaded | Holds / quantity | Inventory / weapon revision | Total |
| --- | ---: | --- | ---: | --- | --- | ---: |
| Initial equipped AKM | 0 | 11 / 8 / 19 | 3 | 0 / 0 | 5 / 0 | 41 |
| Reserve and begin | 17 | 11 / 8 / 19 | 3 | 1 / 27 | 5 / 1 | 41 |
| Before due | 88 | 11 / 8 / 19 | 3 | 1 / 27 | 5 / 1 | 41 |
| Cancellation ordered at due | 89 | 11 / 8 / 19 | 3 | 0 / 0 | 5 / 2 | 41 |
| Reserve again | 90 | 11 / 8 / 19 | 3 | 1 / 27 | 5 / 3 | 41 |
| Unrelated accepted bandage insertion | 91 | 11 / 8 / 19 | 3 | 1 / 27 | 6 / 3 | 41 |
| Due commit | 162 | 0 / 0 / 11 | 30 | 0 / 0 | 7 / 4 | 41 |
| Original request replay and late sweep | 4162 | 0 / 0 / 11 | 30 | 0 / 0 | 7 / 4 | 41 |

Both reservations assert exact source IDs, quantities and per-item native hold
generations in magazine -> rig -> pockets order: 11 + 8 + 8 = 27. Held source
removal rejects without canonical change. Due-tick cancellation returns native
RELEASED stage 3 and restores no synthetic state: original persistence bytes
were never changed. The second hold remains valid through the unrelated
inventory revision, and commit uses immediate predecessor 6 / successor 7.

At inventory publication, observers already see inventory `[0, 0, 11]`, loaded
30, total 41, and zero active holds. Weapon notification follows. A recursive
port publish call replays the published result; an adapter mutation from the
publication callback is rejected. The canonical magazine shell and its exact
empty child container remain. Replay and sweeps through the original TTL
horizon preserve both canonical states and revisions without another signal.

Three additional real-addon fixtures prove interruption at the exact due tick:
death, an actual native move of the equipped AKM followed by adapter equipment
validation, and explicit adapter teardown. All preserve each source quantity,
loaded ammunition and conservation, release the exact native reservation, and
leave no pending reload or hold. Due-tick ordering is driven by the harness;
production RaidAuthority integration and input routing remain later tasks.

The fifth fixture deliberately completes the weapon out of band through its
native API. The adapter detects the changed ready weapon and latches recovery.
It retains 27 HELD rounds and the exact transaction record. Spendable accounting
is **38 inventory - 27 held + 30 loaded = 41**. Death, a new reload, and ordinary
release cannot refund that hold. The fixture is then disposed through owner
teardown; this proves quarantine accounting, not a production recovery workflow.

Machine observations, ordered timelines, every assertion and publication
receipts are in [flow_results.json](flow_results.json) and
[native_results.json](native_results.json).

## Independent capacity challenge

[independent_capacity.gd](independent_capacity.gd) proves actual provider/root/
child ancestry at depth one, matching inventory and Weapon capacity 30,
and exact native mass capacity 489000 mg. A fresh 30-round insertion succeeds.
A separate fresh empty magazine rejects 31 rounds with **code 6, diagnostic 123,
detail 505300**, preserving revision, persistence bytes, item identities,
container identities, and the shell plus empty child topology.

A loose round cannot bypass the bound by merging into the full magazine:
the same diagnostic is returned and both stacks remain unchanged. A control
merge into a below-capacity magazine succeeds. The trait filter still rejects
a bandage with diagnostic 118; the one-stack limit still rejects a second
compatible stack below mass capacity with diagnostic 26. Both failures preserve
complete canonical state. [capacity_results.json](capacity_results.json)
contains all 33 passing checks and the exact native result dictionaries.

## Native evidence, integrity and limitations

[Native ordered timeline](native_timeline_1280x720.png) is an actual visible
macOS Compatibility framebuffer capture, 1280x720, visually inspected by this
validator. All eight rows and columns are readable without clipping. It is
prominently labeled **VALIDATION HARNESS / NOT PRODUCTION UI** and states that
this is an automated flow, not a human playtest. [visual_review.json](visual_review.json)
records the inspection and capture hash.

[gate_result.json](gate_result.json) records final checks and acceptance.
[dependency_hashes.json](dependency_hashes.json) identifies the facades, native
transaction semantics, game-owned dependencies, locks, loaded debug binaries,
and pinned engine. [addon_hashes.json](addon_hashes.json) covers all 849 tracked
add-on files. Final hashes match the pre-run source/dependency/add-on/spec
baseline; add-on git status and staging are empty; HEAD is unchanged; no
production `advance_tick` call exists. The earlier sealed REJECT packet remains
40 files including its manifest, with all 39 listed hashes verified before and
after this validation.

All validator-owned processes were reaped, as recorded in
[process_cleanup.json](process_cleanup.json). Other Godot processes on the
machine were left untouched. [packet_hashes.sha256](packet_hashes.sha256)
records the original accepted packet seal. Current retirement-safety overlays
intentionally differ from that historical seal and do not claim a reseal; the
manifest and its original verification log are excluded from their own seal.
The sole unsuccessful runner-authoring attempt used the wrong working
directory for the earlier manifest verification; its output and explanation
are preserved under [history](history/initial_runner_attempt.md), excluded from
accepted totals. It was not a product or Godot failure.

Acceptance is limited to offline, synchronous, in-memory, single-writer/no-yield
coordination. Inventory supports rollback of an unpublished immediate successor;
the installed Weapon facade closes its internal participant before returning
and exposes no public symmetric rollback. Crash/restart atomicity and completion
of a recovery workflow are excluded. Physical detachable-magazine weapon
identity/swapping is excluded; contained-ammunition consumption is proven.
This gate does not approve production UI/input, combat feel, a complete raid
loop, human playtest, multiplayer, Windows/Linux release, or later task gates.
The parent may now update documentation/task status and stage the reviewed
change; this validator made neither action and made no commit.
