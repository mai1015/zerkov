## MODIFIED Requirements

### Requirement: Authored Bunker Presentation
The bunker route SHALL display an authored cutaway built from the supplied
kit rather than the temporary map backdrop. Room identities MUST be stable.
The player SHALL be able to walk that cutaway rather than only inspect it, and
the room description SHALL follow where the player stands. Walking MUST NOT
mutate gameplay state: the bunker runs no raid authority and writes no save.

#### Scenario: Walk into a facility
- **WHEN** the player walks the operator into a valid room
- **THEN** the matching authored room description and station art are shown
- **AND** `station_entered` is emitted with that room id
- **AND** no gameplay state is mutated.

#### Scenario: Leave every room
- **WHEN** the operator stands where no room is defined
- **THEN** `station_left` is emitted
- **AND** the previous room's description is not re-emitted on re-entry
  without first leaving.

#### Scenario: Walls and props block movement
- **WHEN** the operator walks into a wall or prop footprint on one axis
- **THEN** movement along that axis stops
- **AND** movement along the other axis continues.

#### Scenario: Reject unprovenanced player artwork
- **WHEN** a player art source does not match its manifest sha256
- **THEN** the operator is not created and the hideout remains inspectable
- **AND** no partially composed player figure is displayed.

### Requirement: Independent World Lighting and Honest Availability
The world SHALL render at 640x360 with exact 3x nearest enlargement inside a
1920x1080 interface. Cosmetic lighting MUST NOT affect interface text or
claim that power, crafting or progression services are operational. The
bunker scene MUST NOT retain authored station nodes that are hidden on every
entry; an unavailable facility is stated in text, not drawn and then hidden.

#### Scenario: Toggle lighting preview
- **WHEN** the emergency lighting preview is selected
- **THEN** world illumination changes while interface rendering remains stable
- **AND** build, crafting and upgrade functions remain explicitly unavailable.

#### Scenario: No hidden placeholder layout
- **WHEN** the bunker scene is loaded
- **THEN** it contains no station nodes whose only runtime behavior is to be
  hidden by the hideout screen.
