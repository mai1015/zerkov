# Task 8.9 integration verification

Status: accepted after independent Astra candidate review and independent
post-integration review. Task 8.9 is checked; `human_approval` remains false.

Final exact-output enforcement was repaired on 2026-09-11 by integrating
candidate `d3b8975fe2da3dcf4937917007d586339b73025c` over
`e12dcd043625c22ea8b62cd7fce2587505bb03a8`, then merging current main
`26b9d5a94e56278fc3783fcf701644628960cbbb`. Both no-fast-forward merge
boundaries were conflict-free. The original accepted native evidence remains
untouched and historical; this repair used source-only, static, import,
check-only, and exact-argument headless validation.

## Integration boundary

The reviewed candidate
`14463e2296ab021aa3ebbec88a3b36752aee3f6e` was applied with a no-fast-forward,
no-commit merge over main
`9cb602f0f5674deea7d5ad8739c67dda431006f4`. Their merge base is
`7acc971b7622f1a6580e51bcca27793f32e50d56`.

The merge produced no conflicts. Only
`tests/tooling/test_ui_first_playable_scope.py` changed on both sides: current
main strengthened automatic active-writer discovery and negative controls,
while Task 8.9 registered its two capture writers. The combined static gate
passes all seven tests.

The candidate report and its original 43-entry source manifest remain
unchanged as historical evidence. That manifest now reports exactly four
expected differences:

- current main's strengthened
  `tests/tooling/test_ui_first_playable_scope.py` and `ui/main.gd`;
- the two Task 8.9 runners hardened during integration.

The other 39 candidate entries still match. This directory's
`sources.sha256` reseals those four final files, the unchanged candidate
manifest, the task ledger, this integration record, and all seven saved
integration captures.

## Final exact-output enforcement repair

The scanner now accepts only direct local image receivers for a PNG write and
binds exact-frame proof to each individual `save_png` occurrence. Qualified or
indexed receivers such as `holder.image.save_png(...)` and
`holder[0].save_png(...)` are unsupported and fail the gate, including two
qualified writes on one line behind an unrelated local-image guard. Separate
same-line direct writes pass only when each direct receiver has its own
dominating exact-size rejection.

Retired GDScript discovery also rejects a top-level `load()` or `preload()` in
a `const`/`var` initializer before `_initialize()` can fail closed. Both
retained ability/equipment independent-flow copies now declare their historical
script handles without eager imports and keep their `load()` calls inside the
unreachable retired flow. The retained ability/equipment and weapon/reload
reports label their command descriptions as disabled historical provenance.

The two Task 8.9 writers retain the physical-window, root, root-texture, and
raw-readback exact-1920 preflight before UI work. At every write they now test
the direct raw `Image` receiver and return on mismatch immediately before
`save_png`; buffer encoding and decoded-file identity checks occur after the
write. Thus no alias or unproven image operation lies between the final proof
and the write, while the decoded file must still equal the source image's raw
pixel data.

The exact-output module passes all 12 tests and full tooling discovery passes
all 15. Current discovery covers 25 active GDScript runners, 35 retired
GDScript runners, 12 retired Python entry points, and 9 active PNG writers.
Pinned exact-argument headless checks pass the Task 8.9 contract at `74/0` and
its real-input visual contract at `124/0` with capture intentionally skipped by
the dummy renderer. A pinned editor import and check-only parsing of all 14
changed GDScript files complete without diagnostics. The newly merged health
consequence and inventory-catalog contracts also pass at `444/0` and `551/0`.
Both approved specs validate strictly, and the Sawmill packet manifest verifies
without a changed Sawmill-specific source.

No native rerun was required: the repair changes proof/write ordering, not the
raw image, path, UI behavior, or accepted captures. All seven retained
integration PNGs remain exactly 1920x1080 and byte-identical to their accepted
candidate counterparts. No alternate-size or upscale output was produced.

## Exact native evidence

The predecessor integration run used the pinned Godot 4.7.2 executable, this
worktree, `--resolution 1920x1080`, exclusive fullscreen, the two named Task
8.9 scripts, and the integration capture path/directory. The exact complete
argv was not independently persisted, so this packet does not reconstruct its
ordering as fact. The preserved handoff transcript records:

```text
EXACT_1920_NATIVE_PREFLIGHT physical_window=1920x1080 root=1920x1080 root_texture=1920x1080 raw_root_image=1920x1080 ui_mounted=false
FEATURE_GATES_8_9_RESULT checks=163 failures=0 size=1920x1080
FEATURE_GATES_8_9_VISUAL_RESULT checks=713 failures=0 size=1920x1080 frames=5
```

