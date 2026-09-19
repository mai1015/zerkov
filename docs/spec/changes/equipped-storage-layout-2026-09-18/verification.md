# Corrected equipped-storage validation

PR #47 continues the user-approved correction. Base merge:
`6be2bf98c909c1bb9db3d780d6d70a59badbffd9`, incorporating main
`2154994e97b93e6d12510f660878b4355558117d`. The earlier local-only patch and
its replacement-action-strip screenshots are superseded, not current evidence.

## Executed local native tests

Godot `4.7.2.stable.official.ed1daf0bf`, actual native addons in an outside Linux
runtime. No native/script doubles replace production services. All changed
GDScript and scene files match the tested runtime byte-for-byte. The final
implementation commit and remote workflow status are recorded on PR #47.

| Contract | Checks / failures |
| --- | --- |
| Storage: New Game / independent Continue | 217 / 0; 110 / 0 |
| Graphical storage: New Game / Continue | 224 / 0; 112 / 0 |
| Contextual loot: New / Continue | 1317 / 0; 22 / 0 |
| Offline journey: New / Continue | 277 / 0; 137 / 0 |
| Equipment commands/projection | 201 / 0 |
| Equipped-item reconciliation | 123 / 0 |
| Inventory/ability reconciliation | 562 / 0 |
| Authored Character UI binding | 65 / 0 |
| Equipment input: create / resume / deploy | 100 / 0; 75 / 0; 98 / 0 |
| Full extraction/death/save-retry cycle | 4270 / 0 |
| Independent final profile reads | 3 / 0; 3 / 0 |

Counts include repeated tick/assertion checks, not independent scenarios. Every
runner, cleanup and required process completed with exit zero and no script or
engine errors. The initial import setup failure is retained separately; the
corrected library mapping/import was rerun before these tests.

The storage flow tests absent grids after repeated refresh/reflow/show, explicit
native fixture gear, real unequip/re-equip, full-column wheel scrolling, Secure
last, one original Quick Use row, same-scene reuse and toast clearance. It also
checks raw admission into missing storage, explicit and automatic removal of a
filled provider, automatic self-root selection, legacy-item recovery by actual
mouse clicks and rejection of repeated recovery. The test gear/legacy items are
explicit fixtures in isolated namespaces, never production starter equipment.

New/Continue headless and graphical storage runs preserve this same final
profile fingerprint:
`b7b37251d4ab1a2aa710aec07f2717eb32864f8f9d8f8643e2d17c62c0f70117`.

## Visual evidence

Nine raw 1920x1080 PNGs passed the unchanged physical output guard. Reviewed
states include no gear, native fixture gear, Secure at the scroll bottom,
legacy contents with recovery buttons and no grids, Character in raid and
original Quick Use on the live HUD. The nine raw captures and logs are delivered
in the conversation evidence packet, not committed as generated artifacts.

## Boundaries

The original Quick Use design is reused, not a new bar or assignment backend.
Slots 5-8 remain explicitly unavailable; no sample item/count is shown as real.
The V1 save format still keeps storage roots separate from provider items, so
filled providers must be emptied before removal. Restricted automatic transfer
uses whole-stack valid placement, not cross-inventory stack merging or partial
success. No profile migration, addon/engine lock, starter kit, catalog, art/font
binary or map changes.

Local Linux uses hash-verified native library artifacts and explicit extension
startup for the already documented engine cold-discovery problem. This is not
normal cold-import/export or frame-rate qualification. macOS CI uses the actual
pinned checkout addons and normal import; its status is a separate acceptance
record on the exact PR head. Final user/controller review is also separate.
