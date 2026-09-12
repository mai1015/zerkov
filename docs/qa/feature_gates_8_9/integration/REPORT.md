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

## Source-policy escape hardening candidate

This source-only candidate tightens the static exact-frame writer policy.
A pre-proof image reference may remain only as a direct local alias, an
allowlisted read with inert arguments, or a direct known mutation with inert
arguments that is followed by a fresh proof. Containers, maps, properties,
indices, callables, bound methods, lambdas, constructors, returns, unknown
calls, and computed expressions are permanent escapes. A fresh-image helper
must also keep its returned image local and nonescaping.

Reverse provenance unions conditional initializers, parses nested parameter
defaults structurally, and carries property/index/non-fresh-call owners through
retained sibling aliases and callables. Every later owner access before the
save fails closed unless it is a direct sibling-image read in the narrow
allowlist. Before the proof, a tainted owner may only initialize the protected
direct image local/alias; qualified properties, global members, indexes,
containers, callables, and unrelated locals are rejected as retained owner
channels. The proof itself permits only the selected image readback, inert
exact constants, and approved helpers; typed properties and raw visible-rect
expressions are not proof operands. Direct typed, untyped, and cast aliases
remain covered positive controls when that alias is the proven/saved receiver.

The policy required guard-only source restructures in `ui/main.gd`,
`tests/ui_component_states.gd`,
`tests/visual/inventory_loot_ui_4_11/capture.gd`, and
`tests/visual/live_character_ui_8_6/capture.gd`: each existing root predicate
now terminates before a direct image-only proof. Static assertions preserve the
exact-size markers and the separated shape. No layout, style, data, inventory,
writer-inventory, or output-name branch changed.

Python historical entry points now require precisely one inert string marker
in the initial `SystemExit` call. Extra positional or starred arguments,
keywords, calls, comprehensions, f-strings, byte markers, and any `from`
clause are rejected before an entry point can be classified as retired.

The source-policy suite remains 12 tests and complete tooling remains 15.
Its permanent controls total 30 exact-write negatives, 39 pre-proof/reverse
origin negatives, six fresh-helper escape negatives, and 23 Python-retirement
negatives. Discovery remains 25 active GDScript runners, 35 retired GDScript
runners, 12 retired Python entry points, and 9 active PNG writers. The direct
Python-entry check confirmed all 12 leave only the required marker and no
observed side effect. This is a branch-local candidate record; it makes no
acceptance claim.

## Practical exact-1080 manifest-gate successor — 2026-09-11

The source-policy implementation above is superseded for current repository
enforcement by a bounded, reviewable manifest gate. The prior report text,
accepted native captures, hashes, and observed 8.9 behavior remain historical
records; none was rewritten or regenerated.

`config/first_playable_1080_gate.json` independently classifies 26 active visual
GDScript entrypoints, two active Python command drivers, 35 current headless
contracts, 16 retired display drivers, 31 historical-evidence drivers, and the
small exact-output support set. Current visual, command, and output-sensitive
support bytes are SHA-256 allowlisted. Repository discovery rejects an omitted
or new runner, active PNG-writer discovery remains complete at nine writers,
and retired/historical drivers must fail first before retained logic.

The checker validates literal output assignments and server size/attach calls,
literal command resolutions, exact project output configuration, the 640x360
world surface at nearest 3x, and reviewed root/visible/readback guard anchors.
It also rejects direct references from current commands, config, QA runners, or
reviewed support to retired/historical display drivers. This edge check exposed
one active inheritance from the retired multi-resolution inventory capture.
The exact inventory-loot runner now inherits the accepted inventory binding
contract directly and contains the same authority/bridge/controller setup it
already used. It still mounts the existing designed inventory interface; no
production inventory, game UI, layout, style, or state implementation changed.

