# Fresh Astra checkpoint: task 4.10

Historical evidence notice: every runner, generator, probe, and command named
in this retained packet is disabled for current use. The corresponding entry
points fail closed before imports, setup, subprocesses, paths, or writes. Use
the current promoted contract documented in the parent README; do not rerun or
regenerate this packet before task 11.8 or a later approved display-support
proposal.

Decision: **ACCEPT** for the exact frozen inventory-to-ability equipment
implementation reviewed on 2026-09-10. Human playtest approval remains **false**.
This packet authorizes the task checkpoint evidence; it does not claim production
UI/input integration, a complete raid loop, multiplayer or release acceptance.

The final machine gate is [gate_result.json](gate_result.json). All 18 gate
conditions passed. The packet contains 17 distinct test programs and 18 execution
variants, with **21,756 raw assertion executions and zero failures**. Native
repeats the same independent core flow; these are execution counts, not a count
of unique logical invariants. Earlier QA authoring attempts are retained in
`history/` and excluded from accepted totals.

## Frozen review and approved scope

The approved proposal, full design, task ledger and inventory-equipment delta
were reviewed at `docs/spec/changes/add-zerkov-playable-raid-2026-09-09/`.
Task 4.10 requires game-owned, source-item-based, idempotent equipment grants and
revokes from authoritative full snapshots and accepted deltas, including removal
on unequip, destruction and invalidation.

The exact catalog diff in [reviewed_diff.json](reviewed_diff.json) and the full bodies of all new production/promoted test
files were reviewed. [frozen_hashes.json](frozen_hashes.json) and
[frozen_hashes_after.json](frozen_hashes_after.json) match all six hashes supplied
to this gate: the promoted reconciliation contract, inventory ability adapter,
participant interface, production Gameplay Abilities port, equipment ability
content and inventory catalog. No production or promoted test file was changed
by the validator.

The implementation binds exact owner, admission, native inventory/catalog and
ability participant identities; seals the equipment declaration mapping into
the inventory manifest; queues bounded sequencing hints without granting from
them; and reconciles the current native owner snapshot in phase 7. Stable item
source keys preserve retained records. Complete preflight precedes deterministic
add-before-remove replacement, and adapter publication follows native completion.
The native port validates the complete canonical content subset and ties the
authored catalog back to the configured native manifest. Unexpected partial
failure enters explicit recovery and may terminally quarantine the component.

## Independent real flow and native evidence

[independent_flow.gd](independent_flow.gd) is a separately authored `SceneTree`
harness modeled on the prior 4.9 QA runner/display. It does not load, subclass or
invoke the promoted contract. It creates real `RaidInventoryOwner`,
`InventoryAuthority`, `RaidAuthority`, `GameplayAbilityComponent`, production
participant and adapter instances. Six separate fixtures exercise the ordinary
flow, injected failure, explicit release, owner-first Node destruction,
component-first Node destruction and the accepted terminal-first composition
constraint.

Only `RaidAuthority.advance_one()` drives ticks. Real inventory insert, move,
equip, replay and destroy operations run inside phase 5. Native transaction
callbacks and the end of that phase prove the complete ability state is still
unchanged. Native grant/revoke signals and accepted adapter publications occur
in phase 7. A controlled independent same-tag grant/revoke also runs in phase 7.
The ordered receipts, events, observations and individual assertions are in
[flow_results.json](flow_results.json) and [native_results.json](native_results.json).

The continuous fixture proves mutation-free binding, revision-zero initial full,
rig/backpack no-grant declarations, AKM and machete grants, duplicate full state,
recorded native replay and normalized replay, pending-hint deduplication,
multiple accepted revisions, forward-gap detection/full-snapshot healing,
unequip/re-equip, source identity retention, replacement add-before-remove and
destruction of equipped items. The exact replacement event sequence is two
inventory commits, native grant, native revoke, then one adapter publication.
An independent same-tag source survives removal of the adapter-owned AKM; its
own later revoke clears the last AKM contribution. Final destruction leaves
zero live sources/effects/executions/tags/modifiers and five revoked tombstones.

The dedicated failure fixture starts with two real live contributors, injects
only a persistent rejected revoke through a narrow production-port subclass,
then uses the unchanged production quarantine and cleanup proofs. It proves
`RaidAuthority.FAILED`, `InventoryAbilityAdapter.RECOVERY_REQUIRED`, exactly one
quarantine call, a terminal native component, zero live contributions and an
empty unresolved-record list. No successful new inventory revision is claimed.

Actual `queue_free()` plus instance-validity checks prove owner-first and
component-first Node destruction. The synchronous invalidation publication
observes clean native effects/tags/modifiers before destruction. Both leave an
inert successful phase handler while the raid remains active. Explicit release
is independently proven before raid terminalization.

The accepted run historically used the pinned Godot 4.7.2 executable with the
recorded project path, Compatibility renderer, 1280x720 resolution, 40,40
position, and this packet's `independent_flow.gd`. This is provenance only, not
a runnable current command; the runner is now unconditionally retired.

The process reported the actual macOS display server, visible 1280×720 window,
Compatibility renderer and exact executable. CUA accessibility independently
observed the named native standard window while it was running. The process
exited normally before a later CUA screenshot request; the four framebuffer
PNGs had already been captured in the live window using four deterministic
settle frames and `RenderingServer.force_draw(true)`.

All four frames were visually inspected:

