## ADDED Requirements

### Requirement: Offline Default Entry
The normal application SHALL start without login, Steam or a network request and
SHALL expose a local New Game or Continue action through existing CommonUI routes.
#### Scenario: Steam or internet is absent
- **WHEN** the user starts the game
- **THEN** the title and local profile menu are usable without waiting for services.

### Requirement: Committed Local Inventory
Pre-raid edits MUST use native inventory transactions and MUST be published as
accepted only after a verified ProfileStore commit. Stale gestures MUST reject.
#### Scenario: A profile write fails before replacement
- **WHEN** a proposed move cannot be saved
- **THEN** the previous visible inventory remains and the user sees the failure.
#### Scenario: A user restarts after an accepted move
- **WHEN** Continue loads the same profile
- **THEN** native item IDs, quantities, locations and equipment are restored.

### Requirement: Safe Profile Creation
Starter content SHALL be explicit and versioned and SHALL apply only to a new
missing profile. Existing or incompatible saves MUST NOT be silently reset.
#### Scenario: A saved profile cannot be decoded
- **WHEN** Continue is attempted
- **THEN** creation remains blocked and the original files remain intact.

### Requirement: Pre-Raid Feature Boundary
Bunker entry and stash management SHALL NOT activate deployment, a raid clock,
world inventories, crafting, economy, multiplayer or escrow. Future Steam
sessions SHALL remain a separate optional integration.
#### Scenario: The player inspects an unimplemented facility
- **WHEN** the room is selected
- **THEN** inspection works but production mutation actions remain unavailable.
