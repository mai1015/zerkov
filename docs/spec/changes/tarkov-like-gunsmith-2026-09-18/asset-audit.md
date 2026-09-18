# Asset audit — zerkov.zip weapon breadth

Archive SHA-256: `ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006`

This audit is discovery evidence only. It does not grant release/provenance clearance and does not infer real-world weapon identities.

## Firearm families

- AR1–AR8: **8**
- SMG1–SMG8: **8**
- P1–P7: **7**
- SG1–SG5: **5**
- SN1–SN4: **4**
- Total firearm families: **32**

Across those families the archive contains **84 PNG layers**. Every inspected family layer is exactly **96x32**, making deterministic same-canvas Gunsmith composition feasible.

Family-specific layers include combinations of:

- base gun
- barrel
- stock
- grip
- scope

Coverage differs by family; missing layers SHALL remain absent rather than synthesized.

## Generic attachments

The `Weapons Inventory/Attachments` folder contains **62 PNGs**:

- optics: 10
- stocks: 10
- grips: 10
- barrels: 10
- muzzle variants: 20
- lasers: 2

The source naming divides them exactly into **31 small** and **31 large** assets. This is useful candidate metadata, but runtime compatibility SHALL come from reviewed definitions rather than parsing filenames.

## Melee

The source pack contains five melee inventory items:

- pipe
- bat
- knife
- machete
- axe

They are catalog candidates but are not part of firearm attachment mechanics in this proposal.

## Presentation limitation

The source pack does not provide a general skeletal weapon-holding rig. The currently reviewed AKM path has dedicated holding-arm art, and the knife attack uses matched frame sheets. The other firearm families therefore require explicit held-pose profiles before raid deployment. Gunsmith preview coverage SHALL NOT be interpreted as in-raid visual approval.