This practical gate is explicitly not a general GDScript evaluator, sandbox,
or proof against arbitrary hostile semantics. Its boundary is the reviewed
manifest and hashes, independently discovered entrypoints, direct reference
edges, literal output/config/command operations, simple fail-first stubs, and
the sanctioned capture anchors. Any allowlisted byte change requires whole-file
review and resealing.

The final source-only matrix passed the standalone gate and all 14 focused tests
under Python 3.8, 3.9, and 3.14; complete tooling discovery passed 17 tests on
each interpreter after replacing the Python-3.9-only `str.removeprefix` use in
the platform artifact checker with its equivalent validated prefix slice.
No Godot process, renderer, viewport, PNG writer, historical packet generator,
or alternate-size command ran. Human approval remains false, and the task
ledger was not changed.

## Practical gate bounded-review repair — 2026-09-11

An independent review rejected the first practical-gate snapshot because
ordinary `extends SceneTree # comment` and single-quoted inherited runners were
not discovered, owner-relative imports could avoid the retired-reference edge
check, retired and historical categories could overlap, and seven sanctioned
writers plus Sawmill did not yet share the same physical final-write proof.
That rejected snapshot is not an accepted gate.

The successor uses bounded lexical/path checks rather than reviving the
superseded evaluator. It strips GDScript comments before runner discovery,
recognizes either quote style for inherited scripts, normalizes both `res://`
and owner-relative literal `extends`/`load`/`preload` paths, and requires each
GDScript and Python display driver to have exactly one category. Permanent
in-memory controls cover the original bypasses, comment decoys, all six
resource-operator/path combinations, and category overlap.

All nine sanctioned writer paths now preload the export-safe
`game/presentation/exact_1080_capture_guard.gd`. Immediately before each of the
ten static `save_png` calls, the exact manifest-declared call must fail closed
with no yield or intervening success-path statement. The hashed helper rejects
headless capture and requires the physical DisplayServer window, root/window
size, root visible rect and texture, capture viewport visible rect and texture,
and raw Image to all be exactly 1920x1080. Sawmill's `_exact_frame` now calls
that same physical guard, so an OS-clamped preview is not accepted; its sole
internal world remains 640x360 at exact nearest 3x. The existing designed
inventory screen and its authority/bridge/controller seam remain in use.

The source-only matrix passed the standalone gate on Python 3.8.20, 3.9.6, and
3.14.6, with 18/18 focused and 21/21 complete tooling tests on each interpreter.
Both managed changes passed strict validation. Pinned Godot 4.7.2 performed one
headless import and check-only parsed all ten changed GDScripts at explicit
`--resolution 1920x1080`. Three non-capture headless contracts then passed at
74/0, 124/0, and 111/0 with empty capture paths; the visual contract reported
`frames=0` and skipped capture. These runs are parser/contract evidence only:
no native renderer, physical visual approval, screenshot, PNG writer, alternate
resolution, or historical generator ran. Generated cache and the new helper
UID were moved intact to a recoverable temporary directory.

The dated successor seal contains all 27 current files, including the practical
manifest/checker, export-safe guard, every changed sanctioned writer/tool, and
the unchanged historical capture bytes. Human approval and independent
acceptance remain false, and no task checkbox was changed pending a second
independent review.

## Practical gate second-review closure — 2026-09-11

The second independent review found no P0/P1 issue, but rejected the preceding
snapshot for two bounded P2 omissions and one stale P3 comment. A sanctioned
writer could remain declared after being removed from its hashed current
classification; enabled starred autoload and direct literal `OS.execute`
`--script` edges were incomplete; and Sawmill still described a clamped preview
as acceptable. That snapshot remains rejected rather than accepted by this
successor record.

The repaired checker requires every sanctioned writer to belong to exactly one
applicable SHA-256-reviewed current category. Its lightweight quote/comment
lexer now separates executable GDScript literals from ordinary strings and
comments, and its bounded reference grammar covers bare or starred enabled
config paths plus direct literal `OS.execute`, `execute_with_pipe`, and
`create_process` `--script` arguments. INI `;`/`#` comments, GDScript comments,
and explanatory strings remain inert. Permanent controls cover writer-category
omission and overlap, bare/starred autoload values, comment decoys, direct
command arrays, and quoted `load(...)` text.

