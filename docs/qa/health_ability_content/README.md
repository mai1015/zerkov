# Health ability content evidence

Task 5.5 authors the first-playable Gameplay Abilities health catalog. The
current implementation packet lives in `implementation/`. The earlier
`independent_review.md` and `astra_final/` acceptance records describe a
superseded source snapshot and are explicitly not acceptance evidence for the
current implementation; a different agent must review the final commit.

The packet covers native catalog validation/configuration, all seven body-zone
definitions, life/stamina/hydration initialization, parameterized attribute
effects, execution-owned life/injury/treatment transitions, fixed-point
overkill/overspend/overrestore bounds, pain and movement modifiers, healing
eligibility policy, post-gameplay initialization replay, catalog provenance,
60 Hz rejection, stale/future command fail-atomicity across both canonical
bytes and the wrapper tick watermark, reentrant-notification rejection before
native queue admission, bounded reservations and terminal receipts for foreign
native notification queues, deterministic snapshots, adjacent equipment/combat
regressions, combined add-on loading, strict spec validation and an error-free
editor import.

Run the implementation validation from the repository root:

```bash
python3 docs/qa/health_ability_content/implementation/run_validation.py
```

Task 5.5 supplies definitions and the bounded local effect-application seam.
It does not claim task 5.6 hit/injury evaluation, periodic bleed scheduling,
stable consequence deduplication, death ordering, medical-item transactions or
cross-domain consequence orchestration. It also does not claim hitboxes,
combat feel, HUD binding, human playtest, multiplayer or release readiness.
