## ADDED Requirements

### Requirement: Candidate isolation and identity
The candidate SHALL stage only the six enumerated, before/after-hashed native
source changes in a new outside directory. It SHALL NOT mutate installed addon
sources, manifests or locks or claim upstream release provenance.

#### Scenario: Wrong base bytes
- WHEN an enumerated source differs from its recorded base hash
- THEN staging fails before writing a candidate and the checkout remains intact

### Requirement: Admission is not execution
The candidate bridge SHALL require current connection compatibility and an
explicit control grant before submitting to a trusted host queue. It SHALL NOT
execute native weapon mutation from an RPC callback or forward client entropy.

#### Scenario: Revocation during queue residence
- WHEN the actor's grant or connection is revoked before execution
- THEN currentness and completion reject the old command
- AND regrant and duplicate replay cannot report that cancelled command as successful

### Requirement: Replication is recipient-bound
The candidate SHALL check auxiliary RPC and replication eligibility and accept
only acknowledgement revisions actually sent to that connection.

#### Scenario: Hidden instance resync
- WHEN a peer requests a known but ungranted instance
- THEN no snapshot, revision disclosure or replica state is emitted to that peer

### Requirement: Native evidence remains scoped
Native verification SHALL fail on every nonzero process exit, script error,
timeout or missing/duplicate/empty pass marker. Explicit startup registration
SHALL be disclosed and SHALL NOT imply automatic cold editor discovery or export.

#### Scenario: Runtime pass after an import abort
- WHEN the required loader invocation aborts but a later invocation could pass
- THEN that verifier run fails rather than silently retrying or promoting artifacts
