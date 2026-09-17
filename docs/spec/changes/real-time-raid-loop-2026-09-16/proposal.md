# Real-time raid loop: 60 FPS baseline, 120 FPS performance target

Status: proposed architecture; not approved for implementation and not a performance acceptance claim.

## Why

The current bottleneck is repeated validation over retained state, not just movement or rendering. `RaidAuthority.PhaseHandlerRelay` recursively scans the callback owner's reachable graph on every invocation. `ZerkovHealthAbilityContent._validate_catalog_subset` runs a complete live catalog validator, builds a fresh expected catalog, repeatedly searches actual definitions, then validates both expected and selected catalogs for every preflight. Health audits invoke this per actor per tick. Published health snapshots are also reconstructed by repeated readers.

The existing PR #22 optimization is useful but insufficient. Its teardown cycle was fixed separately in `5bc2f1fb1296c923e786d83d3c665af8c1d4f623`. That fix preserves the existing fresh-scan contract and is not the redesign proposed here.

## Goals

Preserve the authoritative 60 Hz simulation, gameplay outcomes, local saves, offline default and future host-authoritative Steam path. Make mandatory hot-path work bounded by active simulation work, not by the transitive size of each callback owner's graph or by rebuilding authored definitions. Target a warmed authoritative tick p95 at or below 4 ms on a named reference machine, leaving frame time for presentation and rendering. Prove 60/120 FPS separately with windowed frame-time measurements.

## Non-goals

Do not change installed addon binaries, locks, save formats, encounter rules or simulation frequency. Do not disable validation globally, allow UI/client writes, cache arbitrary callback safety, or mistake shared CI timings for the operator's FPS. A native runtime change, if needed to enforce immutable compiled content, requires its own reviewed addon promotion; this proposal does not authorize one.

## Scope and approval boundary

First deliver behavior-preserving reductions: immutable expected-content metadata, linear duplicate-aware definition lookup, instrumentation and measured snapshot reuse only where revision coverage is proven. Then replace the current arbitrary-callback capture contract with a reviewed, closed production dispatch contract. This is an explicit architecture/security contract change, not a transparent scanner optimization. Catalog validation may move out of the tick only after active content cannot be mutated through retained authoring-resource aliases, or a complete mutation revision/invalidation mechanism is proven. A top-level Resource.changed signal alone is insufficient.

The proposed replacement contracts and migration tests must be approved before removing existing per-invocation protections. Until then, retain the fresh scanner and full live catalog validation.

## Acceptance

Exact locked native runtime; independently recorded debug and release runs; paired uninstrumented comparisons with matching authoritative traces; full extraction, death, save failure/retry and process relaunch; stale-generation, forged registration, wrong-phase, teardown and content-mutation adversaries. Final windowed runs record CPU/GPU, renderer, resolution, VSync, frame/tick p50/p95/p99 and missed budgets. See design and tasks.
