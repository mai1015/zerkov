## ADDED Requirements

### Requirement: One production bunker presentation
The campaign SHALL render one bunker map hub and SHALL NOT retain an active
placeholder station tree or restore it during reflow. Standalone art preview
SHALL remain inspection-only and SHALL NOT instantiate campaign state.

#### Scenario: Campaign enters or reflows home
- WHEN New Game, Continue or Return Home reaches the bunker
- THEN the existing authored map is the only bunker presentation
- AND reflow does not reintroduce old navigation or placeholder actions

### Requirement: Room actions use existing owners
The hub SHALL emit only navigation intents. The selected room SHALL persist
while browsing workspaces in the same presentation epoch and SHALL NOT alter
profile data. Unimplemented facility actions SHALL stay disabled and explained.

#### Scenario: Inspect medical and return
- WHEN the player selects Medical, opens Health and presses Back
- THEN the existing health workspace was used and Medical remains selected
- AND no inventory owner or save mutation was created by room selection

### Requirement: Briefing precedes deployment
The hub SHALL open the existing map briefing, not deploy immediately. The root
SHALL reject deployment requests outside that briefing or from retired epochs.

#### Scenario: Plan from the workshop
- WHEN the player selects Plan a Raid
- THEN Sawmill briefing appears with objectives and extraction conditions
- AND no raid or deployment escrow is created until the final Deploy action

### Requirement: Local campaign entry and exit
The menu SHALL offer one primary New/Continue action. Returning to the menu
from home SHALL save through the existing campaign owner and SHALL NOT reseed
an existing profile. Failed saves SHALL NOT be reported as successful exits.

#### Scenario: Close home and continue
- WHEN the player returns to the menu and continues the campaign
- THEN the same saved profile is loaded with no extra starter items
- AND old-epoch home commands cannot navigate or deploy
