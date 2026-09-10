## ADDED Requirements

### Requirement: Pinned Combined Add-on Baseline
The project SHALL record the exact source revision, semantic version, Godot compatibility, artifact availability, and enabled feature flags for every integrated add-on. The combined baseline MUST be proven in one project before feature work depends on it.

#### Scenario: Known-good add-on set loads together
- **WHEN** the project starts with the revisions recorded in the add-on lock manifest
- **THEN** all six add-ons load without registration errors, singleton collisions, or parser failures
- **AND** an automated smoke report identifies every loaded version

#### Scenario: An add-on revision changes
- **WHEN** a contributor proposes a different add-on revision
- **THEN** the combined load, version, and compatibility checks MUST pass before the manifest is updated

### Requirement: Single Raid Authority Boundary
The game SHALL own a single `RaidAuthority` boundary that coordinates cross-domain commands, canonical identifiers, authoritative time, event ordering, and raid lifecycle state. Add-ons MUST remain independently testable and MUST NOT directly reach into another add-on's private runtime state.

#### Scenario: A cross-domain action is requested
- **WHEN** inventory, weapons, abilities, AI, tasks, or extraction need another domain to change
- **THEN** the initiating domain emits an intent or contract request to `RaidAuthority`
- **AND** `RaidAuthority` validates and routes the operation through a game-owned adapter

#### Scenario: A domain is tested alone
- **WHEN** an add-on test runs without the Zerkov game layer
- **THEN** the add-on can execute against its own public interfaces or test doubles without loading unrelated add-ons

### Requirement: Canonical Simulation Contract
The authoritative simulation SHALL use one 60 Hz tick, stable entity and item identifiers, explicit seeded randomness, and documented canonical units for distance, time, mass, quantity, and damage. State-changing outcomes MUST be ordered by authoritative tick and sequence number rather than render-frame timing.

#### Scenario: Multiple intents arrive in one tick
- **WHEN** two or more accepted intents affect the same resource during one authoritative tick
- **THEN** the system applies them in a deterministic sequence
- **AND** records the chosen order for replay and diagnosis

#### Scenario: Presentation frame rate changes
- **WHEN** rendering runs above, below, or independently of 60 frames per second
- **THEN** authoritative gameplay outcomes remain unchanged for the same input stream and seed

### Requirement: Deterministic Event Journal
The game SHALL maintain an append-only raid event journal containing authoritative identifiers, ticks, sequence numbers, accepted consequences, and settlement boundaries. Replaying a captured journal against the same content version and seed MUST reproduce the same authoritative raid result.

#### Scenario: A raid defect is reproduced
- **WHEN** a developer loads the raid seed, content revision, initial profile projection, and recorded accepted intents
- **THEN** the resulting authoritative event sequence and final raid outcome match the captured journal

#### Scenario: Presentation emits a duplicate signal
- **WHEN** the same client-side animation or UI signal is delivered more than once
- **THEN** the journal contains no duplicate authoritative consequence

