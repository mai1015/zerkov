## ADDED Requirements

### Requirement: Confirmed equipment controls world weapon presentation
The in-world character SHALL display the supported equipped weapon from the same committed identity used by combat, and SHALL clear it on unequip, death or binding release. Unsupported or missing equipment MUST NOT display fixture gear.

#### Scenario: Unequip and restore a primary weapon
- WHEN the player unequips the primary item through Character and resumes the raid
- THEN its world firearm and firing context are absent after authoritative reconciliation
- AND re-equipping the same item restores the same weapon identity without replenishing ammunition.

### Requirement: Shot feedback follows committed combat
Visible shot feedback SHALL originate from a committed shot and use the existing resolver's value-only result. Presentation MUST NOT resolve collisions, cause damage or consume ammunition. Duplicate or stale frames MUST NOT replay an effect.

#### Scenario: Fire and reload through ordinary input
- WHEN the player fires and reloads the equipped weapon using gameplay input
- THEN authoritative ammunition and receipts determine the displayed results
- AND a rejected or dry trigger produces no successful muzzle/shot effect
- AND an actual hit's damage is confirmed by the health owner.

### Requirement: End-to-end equipment gameplay evidence
Equipment gameplay acceptance SHALL exercise the normal local application, actual input, a real target and unchanged native addons. Inventory-only tests MUST NOT be described as proof of rendered weapon or shooting behavior.

#### Scenario: Record the equipped weapon in a raid
- WHEN an automated native gameplay recording is published
- THEN it identifies its source revision and capture timing
- AND distinguishes functional/visual evidence from real-time FPS or final animation-art acceptance.
