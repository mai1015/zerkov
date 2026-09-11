# Presentation boundary

Read-only UI projections, animation, VFX, camera, and audio presenters live
here. Presentation submits intent through the authority boundary and cannot
commit gameplay outcomes or write canonical domain state.

`views/` contains the typed screen contracts. Every ready view carries a
generation, revision and authoritative source tick; unavailable views carry an
explicit synchronization state and diagnostic. Stale, resynchronizing and
disconnected views also retain the exact subject identity needed to associate
them with the previous ready projection. Contracts expose typed accessors only,
seal their provenance and retained child records after validation, detach stable
identities, and return read-only collections. They deliberately contain no
authority, navigation or intent submission methods.

| Contract | Stable projection surface |
| --- | --- |
| `RaidView` | lifecycle, authoritative timer, equipped weapon, extracts and ordered feed |
| `InventoryView` | one profile/raid scope with typed containers, exact per-inventory revisions and item records |
| `HealthView` | liveness, body-part totals, survival resources, injuries and effects |
| `TaskView` | task selection, status, objectives, rewards and feature-gate reasons |
| `MapView` | authored zones, normalized markers, selection and availability |
| `BunkerView` | profile summary, stash capacity, deployment readiness and gated stations |
| `SummaryView` | terminal outcome, settlement identity, audit digest, loot, tasks, losses and corrections |
