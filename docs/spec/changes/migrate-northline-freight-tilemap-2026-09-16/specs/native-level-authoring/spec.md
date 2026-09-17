## ADDED Requirements

### Requirement: Native editable freight source
The migrated freight slice SHALL use saved TileMapLayer, shared external TileSet
and reusable PackedScene resources as its runtime authoring truth. Runtime
startup MUST NOT regenerate placement from JSON or run an image processor.

#### Scenario: An author changes a tile or prop
- **WHEN** an author saves a painted tile and moved prop in Godot
- **THEN** their native resource changes persist on reopening
- **AND** starting the review does not overwrite those edits

### Requirement: Original asset detail
Atlas sources SHALL reference the full original PNG sheets unchanged. No
resampling, colour quantization or custom image repack SHALL be required.

#### Scenario: Art is installed
- **WHEN** the selected full sheets are copied from the approved source archives
- **THEN** their byte hashes match the recorded original sources
- **AND** the native imported RGBA data retains the original pixel data

### Requirement: Conserved logical geometry
The migrated slice SHALL retain the original logical prop placements, wall and
cover footprints and normal camera coverage. Its approved native render target
SHALL remain exactly 1920x1080, without changing the main product's render policy.

#### Scenario: A player inspects the loading entrance
- **WHEN** the review actor crosses the old south doorway
- **THEN** it can traverse the same opening and is blocked by the adjacent wall
- **AND** the camera shows the same logical-world footprint at higher native detail

### Requirement: Honest prerequisite and verification status
Missing original art SHALL block the native render gate. Serialization tests
MUST NOT be presented as completed graphical editor or product-host acceptance.

#### Scenario: The repository has not installed its original sheets
- **WHEN** the native gate is run
- **THEN** it reports the missing assets before scene startup
- **AND** it does not generate substitute textures or claim a passing visual result
