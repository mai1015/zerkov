## ADDED Requirements

### Requirement: CommonUI-owned Screen Lifecycle
Production menu, overlay, modal, notification, focus, and back-navigation lifecycles SHALL route through CommonUI using stable route identifiers and typed route payloads. Feature screens MUST NOT create competing global navigation stacks.

#### Scenario: A production route opens
- **WHEN** a valid screen intent requests stash, loadout, trader, task, settings, raid HUD, pause, or summary
- **THEN** CommonUI resolves the route and lifecycle policy
- **AND** focus, input layer, transition, and back behavior follow the shared contract

#### Scenario: An unknown route is requested
- **WHEN** a route identifier or payload is invalid
- **THEN** navigation fails safely with a diagnostic reason
- **AND** the current screen stack remains valid

### Requirement: Intent-only Interface State
Production interface code SHALL render immutable view models derived from authoritative domain projections and SHALL communicate changes through declared intents. The current prototype `app.state` MAY remain as fixture or development data but MUST NOT be the source of canonical gameplay or profile mutation.

#### Scenario: Gameplay state changes while a panel is open
- **WHEN** authority publishes a newer projection relevant to the open panel
- **THEN** the panel renders the new immutable view model
- **AND** stale widgets cannot overwrite the authoritative value

#### Scenario: A prototype screen lacks a backend feature
- **WHEN** a route is retained for visual evaluation before its system exists
- **THEN** it is explicitly labeled fixture-only or feature-gated
- **AND** it cannot commit production profile state

### Requirement: Preserve the Established Visual Contract
Migration SHALL preserve the implemented utilitarian post-Soviet visual language, dense information hierarchy, existing route coverage, and pixel-world versus crisp-interface separation unless an approved visual task changes that contract. The current first-playable target is 1920x1080 only. Existing adaptive behavior MAY remain, but smaller-output support is deferred and MUST NOT gate this change. Visual changes MUST be reviewed from native 1920x1080 captures.

#### Scenario: A screen is migrated to live data
- **WHEN** production bindings replace prototype state on an existing route
- **THEN** its core information hierarchy and interaction affordances remain recognizable
- **AND** native capture comparison records intentional visual differences

#### Scenario: The interface runs at the first-playable target
- **WHEN** the game window is 1920x1080
- **THEN** critical actions, status, text, and inventory interaction remain reachable without overlap or clipping
- **AND** no smaller-output capture or adaptive-layout result is required for acceptance

### Requirement: Feature-gated Meta Screens
Hideout, marketplace, advanced traders, skill trees, clan, online social, and other post-slice routes SHALL be disabled, fixture-only, or clearly marked unavailable until their owning systems meet production requirements. They MUST NOT imply that unsaved or unauthoritative changes are durable.

#### Scenario: A player selects an unimplemented feature
- **WHEN** a gated meta route is reached from a development build
- **THEN** the interface identifies its non-production status
- **AND** prevents profile-affecting actions

#### Scenario: A feature becomes production-ready
- **WHEN** its owning spec, persistence, validation, and tests are approved
- **THEN** the feature flag can enable the live route without bypassing CommonUI or authority contracts

### Requirement: Input, Focus, and Accessibility Integrity
The interface SHALL provide deterministic keyboard, controller, and pointer focus behavior for all production-critical screens. Critical state MUST NOT rely on color alone, and text, selection, disabled state, warnings, and interaction targets MUST remain legible at the 1920x1080 first-playable target.

#### Scenario: Input method changes
- **WHEN** the player switches between pointer, keyboard, and controller during a screen lifecycle
- **THEN** a valid focus target and interaction hint are restored without triggering an unintended action

#### Scenario: A destructive or irreversible action is offered
- **WHEN** the interface presents discard, abandon, sell, or similar high-impact intent
- **THEN** its consequence and target are clearly identified
- **AND** the required confirmation policy is applied consistently
