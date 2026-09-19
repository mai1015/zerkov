# Equipped storage and the existing Quick Use row

The user approved gear-dependent rig/backpack storage, a single scrolling
carried section, secure storage last, bottom Quick Use in Character and raid,
and a vertically centered Character. Review then clarified two requirements:
**no grid without the equipped gear, including legacy contents**, and **reuse
the existing authored numbered Quick Use boxes, not a new action strip**.

This PR completes that correction on the live contextual-loot/equipment UI.
The V1 catalog still creates independent rig/backpack roots. The local admission
policy gates their use; no native package, catalog, save schema or starter kit
changes. Legacy items are preserved and exposed only as non-grid recovery rows.
A filled provider cannot be removed until emptied because V1 contents do not
travel with the item. True item-owned bag storage and bag acquisition remain
outside this pass.

The original QuickUseTitle and QuickSlot5–8 controls are the single design
source, reused at the bottom. The fixture item art/counts remain hidden and
unimplemented numbered assignments remain disabled. This does not introduce a
replacement hotbar, a new assignment backend or additional gameplay bindings.
