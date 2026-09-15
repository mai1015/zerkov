## ADDED Requirements

### Requirement: Authored Bunker Presentation
The bunker route SHALL display an authored cutaway built from the supplied
kit rather than the temporary map backdrop. Room identities MUST be stable.

#### Scenario: Inspect a facility
- **WHEN** a user clicks a valid room or its facility button
- **THEN** the matching authored room description and station art are shown
- **AND** no gameplay state is mutated.

### Requirement: Independent World Lighting and Honest Availability
The world SHALL render at 640x360 with exact 3x nearest enlargement inside a
1920x1080 interface. Cosmetic lighting MUST NOT affect interface text or
claim that power, crafting or progression services are operational.

#### Scenario: Toggle lighting preview
- **WHEN** the emergency lighting preview is selected
- **THEN** world illumination changes while interface rendering remains stable
- **AND** build, crafting and upgrade functions remain explicitly unavailable.

### Requirement: Native Evidence
Review screenshots MUST be captured from the real Godot-rendered view with
physical window, viewport, texture and raw-image dimensions checked.

#### Scenario: Render review evidence
- **WHEN** the native capture gate runs twice
- **THEN** both runs produce exact 1920x1080 screenshots with matching hashes
- **AND** a process success with runtime diagnostics is rejected.