For every sanctioned PNG write, the manifest-declared guard's third Image
receiver must be the same direct Image receiver passed to `save_png`. The
bounded source check rejects computed receivers and any same-line work,
including a yield or state-changing call, before the write. All nine writer
paths, ten PNG calls, and three existing guarded JSON-report paths remain in
place. Sawmill's comment now states the enforced behavior: a clamped physical
preview is rejected before evidence can be written.

The source-only matrix passed the standalone gate, 20/20 focused tests, and
23/23 complete tooling tests under Python 3.8.20, 3.9.6, and 3.14.6. Both
managed changes remain strict-valid. Per instruction, this repair pass did not
start Godot, a renderer, a viewport, a contract script, or any capture/output
writer. Therefore it adds no new engine-parse, physical-framebuffer, visual, or
human-playtest evidence. Previous report and log bytes remain exact prefixes;
no task checkbox changed, human approval remains false, and independent
acceptance is pending another read-only review.

## Practical gate command/write-expression closure — 2026-09-11

A third independent Astra-max review rejected the preceding bytes with two P2
findings and no P0, P1, or P3: an `await` inside a `save_png(...)` argument could
cross a frame boundary after the physical proof, and a direct GDScript OS
command's repository-relative `--script` value was incorrectly normalized
relative to the source file. That reviewed snapshot remains rejected.

The bounded writer grammar now finds the complete balanced direct save call and
rejects lexical `await` anywhere in its argument expression. Both single-line
and multiline reproductions are permanent negative controls; quoted strings
and comments remain masked. The command-edge grammar now keeps literal
resource imports owner-relative while normalizing literal Godot `--script`
arguments from the project working directory. Permanent controls cover
repository-relative `OS.execute`, `execute_with_pipe`, and `create_process`
forms as well as `res://` and `--script=` spellings.

The source-only gate and all 20 focused and 23 complete tooling tests again
passed on Python 3.8.20, 3.9.6, and 3.14.6. No GDScript, inventory, UI, writer,
guard, output dimension, or capture artifact changed during this closure. No
Godot process, renderer, viewport, contract runner, PNG/JSON writer, screenshot,
or alternate-size command ran. Previous report/log bytes remain exact prefixes;
the task is still unchecked, human approval is false, and the successor awaits
another independent read-only verdict.

## Final exact-1920 non-capture validation — 2026-09-11

A different Astra-max reviewer accepted the frozen command/write-expression
closure with no P0, P1, P2, or P3 findings. It verified the supplied hashes,
all 27 sealed files, the prior report/log prefixes, the nine writers and ten PNG
calls, the three guarded JSON paths, and 91 additional source-only assertions.
It did not edit the candidate or invoke Godot or an evidence writer.

After that acceptance, the pinned Godot 4.7.2 executable (SHA-256
`c7cccbf8fb143e34e02fd6521e09be2c2b974f0d5db080b19071c9c570718ccf`)
completed a headless import and check-only parsed the ten changed GDScripts at
explicit `--resolution 1920x1080`; all ten exited zero with no diagnostics.
Three exact-resolution headless contracts then passed at 74/0, 124/0, and
111/0. Every capture environment variable was absent and the explicit capture
arguments were empty. The visual contract reported `frames=0` and
`HEADLESS_EVIDENCE_CAPTURE_SKIPPED`.

These are import, parse, and non-capture contract results only. The headless
visual contract used its dummy logical SubViewport, but no native renderer,
physical-framebuffer validation, screenshot, PNG/JSON writer, historical
generator, or alternate-size command ran. The seven historical capture hashes
remain unchanged. Human approval remains false and every task checkbox remains
unchanged.
