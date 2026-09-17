## ADDED Requirements

### Requirement: Reuse the authored bunker workspaces
The local campaign SHALL open the authored Crafting, Build Mode and Session
routes from its single bunker hub. Primary storage, health and planning actions
SHALL retain their approved behavior.

#### Scenario: Return from a workstation
- WHEN a player closes one of these workspaces
- THEN CommonUI returns to the same campaign bunker with the selected room retained
- AND no additional campaign or inventory authority is created

### Requirement: No fixture mechanics in production
The workspaces SHALL read current immutable projections and SHALL NOT initialize
fixture state, execute sample timers or display fictional prices, ingredients,
outputs, invite codes or occupants as live data. Unavailable mechanics SHALL
remain visibly disabled without changing the production feature gates.

#### Scenario: Try an unavailable craft or placement
- WHEN a player presses a sample craft, collect, place, rotate or invite control
- THEN no inventory, profile, world state or fixture document is mutated
- AND the screen explains which service is unavailable

### Requirement: Home-bound commands
Opening a bunker workspace SHALL require a current home presentation epoch and
live home inventory. The application root SHALL reject requests in other modes.

#### Scenario: Retired home request
- WHEN a retained command is used after returning to the menu or deploying
- THEN it cannot navigate, create a second owner or restore a retired workspace
