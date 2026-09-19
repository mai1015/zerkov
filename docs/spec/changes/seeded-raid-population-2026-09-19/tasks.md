# Tasks

- [x] **T1 — Define the closed population values and deterministic generator.**
  Evidence: same inputs produce the same digest; changed seed/map identity changes
  the plan; invalid/tampered plans fail validation.
- [x] **T2 — Add authored optional-container candidates and weighted loot tables.**
  Evidence: every map exposes six unique bounded candidates and known item rules.
- [x] **T3 — Persist the population descriptor through deploy, prepare, commit and recovery.**
  Evidence: deployment retries reject descriptor conflicts; committed receipts
  preserve the descriptor; legacy records without it remain valid.
- [x] **T4 — Integrate objective and optional containers with the live raid.**
  Evidence: three task containers remain guaranteed; two optional containers are
  selected, searchable and open through the existing inventory flow.
- [x] **T5 — Add non-physics placeholder visuals for selected optional containers.**
  Evidence: selected containers have visible presenters without adding physics
  bodies or changing authoritative geometry.
- [x] **T6 — Run focused, live-map, local-flow and persistence regression suites.**
  Evidence: locked Godot 4.7.2 passed the population contract (146/0),
  progression persistence (331/0), native progression (446/0), live-map
  structure (2,283/0), complete local journey including an optional cache
  (4,569/0), and Northline/Blackwater launch flows (48/0 each). Repository
  tooling passed 247 tests and 128 subtests; exact-output policy passed.
