## ADDED Requirements

### Requirement: Consistent operation presentation
The offline flow SHALL preserve the new bunker environment and reuse a shared visual vocabulary across preparation, briefing, deployment and committed results. Presentation SHALL NOT invent domain state or mutate gameplay owners.

#### Scenario: Deploy from briefing
- WHEN the player confirms deployment
- THEN operation identity remains recognizable through loading and raid context
- AND loading reflects real state rather than a simulated progress percentage

### Requirement: Contextual preparation return
The game SHALL return a briefing-origin equipment/health excursion to that briefing, while normal bunker-origin preparation returns to the bunker. Return context SHALL be ephemeral and retired when the home lifecycle changes.

#### Scenario: Review and edit loadout
- WHEN the player opens equipment from briefing and presses Back after visiting character tabs
- THEN the same briefing is shown without creating a raid
- AND current equipment is read from the existing immutable projection

### Requirement: Honest equipment and result summaries
Briefing equipment SHALL use current authorized projections and distinguish empty from unavailable. Results SHALL show only committed outcomes or an explicit pending-save state.

#### Scenario: Unavailable state
- WHEN an equipment projection or final save receipt is unavailable
- THEN presentation explains that state without substituting a sample kit or successful outcome


### Requirement: Shared sections and page-local details
The local application SHALL use the same section-navigation component across bunker,
Character, Tasks, Map/Briefing and Settings. Controls and character subpages SHALL
remain within page content. The raid SHALL NOT expose a Bunker navigation entry.

#### Scenario: Browse raid sections
- WHEN a player opens Character during a raid and visits Tasks, Map and Settings
- THEN the same section header and current-section state are retained
- AND Escape cancels active key capture before it can leave Settings
- AND closing the menu returns to the raid under the existing solo pause policy

### Requirement: Raid Character cannot open or disclose unrequested loot
The reused Character workspace SHALL NOT expose the home stash during a raid or
render retained world-container content when no container is explicitly open.
Opening world loot SHALL remain owned by the existing admitted interaction path.

#### Scenario: Character opened without a loot interaction
- WHEN the player opens Character with no world container open
- THEN the loot pane is empty and its tab cannot open a default container
- AND after a valid world interaction the normal opened-loot transfer remains available
