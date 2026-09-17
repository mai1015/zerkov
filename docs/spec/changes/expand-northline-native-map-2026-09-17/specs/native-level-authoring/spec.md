## ADDED Requirements

### Requirement: Full-zone native authored scene
Northline SHALL load saved native TileMapLayer, TileSet and prop resources for
all nine districts without regenerating terrain or placement from JSON at startup.

#### Scenario: Open and edit a district
- **WHEN** a designer paints a tile or moves an instance and saves the scene
- **THEN** a fresh process MUST retain that edit without running a generator
- **AND** shared prop collisions MUST move with their instance.

### Requirement: Preserve originals and logical geometry
The replacement MUST preserve complete source PNG bytes and original logical
positions, collision footprints and camera coverage. Detail rendering SHALL use
native 1920x1080 output rather than a reduced offscreen world surface.

#### Scenario: Inspect a detail view
- **WHEN** a 48px tile is rendered at normal detail zoom
- **THEN** it MUST occupy 48 output pixels without prior image resampling
- **AND** native imported RGBA MUST equal the original PNG data.

#### Scenario: Traverse the existing routes
- **WHEN** an inspection body follows each recorded cross-map path
- **THEN** every path MUST remain collision-traversable to its named exit
- **AND** the route annotation MUST NOT execute extraction or change a profile.

### Requirement: Explicit verification boundary
Native verification MUST fail source preflight when original PNGs are missing.
Source-only tests SHALL NOT be presented as a complete native render result.

#### Scenario: Verify an unprovisioned checkout
- **WHEN** any required original sheet is absent or differs from its recorded hash
- **THEN** validation MUST report BLOCKED before importing the native scene.
