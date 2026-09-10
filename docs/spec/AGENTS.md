# Spec Instructions

## Workflow

- Stage 1: create a change under `docs/spec/changes/<id>-YYYY-MM-DD/`, including
  `proposal.md`, `tasks.md`, cross-cutting `design.md`, and capability deltas.
- Validate the proposal strictly and obtain explicit approval before coding.
- Stage 2: implement approved tasks without expanding scope. Keep task status
  and verification evidence current.
- Stage 3: after the change ships, archive it and merge accepted requirements
  into `docs/spec/specs/`.

## Delta rules

- Delta files live at `docs/spec/changes/<id>/specs/<capability>/spec.md`.
- The first non-empty line must be `## ADDED Requirements`,
  `## MODIFIED Requirements`, `## REMOVED Requirements`, or
  `## RENAMED Requirements`.
- Every `### Requirement:` needs descriptive normative text before scenarios.
- Every requirement needs at least one `#### Scenario:` header.
- Use `SHALL` or `MUST` for normative behavior.
- Do not edit truth specs during implementation; truth is updated at archive.

## Zerkov implementation rules

- UI and remote peers submit intent; they never mutate authoritative gameplay
  state directly.
- `RaidAuthority` owns the canonical tick, identity mapping, world policy,
  cross-addon ordering, and the raid audit stream.
- Add-ons remain independent. Cross-domain behavior belongs in game-owned
  adapters with stable idempotency identities.
- Presentation reads immutable snapshots or projections and treats prediction
  as reversible presentation only.
- One task should be small enough for one focused agent turn and must name its
  expected verification evidence.
- Model lane tags in `tasks.md` are recommendations, not permission to skip
  review or acceptance criteria.
