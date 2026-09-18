## ADDED Requirements

### Requirement: Contextual loot workspace
A local Character screen SHALL NOT display a loot tab, empty loot workspace, loot search or filter controls when no container is open. Home stash presentation SHALL remain available only at home. Player equipment positions SHALL remain stable.

#### Scenario: Character opened away from loot
- WHEN the player opens Character with no active or nearby eligible crate
- THEN only their own inventory is presented and no “No container open” error appears
- AND retained world contents are not disclosed or made interactive

### Requirement: Nearby is an interaction hint, not remote inventory
The Nearby card SHALL use only the current world-policy-eligible crate metadata and SHALL NOT expose contents, counts or values before an admitted open. LocalGame SHALL revalidate phase, route, epoch, modal and current target before Search/Open.

#### Scenario: Search nearby crate
- WHEN the player activates Search from Character
- THEN the existing canonical search intent is queued and gameplay resumes
- AND no items are revealed before search completion and a subsequent valid open

### Requirement: Distinct empty and unavailable states
An open, ready container with zero items SHALL be distinguished from a filter with no matches, a closed container and unavailable data. Closing SHALL retain canonical inventory while retiring view interaction and hidden focus targets.

#### Scenario: Clear a filter or close loot
- WHEN filtering hides all rows in a nonempty container
- THEN the UI offers clear filters and does not call the container empty
- WHEN the player closes loot or leaves the Character family
- THEN its controls disappear and focus remains on a visible control
