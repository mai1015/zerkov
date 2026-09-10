# Verification budgets

Representative resource budgets for the native engine-free core (tasks.md
12.7; inventory-platform-support spec, "Verification and Sanitizer
Coverage"). Enforced by
`addons/inventory_system/native/tests/inv_test_budgets.cpp`. None of these
budgets weaken validation, canonical ordering, or any hard limit in
[`../../../docs/inventory/contracts.md`](../../../docs/inventory/contracts.md)
— they pin a **regression ceiling** on top of behavior already fully proven
elsewhere (byte-exact golden fixtures in `inv_test_protocol_codec.cpp`,
round-trip tests in `inv_test_snapshot.cpp`, per-op delta proofs in
`inv_test_deltas.cpp`). A budget test failing means something got
unexpectedly bigger, not that canonical behavior changed.

## How a budget is pinned

Every ceiling below follows the same two-step discipline the suite's golden
byte fixtures already use (see `inv_test_protocol_codec.cpp`'s header
comment): **measure the actual value once, then pin `measured * 1.5`**
(rounded up to a round number) as the regression ceiling, in addition to the
unconditional hard limit from `inv_limits.h`. `inv_test_budgets.cpp` has a
`PRINT_MEASURED_BUDGETS` compile-time flag (default `false`) that, when
flipped to `true` locally, prints every measured byte count to `stderr` so
the ceiling can be re-derived after an intentional change; it must be
flipped back to `false` before committing.

## Measured vs. ceiling

| Budget | Fixture | Measured | Ceiling (measured × 1.5) | Hard limit |
|---|---|---:|---:|---:|
| Typical command envelope | One `MoveItemCommand` against the shared small transaction-test catalog (`inv_test_transaction_support.h`) | 65 bytes | 100 bytes | `MAX_COMMAND_BYTES` = 4,096 |
| Large-stash snapshot | 4,000-item stash (one `ORDERED_LIST` container near `MAX_ITEMS_PER_INVENTORY` = 4,096) | 248,173 bytes | 375,000 bytes | `MAX_SNAPSHOT_BYTES` = 1,048,576 |
| Delta batch for one move in that stash | Same 4,000-item stash, one accepted `MoveItemCommand` | 64 bytes | 100 bytes | `MAX_DELTA_BYTES` = 262,144 |
| Full resync (encode + decode + restore) of that stash | Same 4,000-item stash | succeeds; restored item count = 4,000 | N/A — success/count is the proxy (see below) | — |

## Why an `ORDERED_LIST` container for the "large stash"

A stash approaching `MAX_ITEMS_PER_INVENTORY` needs thousands of distinct
item instances. A `SPATIAL_GRID` container would need an impractically large
square footprint to hold that many 1×1 items; an `ORDERED_LIST` container
holds one item per dense ordinal with no spatial footprint at all, so it
reaches a representative large-stash size with a small, self-contained
fixture catalog (`test.container.budget_stash` / `test.profile.budget_stash`
/ `test.item.budget_unit`, never shared with another test's fixture, so it
cannot perturb any other test's golden manifest fingerprint). The item count
used is 4,000 — near, but deliberately short of, the 4,096 hard limit: the
exact-limit edge is already covered by
`aggregate_item_limit_rejects_create_without_partial_mutation` in
`inv_test_runtime_state.cpp`, so this fixture stays a representative-scale
budget rather than a duplicate edge probe.

## The key resync-cost property

The delta-batch budget is deliberately measured against the SAME large
stash as the snapshot budget, and pinned at roughly the same scale as the
plain command-envelope budget (not the stash-snapshot budget): a delta's
size is a function of the command's own payload, never of inventory size.
`budget_delta_batch_for_one_move_in_large_stash_does_not_scale_with_stash_size`
is the one test in this file that exists specifically to prove that
property, not merely to fit under `MAX_DELTA_BYTES`.

## Full resync: a bounded op-count proxy instead of wall-clock timing

Tests in this repository never assert wall-clock timing (nondeterministic,
environment-dependent). Instead, `budget_full_resync_of_large_stash_completes_
and_preserves_item_count` treats **successful completion at scale, with the
exact expected item count reproduced**, as the resync-cost proxy:
`decode_canonical()` bounds every collection against `inv_limits.h` before
any per-entry loop runs (`core/inv_bytes.h`'s `read_count()`), and
`restore()`/`restore_from_snapshot_parts()` walk the decoded maps exactly
once each. Completing that walk over 4,000 entries and getting back exactly
4,000 restored items — plus a clean `audit_invariants()` pass on the
restored runtime — is the bounded-work proof; there is no separate iteration
counter to maintain.

## Memory

Memory is bounded **by construction**, not by a runtime RSS assertion. Every
collection the native core allocates from untrusted or bulk input — items,
containers, references, delta ops, trait payloads, manifest entries,
snapshot/command/delta bytes — is capped by an explicit `inv_limits.h`
constant and validated (`ByteReader::read_count()`/`read_string()`/
`read_blob()`, or the runtime's own aggregate-bound checks in
`inv_runtime_state.cpp`) **before** the corresponding allocation or
per-entry loop, never after. A profile or container cannot lower a caller
into unbounded allocation; it can only tighten an already-hard-capped
aggregate limit (contracts.md: "Profiles may lower applicable aggregate
limits but cannot exceed hard limits"). Given that discipline, a process-RSS
assertion in a test would only ever restate a bound the type system and the
bounded decoders already guarantee at every call site — so this file
documents the guarantee here instead of asserting it at runtime.

## Discovery budgets

Recipient discovery state is independently bounded: 256 policies and
recipients, 512 indexed containers, 4,096 revealed items, 8,192 token
bindings, and 1,024 idempotency records. One authored duration is capped at
24 hours and one trusted advance at 60 seconds. A discovery view or V1
replacement delta is capped at `MAX_SNAPSHOT_BYTES + MAX_DELTA_BYTES`
(1,310,720 bytes). These bounds are encoded into the opt-in discovery feature
manifest and every decoder rejects before unbounded allocation. The full
table and compatibility consequence are in [`discovery.md`](discovery.md).
