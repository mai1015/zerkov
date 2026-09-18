## ADDED Requirements

### Requirement: Scene-backed offline map deployment
The application SHALL preflight a known saved map and copy its authored geometry
and gameplay markers before committing equipment escrow. The runtime MUST use
the existing canonical raid owners, not an inspection walker.

#### Scenario: Missing or invalid map
- **WHEN** source, markers, production-body navigation or geometry validation fails
- **THEN** deployment MUST reject without changing saved loadout or allocating a raid.

#### Scenario: Authored scene edits
- **WHEN** a designer saves a moved prop or collision segment
- **THEN** preflight SHALL consume the new native geometry rather than an old JSON layout.

### Requirement: Map-scoped task and persistence identity
The same map descriptor SHALL identify deployment, task targets and its committed
receipt. Existing Sawmill records without this optional field MUST remain valid.

#### Scenario: Cross-map request retry
- **WHEN** a prior request identity is reused with another map descriptor
- **THEN** deployment SHALL reject without new escrow or a misleading prior success.

#### Scenario: Crash recovery
- **WHEN** a saved native-map raid was interrupted
- **THEN** recovery MUST retain its map identity and apply existing abandonment rules
- **AND** SHALL NOT load the world or resume uncommitted gameplay to recover a profile.

### Requirement: Production input and honest presentation
Only the current home briefing SHALL admit a finite map selection/deployment command.
Views MUST derive labels, markers and task state from the selected or committed map.

#### Scenario: Map change during a raid
- **WHEN** a delayed home selection arrives during a live or settling raid
- **THEN** it MUST leave that raid's map, task, items and save record unchanged.
