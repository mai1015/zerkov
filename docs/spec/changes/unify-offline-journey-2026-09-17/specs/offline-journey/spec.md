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
