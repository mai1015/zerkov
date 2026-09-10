## ADDED Requirements

### Requirement: Complete Raid Lifecycle
The game SHALL model raid setup, loading, active play, extraction countdown, terminal resolution, settlement, and summary as explicit authoritative states. Each transition MUST declare allowed triggers, cancellation rules, persisted effects, and idempotency behavior.

#### Scenario: A normal raid succeeds
- **WHEN** the player satisfies extraction policy and the countdown completes
- **THEN** the raid reaches one terminal extracted outcome
- **AND** settlement completes before the summary is treated as final

#### Scenario: Conflicting terminal events occur
- **WHEN** death and extraction completion are requested near the same authoritative tick
- **THEN** deterministic ordering and policy select exactly one terminal outcome
- **AND** settlement runs once for that outcome

### Requirement: Staged Supply Run Task
The first playable slice SHALL include a Supply Run task with explicit accept, objective-progress, turn-in or extraction, failure, reward, and persistence states. The task system MUST consume game-owned events and MUST NOT inspect private inventory, combat, or scene-tree state directly.

#### Scenario: The required supplies are obtained
- **WHEN** canonical inventory events satisfy the task's declared item and quantity conditions
- **THEN** task progress updates from those events
- **AND** duplicate events do not increment progress twice

#### Scenario: The player exits under a failing condition
- **WHEN** the raid ends without satisfying the task's configured success policy
- **THEN** the task enters its declared retained, failed, or reset state
- **AND** the summary explains the applied policy

### Requirement: Explicit Extraction and Death Policy
The playable slice SHALL define which carried items, secured items, equipment, task items, injuries, and rewards persist for extracted and dead outcomes. Settlement MUST apply the documented policy from canonical pre-settlement state, not from screen state or presentation callbacks.

#### Scenario: The player extracts
- **WHEN** an extracted raid settles
- **THEN** eligible carried loot and task outcomes are committed to the profile exactly as declared
- **AND** the raid instance can no longer mutate profile-bound results

#### Scenario: The player dies
- **WHEN** a dead raid settles
- **THEN** loss, secure-container, equipment, injury, and task policies are applied consistently
- **AND** no extracted-only reward is granted

### Requirement: Atomic Idempotent Settlement
Raid settlement SHALL commit profile inventory, task progress, currency or rewards, health consequences, and raid history as one recoverable transaction. Repeating the same settlement identifier MUST return the committed result without duplicating, dropping, or partially applying value.

#### Scenario: Persistence fails during settlement
- **WHEN** storage fails before the transaction commits
- **THEN** no partial profile result is exposed as final
- **AND** retrying the same settlement can complete safely

#### Scenario: A completed settlement is retried
- **WHEN** the same settlement identifier is submitted after a successful commit
- **THEN** the stored outcome is returned
- **AND** item, reward, task, and history values are not applied again

### Requirement: Audit-backed Raid Summary
The raid summary SHALL be derived from the terminal outcome and committed settlement record. It MUST expose enough stable evidence to reconcile extraction status, kills, damage, injuries, loot value, task progress, rewards, losses, duration, and exceptional corrections.

#### Scenario: The summary opens after settlement
- **WHEN** a raid has a committed settlement record
- **THEN** the summary renders an immutable projection of that record
- **AND** leaving or reopening the screen does not change the committed outcome

#### Scenario: A value cannot be reconciled
- **WHEN** summary data conflicts with the event journal or settlement record
- **THEN** the inconsistency is logged with stable raid and settlement identifiers
- **AND** the interface does not silently invent a replacement value

