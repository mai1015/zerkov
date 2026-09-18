## MODIFIED Requirements

### Requirement: Intent-only Interface State
Production interface code SHALL render immutable view models derived from authoritative domain projections and SHALL communicate changes through declared intents. The current prototype `app.state` MAY remain as fixture or development data but MUST NOT be rendered as canonical gameplay/profile state when the corresponding production projection is available.

#### Scenario: Live equipment is available
- **WHEN** the Character Gear screen is bound to a current production inventory projection
- **THEN** every supported equipment slot renders its canonical item or canonical empty state
- **AND** fixture weapon names, fixture ammunition counts, and fixture-only item icons are not presented as live equipment

#### Scenario: An authored slot has no production capability
- **WHEN** the visual screen contains a slot not declared by the current canonical equipment profile
- **THEN** the screen identifies that slot as unavailable or empty
- **AND** disables profile-affecting actions for it without substituting preview state

#### Scenario: Equipment mutation is pending or rejected
- **WHEN** an equip/unequip intent has not yet produced an accepted confirmed projection
- **THEN** presentation may show reversible pending feedback
- **AND** MUST NOT commit a local slot arrangement that differs from the latest authoritative projection
