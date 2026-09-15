# AI workstream review checkpoint

Based on task-6 branch `071fbd179df1c59e27a6f4f3fb8a4332a21904f1`.
Scope: implement the approved small, deterministic AI workstream independently
of the user's task 3 work. No behavior-tree addon or new scope is approved here.

| Task | Branch implementation | Acceptance still required |
| --- | --- | --- |
| 6.1 | Existing owner/cadence/budget retained; optional registry injected into the same reserved callback. | Rerun existing native Vision owner regressions after this extension. |
| 6.2 | Full-frame actor lifecycle, strict source/native revisions, stable IDs, explicit geometry, fail-stop native synchronization. | Actual actor/bake source from task 3; native owner/registry tests on supported binaries. |
| 6.3 | Recipient allowlist, visible/remembered/unknown semantics, stale projection downgrade and expiry without hidden updates. | Native LOS, occluder, removal and memory conformance run. |
| 6.4 | Seven-state FSM and deterministic scheduling/replay. | Review and integrate real own-actor observations. |
| 6.5 | Scav aim/fire/reload requests, reaction/cadence, cover/path requests, rejection handling and target-loss search. | Shared movement/combat intent encoder in concrete WorldPort, real Scav encounter. |
| 6.6 | Mutant chase and melee requests using the same state/input boundary. | Task 5.8 authoritative melee/stamina and real mutant encounter. |
| 6.7 | Existing noise service scheduled after committed events; next-tick per-listener observations distributed. | Concrete committed-event producers through WorldPort; no cosmetic audio hooks. |
| 6.8 | Disabled-by-default diagnostic overlay: knowledge state, last-known point, path, state and budgets. | Mount in Sawmill presentation; synthetic exact-1080 render passed. |
| 6.9 | Executable pure contracts, 64-NPC reversed-order replay, native Vision and owner conformance tests, diagnostics-aware runner. | Native tests and full-checkout regressions remain blocked in this Linux environment. |
| 6.10 | Editable provisional Scav/mutant tuning profiles; observable reaction/search/retreat behavior. | Recorded real encounters, readability tuning and human acceptance. No proxy for playtesting. |

The task ledger is intentionally unchanged: no parent/child completion is inferred
from isolated component tests. `game/ai/README.md` is the integration contract and
reproduction entry point. Native tests fail rather than silently substitute mocks.

## Review focus

The branch changes only AI code, AI tests, a focused runner and this checkpoint.
It does not edit task 3, shared bootstrap, existing UI, `project.godot`, addon
snapshots, platform locks, or the existing capability specs. No logs, large result
bundles, engine binaries or synthetic captures are committed.

The most important integration check is a real root-owned `RaidAIWorldPort`:
movement/geometry -> reserved Vision update -> recipient observation -> FSM ->
shared intent encoder -> actual authority receipt. A fixture port is not a
production adapter, and the base port cannot launch successfully.
