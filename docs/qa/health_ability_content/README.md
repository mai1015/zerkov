# Health ability content evidence

Task 5.5 authors the first-playable Gameplay Abilities health catalog. The
retained implementation packet lives in `implementation/` and seals its
recorded source checkpoint. Its generator is retired and fails closed before
imports, subprocesses, paths, or writes. The earlier
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
native notification queues, public-API capacity probing that preserves the
native tick/sequence watermark at all 64 saturated mutation slots, game-owned
deferred activation ordering, an 80-attempt reservation stress case,
deterministic snapshots, adjacent equipment/combat regressions, combined add-on
loading, strict spec validation and an error-free editor import.

Run the promoted contract against current source from the repository root:

```bash
$ZERKOV_GODOT --headless --resolution 1920x1080 --path . --audio-driver Dummy \
  --script res://tests/combat/health_ability_content_contract.gd
```

`implementation/run_validation.py` must not be invoked or used to regenerate
this historical packet until task 11.8 or a later approved display-support
proposal. Current contract results do not reseal the retained packet.

Task 5.5 supplies definitions and the bounded local effect-application seam.
It does not claim task 5.6 hit/injury evaluation, periodic bleed scheduling,
stable consequence deduplication, death ordering, medical-item transactions or
cross-domain consequence orchestration. It also does not claim hitboxes,
combat feel, HUD binding, human playtest, multiplayer or release readiness.
