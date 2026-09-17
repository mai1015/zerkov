## ADDED Requirements

### Requirement: Independent simulation and presentation budgets
The application SHALL preserve the existing 60 Hz authoritative tick and SHALL measure displayed frame performance independently. A headless tick benchmark MUST NOT be labeled 60 or 120 FPS acceptance.

#### Scenario: Tick measurements without a windowed render test
- GIVEN an uninstrumented headless tick comparison
- WHEN the result is published
- THEN it identifies CPU tick cost and explicitly leaves displayed-FPS acceptance unproven.

### Requirement: Bounded production authorization
After explicit approval of the replacement phase-handler contract, production dispatch SHALL use a closed, generation-bound roster and live mutation authorization. It MUST NOT substitute a cached arbitrary-callback safety verdict or a filename whitelist for that contract.

#### Scenario: Stale or forged invocation
- GIVEN an active production roster
- WHEN an invocation uses a stale generation, wrong phase, replaced owner or unregistered executor
- THEN mutation is rejected before state changes, without requiring traversal of unrelated retained object graphs.

### Requirement: Proven content immutability or complete invalidation
Catalog validation SHALL remain on the current safety path until the active representation is isolated from mutable authoring resources or complete mutation invalidation is proven. A top-level change signal alone MUST NOT justify trusting nested state.

#### Scenario: Nested authoring-resource mutation
- GIVEN content that previously passed validation
- WHEN a nested definition or resource array is changed
- THEN it cannot silently change active semantics; the mutation is rejected, isolated from active content, or invalidates validation before any affected operation under the approved contract.

### Requirement: Revision-complete immutable projections
Reused projections SHALL cover every observable dependency in their cache key or invalidation protocol, SHALL remain immutable to consumers, and SHALL preserve canonical digest and save semantics.

#### Scenario: Time-varying state without a health damage event
- GIVEN an actor whose stamina, hydration, lifecycle or equipment changes
- WHEN a consumer reads the next projection
- THEN it observes current state even when no damage event occurred.

### Requirement: Truthful native and frame-time acceptance
Performance acceptance SHALL identify source, engine, native artifacts, build configuration, hardware and workload, SHALL report percentile timings and missed budgets, and SHALL include full functional and adversarial regression. Errors at exit MUST remain failures even when assertions pass or the engine returns zero.

#### Scenario: Passing assertions with retained runtime objects
- GIVEN a run with a zero-failure assertion marker
- WHEN shutdown reports leaked runtime resources or another required error diagnostic
- THEN the run is not accepted and is not reported as green.