Both runners now fail closed before mounting any UI unless the native physical
window, root, visible rectangle, root texture, and raw root-image readback are
all exactly 1920x1080. The contract runner then checks the physical window/root
at each of seven capture stages, accounting for its increase from 156 to 163
checks. The real-input runner checks the same native boundary at its 50 render
contract stages, accounting for its increase from 663 to 713 checks.

The seven saved PNGs all decode as exactly 1920x1080. Each is byte-for-byte
identical to the candidate's accepted raw-pixel-preserving PNG, so the stronger
physical preflight introduced no visual drift:

| Capture | SHA-256 |
| --- | --- |
| `feature_gate_bunker_1920x1080.png` | `b835ef07f956f043c5940d201c099db90196f66d191ad2ca72532f77ab0c6fc4` |
| `feature_gate_crafting_1920x1080.png` | `078076a18b43eeef414dba8db38fad5f3d1f06d5fb561bda4eed1699b4c26924` |
| `feature_gate_friends_1920x1080.png` | `0a64bc78987b44500f01ffdc38db1d268c633dea52a96d86823d9c42fd617bec` |
| `feature_gate_insurance_1920x1080.png` | `909802e14a39db31cc049536e2142a075dc66e31ae89201080331d42eee5a3d8` |
| `feature_gate_marketplace_1920x1080.png` | `6d6a6d4638c7c31aa3b6db88d767673cecb74c22218a9a649faf5e7051f15f87` |
| `feature_gates_1920x1080.png` | `946d010d541ac202f6dd840925a3f90fd4d25af3c6b9d8800cfb905077e0a6b7` |
| `feature_gates_contact_sheet_1920x1080.png` | `5d65a8cf95c6231d049ad4d339253a4f710fe95b91cf3c5f35606c2da4614de1` |

No native rerun was needed after this validation. No alternate-size,
responsive, compact, historical packet generator, or shared binding writer was
executed.

## Fresh integration checks

All personally rerun screen-producing checks were headless and explicitly
pinned to `--resolution 1920x1080`.

| Check | Result |
| --- | --- |
| Godot executable/version/hash | 4.7.2 stable; `c7cccbf8fb143e34e02fd6521e09be2c2b974f0d5db080b19071c9c570718ccf` |
| Feature provider/action/route/focus contract | `74/0` headless |
| Real-input feature-gate contract | `124/0` headless; five actions, no image writes |
| CommonUI navigation / exact-1080 navigation / integration | `80/0`; `99/0`; `76/0` |
| UI route / composition / lifecycle | `948/0`; `103/0`; `116/0` |
| Production-state / read-only view contracts | `57/0`; `115/0` |
| Bunker / raid smoke | 21 passing assertions; `29/0` |
| Character composition / live binding | `22/0`; `65/0` |
| Inventory loot / inventory / utility smoke | `88/0`; `21/0`; `24/0` |
| Static first-playable scope | 12 tests, 0 failures |
| Complete tooling discovery | 15 tests, 0 failures |
| Strict approved-change validation | Both approved changes Valid |
| Pinned editor import / changed-script parsing | exit 0; 14/14 check-only; no engine diagnostics |
| Sawmill packet hashes | all entries OK; Sawmill-specific sources unchanged |
| Candidate manifest transition | 39 unchanged; four expected final-file differences resealed here |
| PNG dimensions and candidate byte identity | seven exact 1920x1080; seven identical |
| Shared binding preservation | exact baseline SHA; `.tmp` and `.bak` absent |
| Merge/diff hygiene | zero unmerged entries; staged and unstaged diff checks pass |

The shared binding file remained exactly
`ff6f972f99cc7e9a66db4852735ead27d344b3d090d246a420aa0136aff6bde5`.
No binding file was written or removed by this integration, including during
the adjacent exact-1080 headless regression sweep.

## Scope held

This integration adds no meta-system service and makes no human-navigation,
controller, broader real-data screen, whole-game, multiplayer, or release
claim. Bunker, crafting, friends, insurance, and marketplace remain visibly
prototype/locked and unable to commit production profile state. The
post-integration reviewer accepted commit
`5c9cb52dae26e9503bb9589da3445e91617766d4` with no P0/P1/P2 findings; Task
8.9 alone is now accepted and human approval remains false.

Exact observed output and personally run commands are recorded in
`verification.log`.
