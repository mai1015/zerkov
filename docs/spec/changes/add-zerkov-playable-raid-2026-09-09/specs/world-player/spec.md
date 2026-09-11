## ADDED Requirements

### Requirement: Authored Sawmill Raid Space
The first playable raid SHALL use an authored Sawmill Yard map with explicit gameplay layers for terrain, obstacles, navigation, vision occluders, loot anchors, spawn anchors, extraction zones, encounter anchors, and presentation dressing. Gameplay anchors MUST use stable identifiers and MUST NOT depend on scene-tree order.

#### Scenario: The raid is instantiated
- **WHEN** a Sawmill Yard raid starts with a valid seed
- **THEN** the player, enemies, loot, task target, and Road Gate extraction are resolved from stable authored anchors
- **AND** decorative changes do not alter those identities

#### Scenario: An anchor is invalid
- **WHEN** required anchors overlap illegally, reference missing content, or fall outside navigable space
- **THEN** the validation suite fails with the anchor identifier and actionable location information

### Requirement: Authoritative Player Locomotion
Player movement, collision, facing, stance, and interaction eligibility SHALL be resolved by the authoritative simulation. Visual interpolation and animation MUST follow resolved state and MUST NOT move the authoritative body or grant interaction range.

#### Scenario: The player collides with world geometry
- **WHEN** movement input would cross a blocking collider
- **THEN** the authoritative body remains in the valid resolved position
- **AND** the visual representation converges to that position without creating a second collision outcome

#### Scenario: The player requests an interaction
- **WHEN** an interaction intent targets a loot container, body, door, or extraction zone
- **THEN** authority validates identity, range, line of interaction, and current eligibility before changing state

### Requirement: Independent World and Interface Presentation
The game SHALL render the pixel-world presentation independently from the crisp interface layer. World scaling, camera shake, hit stop, color treatment, and pixel snapping MUST NOT distort interface layout, text legibility, pointer mapping, or safe-area behavior.

#### Scenario: Combat presentation affects the world camera
- **WHEN** recoil, damage, or an explosion applies camera shake or hit stop
- **THEN** the HUD and menus remain stable and readable
- **AND** gameplay input coordinates continue to resolve correctly

#### Scenario: The game runs at the first-playable output
- **WHEN** the viewport is 1920x1080
- **THEN** the 640x360 world presentation uses its declared exact 3x pixel-scaling policy
- **AND** the interface remains an independent crisp 1920x1080 composition
- **AND** smaller-output scaling and adaptive layout remain deferred

### Requirement: Explicit Vision Occlusion Bake
Vision-blocking geometry SHALL be authored or generated as an explicit, inspectable occluder representation consumed by the perception system. The bake process MUST be deterministic for unchanged source geometry and MUST expose invalid or ambiguous occluders before a raid ships.

#### Scenario: Level geometry is rebaked
- **WHEN** unchanged Sawmill source geometry is processed twice
- **THEN** both bakes produce equivalent occluder data and identifiers

#### Scenario: An occluder is malformed
- **WHEN** a wall or obstacle produces invalid occlusion geometry
- **THEN** validation identifies the source object
- **AND** the raid is not marked release-ready until the issue is resolved or explicitly waived
