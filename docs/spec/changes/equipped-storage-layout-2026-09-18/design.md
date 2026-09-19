# One scrolling carried section; one authored Quick Use design

Keep the shared global header and Gear/Health/Stats tabs. Reparent the existing
live widgets into one vertical ScrollContainer in this order: Pockets, Rig,
Backpack, Secure. Stash/opened loot keep an independent counterpart scroll.
The character and original Quick Use row remain stationary; center the 602px
Character group in its 748px pane. The new composition is qualified at exactly
1920x1080, not as a new compact-window design.

## No gear means no grid

WearableStoragePolicy uses the current catalog and matching item in its named
equipment slot. Grid size and rendering are both gated. Empty equipment targets
remain available, but grid nodes are cleared, disabled and hidden. An event-driven
visibility guard prevents inherited reflow from restoring those cells. This
also applies to legacy contents: they are not an exception granting a grid.

The local mutation adapter independently rejects incoming move/loot/split/merge
into unworn storage and prevents self-storage or removal of a filled provider.
The generic adapter retains all existing actor, identity, epoch, revision,
world-access, replay and native-receipt checks. Two small protected hooks permit
the game-owned automatic destination policy without changing generic behavior.

Legacy contents use named recovery buttons outside any grid. An actual click
captures the current projected item, chooses valid pockets/equipped capacity
and submits the ordinary revision-checked move. No original item is deleted,
no free bag is granted, and a repeated/stale recovery cannot repeat the move.
If no space is available, the move fails without mutation; make room or equip
the matching gear. No profile migration is performed.

Native quick-transfer cannot filter eligible root containers. With either
wearable absent, choose one whole-stack spatial placement in pockets/worn
storage and call one atomic native loot_item operation. No mutate/rollback or
fabricated receipt. This restricted path has no automatic partial split or
cross-inventory stack merge. Both-worn and non-player destinations keep the
original native quick-transfer behavior for loose items. Worn providers require
explicit equipment/move actions; automatic transfer cannot select its own root
or detach a filled provider, including across inventories.

## Reuse Quick Use, do not replace it

AuthoredQuickUse reuses QuickUseTitle and QuickSlot5–8 from the unchanged
character_workspace.tscn. Character reparents its existing instances. HUD takes
the same authored controls from an off-tree scene instance; the preview scene
is never mounted, so its fixture controller never runs. There is one visual
source rather than another handwritten set of boxes. Retire the off-tree scene
owners before reparenting. A plain Control wrapper pins the row 14px above the
bottom and introduces no new artwork or input handler.

Keep the numbered item-slot appearance. Hide sample bottle/counts; disabled
assignments are explicitly unavailable. Do not relabel these slots as Fire,
Reload or other unrelated commands. The existing feedback owner reserves the
row's height so toasts do not cover its keys. Unbound 1/2/3 weapon HUD samples
remain hidden in the production local view.

## Tests and fixture boundaries

A clean New/Continue profile begins without gear and must show no rig/pack cells
even after repeated refresh/reflow or attempted show(). Declared native test
gear then enables the correct grids, removal hides them, and whole-column
scrolling reaches Secure without moving Character. Two declared legacy-item
fixtures verify no grid and actual-button recovery with replay rejection.

Older equipment/loot tests assumed permanent backpack capacity. They now equip
an explicit test daypack rather than use phantom capacity. Loot first fills
real pockets and verifies rejection/no mutation, then uses that test bag to
continue draining the real crate. The equipment test preserves the same bag
through save/relaunch and exercises existing native drag/drop, including secure
to pockets across scroll positions. These fixtures do not change the starter kit.
