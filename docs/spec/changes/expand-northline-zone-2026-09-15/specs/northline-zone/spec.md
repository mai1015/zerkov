## ADDED Requirements

### Requirement: Connected full-zone environment
The review environment SHALL contain one continuous 2688x1792 authored map with
nine districts and nineteen interiors, without enlarging the existing artwork.

#### Scenario: Full-map inspection
Opening the review scene shows the full zone. Selecting a district moves the
source-pixel camera to that same district in the same map instance.

### Requirement: Native inspection without raid mutation
The review walker SHALL collide with authored walls and cover and MUST NOT
receive production raid, health, weapon, inventory or persistence capabilities.

#### Scenario: Boundary collision
A movement into a closed boundary is stopped by a native collision. Switching
to the overview pauses the walker without altering world geometry.

### Requirement: Exact native screenshot evidence
Every screenshot SHALL pass the existing physical 1920x1080 capture guard.
Unexpected engine diagnostics or differing repeated PNGs MUST fail validation.

#### Scenario: Repeatable full-zone review
Two independent graphical runs capture the overview, each district, route
annotations and the fixed-pose walker. All twelve PNGs match between runs.