- [Ordinary flow](ordinary_flow_1280x720.png): eleven ordered canonical states.
- [Independent grant isolation](external_isolation_1280x720.png): foreign-source
  survival and final destruction cleanup.
- [Production quarantine](recovery_1280x720.png): failed raid, recovery required,
  zero unresolved records, two terminal historical rows and zero live effects.
- [Node teardown orders](teardown_1280x720.png): explicit release, owner-first
  and component-first cleanup.

The board prominently states `AUTOMATED VALIDATION HARNESS / NOT PRODUCTION UI`
and distinguishes live grants from revoked and terminal historical rows.
A multi-image tool presentation appeared cropped; the recovery PNG was then
opened individually at original detail and verified to contain the complete
title, subtitle, metadata, table headings and all rows. The actual PNG was not
clipped. Details are in [visual_review.json](visual_review.json); capture hashes
are in [capture_hashes.json](capture_hashes.json).

## Automated matrix and diagnostics

| Program | Checks | Failures |
| --- | ---: | ---: |
| Promoted equipment ability reconciliation | 546 | 0 |
| Inventory catalog | 537 | 0 |
| Inventory weapon reload | 159 | 0 |
| Equipped-item reconciliation | 123 | 0 |
| Inventory authority | 79 | 0 |
| Identity | 18,442 | 0 |
| Session lifecycle | 44 | 0 |
| Authority replay | 81 | 0 |
| Units/clock | 29 | 0 |
| Inventory projection | 99 | 0 |
| Inventory intent adapter | 162 | 0 |
| Inventory mutation routing | 146 | 0 |
| Inventory UI binding | 138 | 0 |
| Inventory multiple controllers | 23 | 0 |
| Combat content | 79 | 0 |
| Combined add-ons smoke | 155 | 0 |
| Independent headless real flow | 451 | 0 |
| Independent visible native flow | 463 | 0 |

The 16 promoted/adjacent suites total 20,842 assertions. Native adds 12 window
and capture assertions to the same 451 independent core assertions; ordered
core labels/results and semantic state rows match the headless run.

The unchanged promoted contract covers semantic manifest and identity
mismatches, sealed native versus mutated authored content, one-micro modifier
drift, native port reentry, grant/revoke before/after failure, failed cleanup,
production quarantine, lingering actual same-tag/modifier contributions,
lifecycle/recovery retry provenance, replacement failures, external revoke,
and native grant-history capacity. Sixty-four grant-history entries are
accounted for, and the 65th re-equip fails preflight with no new live effect.

Every accepted execution has a raw `.log` and structured `_runner.json` with
the command, PID, elapsed time, exit code, timeout status and diagnostics.
Assertions, `ERROR`/`SCRIPT ERROR`, stack overflow, warnings, and
RID/ObjectDB/resource/font leaks are failures even with exit code zero.
All current accepted logs are clean. Clean editor imports before and after QA
construction, strict spec-toolkit validation and `git diff --check` pass.
The earlier QA parse attempt was correctly rejected despite engine exit zero.

## Integrity and accepted limits

All 1,231 covered project files are unchanged across the gate, including the
frozen sources, dependencies, vendored add-ons and specs. The six sibling add-on
trees also match their recorded hashes: Git heads/status and source hashes for
five repositories, and a full non-cache file snapshot for the non-Git Level Task
System tree. See [sibling_addons_after_verification.json](sibling_addons_after_verification.json).
Vendored add-on status is clean. No staging or checkpoint commit was performed,
and no non-packet source/status change was introduced. The exact pinned engine
hash is unchanged. A targeted credential/private-key scan passed without
emitting any matching content. All runner-owned processes were reaped; unrelated
processes were left untouched. The validator created no temporary files outside
this QA packet.

Accepted **P2 follow-up for tasks 4.12/7.1**: composition must release the adapter
or tear down the inventory owner/component before `RaidAuthority` terminalizes.
Raid terminalization clears phase handlers and alone does not automatically
remove equipment contributions. The independent terminal-first probe positively
observed that limitation, then explicitly cleaned its native state. This gate
does not claim automatic cleanup for the reverse order.

This is offline, synchronous, in-memory reconciliation. Native signals are not
a batch transaction boundary. Unexpected ambiguous failure can quarantine the
whole captured component; ordinary foreign-source isolation does not imply
foreign-state survival through component-wide quarantine. Native grant history
is bounded at 64 and no automatic history recycling or completed recovery
workflow is claimed. Human playtest approval remains false.

The QA packet received one packaging-only repair after the initial staging
attempt. Ordinary context-line prefixes in the raw nested `.patch` triggered
Git's outer added-file whitespace checker. The patch is now losslessly encoded
as base64 in `reviewed_diff.json`; decoding reproduces SHA-256
`e5ab6a83d2547c9af54a6e3596e55d3cbd25cbaafa4295bd062d4359e4954c42`.
The runner and sealer preserve and validate that encoding. Production files,
promoted tests, native captures and runtime results were not altered. The seal
contains **80 entries**, with **82 total packet files** including the manifest
and its verification log. Exact staged-index acceptance remains a separate gate
after root restaging; the frozen-runtime ACCEPT above does not replace it.

The former `run_validation.py` suite/flow/native invocations and
`finalize_packet.py` invocation are historical records only and are disabled.
They now terminate before imports or work. `packet_hashes.sha256` inventories
the retained evidence; `manifest_verification.log` records the original
accepted seal check and is not a claim that the retired commands were rerun.
