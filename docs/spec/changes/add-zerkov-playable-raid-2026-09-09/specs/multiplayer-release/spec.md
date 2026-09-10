## ADDED Requirements

### Requirement: Offline-first Readiness Gate
Multiplayer implementation SHALL remain gated until the offline authoritative vertical slice passes its acceptance suite, deterministic replay checks, and atomic settlement tests. Network transport MUST wrap proven authority contracts rather than introduce a second gameplay ruleset.

#### Scenario: Network work is proposed early
- **WHEN** an online feature depends on an offline contract that is not yet accepted
- **THEN** the task remains blocked or limited to non-binding experiments
- **AND** the authoritative offline contract is completed first

#### Scenario: The gate is opened
- **WHEN** the declared offline acceptance evidence passes on the pinned content and add-on baseline
- **THEN** session, replication, prediction, and reconnect tasks may enter implementation

### Requirement: Hardened Session Admission and Command Scope
The server SHALL authenticate or explicitly identify a session, bind actors and profiles to authorized peers, validate every client-originated command, rate-limit abuse-sensitive paths, and scope replicated data to permitted recipients. Client claims MUST NOT directly grant items, damage, rewards, task completion, extraction, or profile settlement.

#### Scenario: A client submits an unauthorized command
- **WHEN** a peer targets another actor's inventory, identity, settlement, or inaccessible world object
- **THEN** the server rejects the command
- **AND** records security-relevant context without leaking restricted state

#### Scenario: A client floods a command path
- **WHEN** traffic exceeds the configured cadence or budget
- **THEN** excess work is rejected or throttled deterministically
- **AND** authoritative simulation remains available to compliant peers

### Requirement: Replication, Prediction, and Reconnect Contract
The network layer SHALL replicate authoritative projections and ordered events using stable identities and sequence information. Prediction MUST be limited to declared reversible presentation or movement paths, while reconnect MUST restore a consistent permitted snapshot without replaying committed consequences.

#### Scenario: A predicted action diverges
- **WHEN** a client's prediction differs from the accepted authoritative result
- **THEN** the client reconciles to authority
- **AND** no duplicate inventory, combat, task, extraction, or settlement consequence is produced

#### Scenario: A peer reconnects during an active raid
- **WHEN** reconnect policy permits return to the raid
- **THEN** the peer receives a scoped authoritative snapshot and subsequent ordered events
- **AND** already-applied consequences are not applied again

### Requirement: Cross-platform Artifact Evidence
Release readiness SHALL require repeatable export, startup, combined add-on load, native dependency, and core smoke evidence for every declared target platform. Windows and Linux MUST be explicitly proven before being listed as supported, regardless of macOS editor success.

#### Scenario: A target export is built
- **WHEN** the pinned project is exported for a supported platform
- **THEN** the artifact starts in a clean test environment
- **AND** records Godot version, add-on versions, native library identity, and smoke result

#### Scenario: A native artifact is missing
- **WHEN** a required platform binary or import dependency is unavailable or incompatible
- **THEN** that platform is marked unsupported or blocked
- **AND** release documentation does not imply parity

### Requirement: Adversarial and Endurance Verification
Online release readiness SHALL include hostile-command, packet duplication, reordering, latency, loss, disconnect, reconnect, process-boundary, long-raid, repeated-settlement, and soak tests. Failures MUST be attributable through stable session, raid, actor, command, event, and settlement identifiers.

#### Scenario: The transport duplicates and reorders messages
- **WHEN** the test harness injects supported duplication and reordering conditions
- **THEN** authoritative outcomes remain valid and idempotent
- **AND** clients either reconcile or disconnect according to explicit policy

#### Scenario: A sustained test fails
- **WHEN** a soak run detects divergence, leak, deadlock, security rejection anomaly, or inconsistent settlement
- **THEN** release readiness fails
- **AND** diagnostics identify the affected authoritative identifiers and last known valid boundary
