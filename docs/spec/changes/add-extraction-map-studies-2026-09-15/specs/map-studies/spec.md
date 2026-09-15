## ADDED Requirements

### Requirement: Original native environment studies
The review SHALL provide Northline Depot and Mercury Block using the supplied
source packs, with separate native props, authored surfaces and collision data.
#### Scenario: Switching maps
When a reviewer chooses the other map, the previous scene's props and colliders
are released and the selected authored environment is displayed.

### Requirement: Honest presentation-only controls
Review input SHALL control only camera inspection, sector selection and route
annotations. It MUST NOT mutate inventory, combat, AI, extraction or settlement.
#### Scenario: Showing a proposed extraction point
The interface identifies the view as an environment study and does not report
an active extraction, reward, resource count or simulated raid result.

### Requirement: Native exact-output evidence
Screenshots MUST be saved only after graphical Godot rendering and a successful
physical 1920x1080 window, viewport, texture and raw-image guard.
#### Scenario: Headless screenshot attempt
A headless attempt is rejected without writing a claimed native screenshot.
