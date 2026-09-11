# Inventory weapon reload evidence

This is a retained historical task 4.9 evidence packet. Its visible native
validation command and smaller-output capture are not part of the current
first-playable UI matrix; current agents/tests MUST NOT invoke or regenerate
them until task 11.8 or a later approved display-support proposal. The
immutable packet remains audit history, not a current aggregate check.

This directory contains the task 4.9 validation history and the final accepted
checkpoint. The acceptance authority is the fresh GPT-6 Astra packet:

- [Final Astra report](astra_final/REPORT.md)
- [Final gate result](astra_final/gate_result.json)
- [Native validation timeline](astra_final/native_timeline_1280x720.png)

The final gate is `ACCEPT FOR DOCS/STAGING` with `human_approval: false`. It
used the pinned Godot 4.7.2 Compatibility executable and found `20750` raw
assertion executions with `0` failures. The promoted catalog and reload
contracts passed `537/0` and `159/0`; the independent capacity challenge passed
`33/0`; the real-addon flow passed `208/0` headless and `213/0` in the native
window. Native repeats the 208 core flow assertions and adds five capture
checks. The packet records 17 distinct test programs and 18 execution variants.

The real flow proves a canonical equipped AKM reserving 27 rounds in
magazine -> rig -> pockets order, canceling and replaying without quantity
change, then committing once to 30 loaded rounds with a conserved total of 41.
It covers same-due-tick death and native equipped-item movement/swap, plus
separate explicit adapter teardown and promoted owner-lifecycle
invalidation/teardown coverage, recursive publication, and out-of-band
completion quarantine.

## Historical rejection

The earlier sealed Astra gate is retained at
[astra_gate/REPORT.md](astra_gate/REPORT.md) and remains useful rejection
history only. It is not acceptance evidence and must not be overwritten or
substituted for `astra_final`. Its magazine probe exposed diagnostic 115,
`NESTING_DEPTH_EXCEEDED`: `_magazine_container()` had
`allow_nesting=false` and `max_nesting_depth=0`, so the provider child could
not materialize at depth one. The `FEATURE_LIST` capability-query metadata
closure for the player-raid profile was added alongside that repair; it was
not the original reproduced blocker. Stash/world-crate/corpse profiles remain
the unchecked `4.12a` follow-up. The final packet re-ran the real add-on flow
and proved the actual magazine child list and capacity behavior.

## Reproduction

From the repository root, with `ZERKOV_GODOT` set to the pinned executable:

```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_weapon_reload_contract.gd
python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py capacity
python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py flow
python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py suites
```

The visible `native` mode remains an immutable historical packet reproduction;
it is intentionally omitted from the current matrix and must not be invoked
until task 11.8 or a later approved display-support proposal.

The native image is explicitly labeled as an automated validation harness, not
production UI or human playtest. The accepted boundary is offline,
synchronous, in-memory and single-writer/no-yield; it does not claim
crash-safe symmetric 2PC or physical detachable-magazine identity/swapping.
Production weapon instances/input (5.2 and 5.7), human playtest, whole-game,
multiplayer and release gates remain open. The next implementation task is
4.10.
