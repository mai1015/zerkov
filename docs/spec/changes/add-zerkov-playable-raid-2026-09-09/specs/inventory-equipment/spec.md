## ADDED Requirements

### Requirement: Canonical Inventory Ownership
The inventory domain SHALL be the sole owner of item instances, stack quantities, grid occupancy, containers, equipment slots, weight, and transfer state. Other domains MUST reference stable item identifiers and request inventory mutations through public commands.

#### Scenario: An item moves between containers
- **WHEN** a validated transfer command moves an item from a world container to the player's inventory
- **THEN** source removal and destination placement commit as one authoritative transaction
- **AND** the item exists in exactly one canonical location after commit

#### Scenario: A transfer cannot complete
- **WHEN** capacity, grid fit, ownership, range, or policy validation fails
- **THEN** no canonical inventory state changes
- **AND** the requester receives a stable rejection reason

### Requirement: Snapshot-driven Inventory Interface
Inventory, loot, stash, and equipment screens SHALL render immutable projections of canonical inventory state. Interface widgets MUST submit intents and MUST NOT directly mutate item resources, grids, equipment slots, or profile data.

#### Scenario: The player drags an item
- **WHEN** the pointer releases a dragged item over a candidate destination
- **THEN** the interface emits a transfer intent containing stable identifiers and the proposed placement
- **AND** the displayed state changes only from a subsequent authoritative projection

#### Scenario: Authority rejects a drag
- **WHEN** the transfer intent is rejected
- **THEN** the interface restores or animates toward the latest authoritative placement
- **AND** presents the stable rejection reason without inventing a local item state

### Requirement: World-policy Validated Loot Transfers
Transfers involving world containers or bodies SHALL include raid policy validation for actor eligibility, target identity, interaction range, access state, and current ownership. A stale or replayed request MUST NOT duplicate or resurrect an item.

#### Scenario: Two actors request the same item
- **WHEN** competing valid requests target one canonical item instance
- **THEN** authority accepts at most one transfer according to deterministic ordering
- **AND** all clients receive the resulting canonical location

#### Scenario: A completed request is replayed
- **WHEN** an already-processed transfer command is submitted again with the same command identifier
- **THEN** the original result is returned or ignored idempotently
- **AND** item quantity and ownership remain unchanged

### Requirement: Atomic Reload Reservation
Reloading SHALL use an explicit reservation contract between the weapon and inventory domains. Ammunition selection, removal, chamber or magazine update, cancellation, and rollback MUST produce one consistent authoritative result across both domains.

#### Scenario: A reload completes
- **WHEN** a valid reload reaches its authoritative commit point
- **THEN** reserved ammunition is consumed exactly once
- **AND** the weapon ammunition state and inventory quantity are committed atomically

#### Scenario: A reload is interrupted before commit
- **WHEN** death, weapon swap, invalidation, or another authoritative interruption cancels the reload
- **THEN** uncommitted ammunition reservations are released
- **AND** no ammunition is lost or duplicated

### Requirement: Equipment and Ability Reconciliation
Equipment changes SHALL reconcile granted abilities and modifiers through a game-owned adapter. Reconciliation MUST be idempotent, based on canonical equipped-item identifiers, and able to remove effects when equipment is unequipped, destroyed, or invalidated.

#### Scenario: Equipment grants an ability
- **WHEN** an item with declared ability grants becomes authoritatively equipped
- **THEN** the adapter grants the declared ability set once
- **AND** records the source item identifier for later reconciliation

#### Scenario: The same equipment projection is processed twice
- **WHEN** reconciliation receives an unchanged equipped-item projection more than once
- **THEN** no duplicate ability, modifier, or gameplay effect is created

