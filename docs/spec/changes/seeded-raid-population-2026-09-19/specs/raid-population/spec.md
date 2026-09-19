## ADDED Requirements

### Requirement: Deterministic authoritative population plan
The authoritative raid composition SHALL generate exactly one immutable population
plan from a closed map identity, deployment seed and generator version. UI and
remote peers MUST NOT mutate or independently author the plan.

#### Scenario: Identical inputs replay the same plan
Given the same map identity, seed and generator version, generation SHALL produce
the same selected container IDs, item rows and plan digest.

#### Scenario: Independent streams isolate domains
Changing a container-content implementation without changing the location-stream
version MUST NOT alter selected optional-container locations.

### Requirement: Guaranteed objective availability
Every supported map SHALL retain all three authored Supply Run objective
containers, and exactly one guaranteed Supply Crate objective item SHALL be placed
in the first objective container.

#### Scenario: Optional population cannot make the task impossible
For every accepted seed, the three objective containers and required objective item
SHALL exist even when optional candidates or random rolls differ.

### Requirement: Bounded optional containers
Each raid SHALL select exactly two unique optional containers from six validated
map-specific candidate points. Selection SHALL occur once during deployment and
MUST NOT run during authoritative ticks.

#### Scenario: Optional container search uses existing authority
A selected optional container SHALL use the same range, line-of-sight, discovery,
open and transfer authorities as an objective world crate, without updating Supply
Run objective progress.

### Requirement: Closed persisted population identity
Deployment and settlement records SHALL optionally carry a closed population
descriptor containing only generator version, seed, map-identity digest and plan
digest. Descriptor conflicts on an idempotent deployment request MUST fail closed.

#### Scenario: Recovery preserves population identity
A crash recovery or committed receipt replay SHALL retain the exact population
descriptor without attempting to restore a live raid.

### Requirement: Presentation cannot add collision truth
Selected optional containers MAY receive visual placeholder presenters, but those
presenters MUST NOT add engine physics bodies or replace `ZMovementWorld2D` as
collision authority.

#### Scenario: Visual container is non-authoritative
Instantiating an optional-container presenter SHALL not change movement geometry,
navigation identity, hitbox obstruction identity or the canonical raid digest.
