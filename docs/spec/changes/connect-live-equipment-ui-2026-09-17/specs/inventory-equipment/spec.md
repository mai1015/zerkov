## MODIFIED Requirements

### Requirement: Snapshot-driven Inventory Interface
Inventory, loot, stash, secure-container, and equipment screens SHALL render immutable projections of canonical inventory state. Equipment projections SHALL include canonical named-slot occupancy from the current loadout inventory and SHALL represent empty declared slots without fabricating item identities. Interface widgets MUST submit intents and MUST NOT directly mutate item resources, grids, equipment slots, or profile data.

#### Scenario: The player equips an item
- **WHEN** the player selects a compatible loadout item and a declared canonical equipment slot
- **THEN** the interface emits an equip intent containing stable inventory/item identity, the confirmed inventory revision, and the declared destination slot
- **AND** the displayed slot changes only after an authoritative accepted projection is published

#### Scenario: The player unequips an item
- **WHEN** the player requests that a canonical equipped item move to a valid loadout destination
- **THEN** the interface emits an unequip intent through the authority seam
- **AND** rejection leaves the confirmed equipment and destination unchanged

#### Scenario: A slot is not part of the canonical profile
- **WHEN** the authored Character screen contains a visual gear slot that the current equipment profile does not declare
- **THEN** live mode marks that slot unavailable or empty
- **AND** MUST NOT display a fixture item, fixture ammunition count, or emit an equipment mutation for that slot

#### Scenario: Secure-container contents are displayed
- **WHEN** the loadout contains the canonical secure container
- **THEN** its current spatial contents are projected from the same confirmed loadout snapshot
- **AND** UI actions use the same intent-only mutation boundary as other loadout containers

### Requirement: Canonical Equipment Intent Admission
Equip and unequip operations SHALL be admitted only against the current canonical loadout inventory, owner generation, inventory revision, item identity, container identity, and a named slot declared by the authoritative equipment profile. Runtime entity-identity grammar MUST NOT be used as a substitute for catalog slot validation.

#### Scenario: A valid authored slot is requested
- **WHEN** an equip intent names `zerkov.slot.weapon_primary` or another slot declared by the current equipment container and the item satisfies native compatibility rules
- **THEN** the request reaches the native Inventory authority exactly once
- **AND** the accepted native receipt becomes the source of the subsequent confirmed projection

#### Scenario: An unknown or incompatible slot is requested
- **WHEN** an equip intent names a slot absent from the current equipment container or the item does not satisfy its required traits
- **THEN** the operation is rejected before or by authoritative inventory validation
- **AND** no item is removed, duplicated, locally repaired, or displayed as equipped

### Requirement: Local Equipment Persistence
Accepted home equipment changes SHALL use the existing local campaign persistence boundary and SHALL be the loadout deployed into the next raid. The interface MUST NOT seed starter equipment, substitute fixture equipment, or create a second equipment save representation.

#### Scenario: Equipment is changed and the application relaunches
- **WHEN** the player changes canonical equipment at home, leaves the workspace through the normal save boundary, and relaunches the same local profile
- **THEN** the equipment projection reflects the persisted canonical loadout
- **AND** the next deployment instantiates the same loadout record

#### Scenario: Saving the loadout fails
- **WHEN** an equipment change is authoritative in memory but the local profile write fails
- **THEN** the existing local-save failure/retry policy applies
- **AND** the UI MUST NOT claim the changed loadout is durable until the profile commit succeeds
