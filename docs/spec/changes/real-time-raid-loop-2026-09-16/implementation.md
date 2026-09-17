# Implementation record: R2 expected health metadata and lookup

The user approved staged implementation after the proposal. This record supersedes the earlier proposal/design's historical 'not approved for implementation' status; it does not imply acceptance of unimplemented mechanisms. PR #22 remains a partial optimization, not a 60/120 FPS fix.

## Delivered increment

`ZerkovHealthAbilityContent` constructs and validates the canonical expected catalog once at script initialization. It retains only a write-once, recursively read-only record of identifiers, fingerprint, entry count, tick rate and validity. It retains no expected Resource graph, actual component, actual-catalog verdict or mutable authoring alias.

Each preflight still validates the FULL CURRENT actual catalog and compares its fingerprint with the configured component. It still constructs and natively validates the current selected subset. Only construction/validation of the unchanging expected catalog was removed from repeated execution: three native validator invocations become two. Each definition collection is fetched once and indexed in linear time with a permanent null sentinel for duplicates; a third duplicate cannot resurrect a definition. Category order and the native-definition rejection precedence are preserved.

No callback graph check, live attribute/lifecycle check, mutation authorization, native binary, lock, save format, gameplay timing or simulation frequency is disabled or changed. Closed production dispatch, active-content isolation and projection reuse are NOT implemented by this increment.

## Verification protocol

`health_catalog_reference.gd` freezes the prior lookup/validation algorithm as a test-only oracle. The native contract compares exact result dictionaries and side-effect-free component snapshots for health-only and combined catalogs, repeated warm reads, reordered definitions, triple duplicates, nested magnitude/array mutation and restoration, nonsemantic metadata, coherently altered semantics and a missing ability. Additional tests verify scalar-only deep immutability and duplicate lookup behavior.

The native runner rejects parse/runtime errors and shutdown retention diagnostics even with exit code zero and a passing assertion marker. Its four tooling regressions run separately. Native tests use the shipped addons and the exact locked engine; there is no stub fallback.

Microbenchmark: warmed reference/candidate/candidate/reference preflights with 32 samples per pass, exact return-value equality and p50/p95/p99/max. This is catalog-preflight cost, not whole-game performance.

Application comparison: baseline/control/control/baseline followed by instrumented attribution. The baseline is the immediate predecessor `be18fc760e8eb102ee4c2747164eb00600a800d3`, not the earlier scanner baseline. This isolates R2 from the previous scanner improvement. All stage-end authority digests must match. The profiler now also reports p99/max and treats retained runtime objects as failure. CI records exact source, engine and native library hashes and CPU/OS identity.

## Evidence at implementation commit

Local: Python syntax compilation; four new native-runner tooling tests; ten existing combat-runner tests; one registration-idempotence test; isolated locked-engine combat values/input regression (3595 input checks per replay, 34 values checks). Isolated replay digest: `b8c5c5215ef63dc1ec600004354a15dbc7116c074bd9c242b9f869ceb73dd6ff`. These local checks are NOT native-game or FPS acceptance.

Native health, combat, progression, full local-flow and paired application profiling results are pending at this commit. No numerical speedup is claimed before inspecting their exact-revision evidence. Separate release, long-raid scaling and windowed target-hardware frame-time acceptance remain outstanding.
