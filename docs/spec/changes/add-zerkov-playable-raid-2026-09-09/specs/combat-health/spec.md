## ADDED Requirements

### Requirement: Explicit Combat Ownership Boundaries
The weapon domain SHALL own weapon state and firing cadence, the world domain SHALL own spatial queries and collision facts, the ability domain SHALL own applied gameplay effects, and the game layer SHALL translate facts between them. No presentation event or foreign domain MUST apply a second authoritative combat consequence.

#### Scenario: A firearm attack resolves
- **WHEN** authority accepts a fire intent
- **THEN** the weapon domain advances canonical weapon state
- **AND** the world domain returns hit facts
- **AND** the game adapter requests exactly one corresponding ability or health consequence

#### Scenario: A tracer animation repeats
- **WHEN** presentation restarts or duplicates a tracer, muzzle flash, or impact effect
- **THEN** ammunition, hit facts, and damage remain unchanged

### Requirement: Body-zone Health and Injuries
The playable slice SHALL model head, thorax, abdomen, left arm, right arm, left leg, and right leg as authoritative health zones. Damage, overflow policy, bleeding, fractures, pain, movement effects, healing eligibility, and death conditions MUST be data-defined and covered by deterministic tests.

#### Scenario: A projectile damages a body zone
- **WHEN** an authoritative hit maps to a valid body zone
- **THEN** the zone receives the declared damage and secondary-effect evaluation exactly once
- **AND** the resulting whole-body state is published in the next projection

#### Scenario: A lethal condition is reached
- **WHEN** the configured lethal-zone or aggregate death rule becomes true
- **THEN** the actor enters the authoritative dead state once
- **AND** further healing or combat intents are rejected according to policy

### Requirement: Idempotent Combat Consequences
Every accepted attack and applied consequence SHALL carry stable command and event identifiers. Duplicate delivery, prediction correction, animation callbacks, or reconnect replay MUST NOT consume ammunition, apply damage, spawn loot, or trigger death more than once.

#### Scenario: The same hit result arrives twice
- **WHEN** an already-applied hit event is delivered again
- **THEN** the second delivery is recognized as a duplicate
- **AND** health and secondary effects remain at the original authoritative result

#### Scenario: A predicted shot is rejected
- **WHEN** local presentation predicts a shot that authority rejects
- **THEN** canonical ammunition and target health follow authority
- **AND** reversible presentation is corrected without applying compensating gameplay damage

### Requirement: Reversible Combat Presentation
Recoil, camera impulse, animation, audio, decals, particles, hit markers, floating feedback, and hit stop SHALL consume authoritative or explicitly predicted presentation events. Predicted presentation MUST be reversible or replaceable and MUST remain consequence-free.

#### Scenario: An accepted shot is confirmed
- **WHEN** authority confirms a locally predicted shot
- **THEN** presentation reconciles without visibly playing the same one-shot effect twice

#### Scenario: Latency changes
- **WHEN** confirmation timing varies within the supported network envelope
- **THEN** combat feedback remains readable
- **AND** authoritative cadence, damage, and movement are unaffected by visual timing

### Requirement: Authoritative Melee Timing
Melee wind-up, active window, target query, stamina or resource cost, recovery, cancellation, and consequence application SHALL use authoritative tick timing. Animation events MAY request presentation cues but MUST NOT define the sole source of hit validity.

#### Scenario: A melee swing intersects a target
- **WHEN** the target is valid during the authoritative active window
- **THEN** the attack applies at most one configured consequence to that target for that swing

#### Scenario: The attacker is interrupted
- **WHEN** an authoritative interruption occurs before the active window or commit point
- **THEN** the configured cancellation policy is applied deterministically
- **AND** a late animation callback cannot restore the attack

