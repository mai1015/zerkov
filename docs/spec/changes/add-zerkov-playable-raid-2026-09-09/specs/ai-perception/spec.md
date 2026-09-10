## ADDED Requirements

### Requirement: Vision-owned Perception Facts
The vision domain SHALL be the authoritative source for current visibility and last-confirmed visual observations. Perception evaluation MUST use explicit occluders, observer parameters, deterministic query inputs, and a measurable per-tick budget.

#### Scenario: A target becomes occluded
- **WHEN** valid occluder geometry blocks line of sight
- **THEN** current visibility becomes false according to the configured perception cadence
- **AND** any retained observation is labeled as memory rather than live vision

#### Scenario: Perception load exceeds budget
- **WHEN** observer-target work exceeds the declared per-tick budget
- **THEN** work is deferred by a deterministic scheduling policy
- **AND** telemetry exposes the over-budget condition without changing facts based on render frame rate

### Requirement: No Hidden Live-target Knowledge
AI decision code SHALL consume only current visible facts, remembered observations with timestamps and confidence, audible facts, and explicitly shared team knowledge. It MUST NOT read an unseen target's live transform, velocity, health, inventory, or input state.

#### Scenario: The player leaves sight
- **WHEN** an AI loses current visibility of the player
- **THEN** pursuit or search uses the last confirmed observation and allowed inference
- **AND** subsequent hidden player movement is not reflected until a permitted new observation occurs

#### Scenario: Debug tooling inspects hidden state
- **WHEN** a debug overlay displays ground-truth target data
- **THEN** that data is visibly marked diagnostic
- **AND** it is unavailable to production decision inputs

### Requirement: Separate Hearing and Noise Channel
The game layer SHALL own a hearing and noise channel distinct from visual perception. Noise events MUST declare source identity, authoritative position, tick, intensity, category, and propagation policy, while AI receives only the resolved audible fact allowed by that policy.

#### Scenario: A gunshot creates noise
- **WHEN** an authoritative firearm event emits a configured noise
- **THEN** eligible listeners receive a resolved audible observation
- **AND** the event does not automatically grant visual confirmation or precise live tracking

#### Scenario: A presentation sound plays locally
- **WHEN** UI or cosmetic audio plays without an authoritative noise event
- **THEN** AI hearing state remains unchanged

### Requirement: Deterministic AI Intents
AI decision logic SHALL emit the same ordered gameplay intents for the same authoritative observations, internal state, seed, and tick sequence. AI MUST request movement, attacks, interactions, and ability use through the same validated authority contracts used by human-controlled actors.

#### Scenario: An encounter is replayed
- **WHEN** the same raid seed and authoritative observation stream are replayed
- **THEN** the AI produces the same decision transitions and ordered intent stream

#### Scenario: An AI attack is invalid
- **WHEN** an AI requests an attack outside the accepted range, timing, or resource rules
- **THEN** authority rejects it using the normal combat contract
- **AND** the AI receives a stable rejection or updated projection

