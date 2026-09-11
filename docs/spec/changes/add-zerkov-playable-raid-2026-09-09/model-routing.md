# Codex Model Routing

This document selects an execution lane for a task. It does not relax the
specification, authorize extra scope, or replace human approval/playtesting.

The current [official OpenAI model catalog](https://developers.openai.com/api/docs/models)
describes GPT-6 Astra as the flagship for the hardest reasoning/coding work,
GPT-5.6 Sol as a flagship model for complex professional work, and GPT-5.6
Luna as the cost-sensitive high-volume option. Availability can vary by account
or host, so use the nearest available lane with the same role when necessary.

## Project defaults

| Lane | Default configuration | Use when | Avoid as sole reviewer when |
| --- | --- | --- | --- |
| `LUNA` | `gpt-5.6-luna`, `max` | The contract is settled, files are bounded, and correctness is covered by deterministic checks. | The task chooses architecture, security policy, visual direction or combat feel. |
| `SOL` | `gpt-5.6-sol`, `high` | Work crosses domains, needs sustained debugging, or owns authoritative/persistent state. | A subjective visual or play-feel decision is still unresolved. |
| `SOL-SECURE` | `gpt-5.6-sol`, `max` | Networking, hostile input, reconciliation, idempotency, recovery or native GDExtension integration. | Human product approval or visual acceptance is required. |
| `ASTRA` | `gpt-6-astra`, `high` | UI/UX, image-based review, level composition, combat feedback or resolving a hard ambiguous bug. | The work is a large volume of already-specified mechanical edits. |
| `ASTRA-GATE` | `gpt-6-astra`, `max` | Architecture approval, system-wide impact, final visual/combat gate or choosing between costly alternatives. | Routine implementation has not first been reduced to a clear contract. |

If Terra is available, `gpt-5.6-terra` at `high` is a reasonable balanced
fallback between Luna and Sol, but the task ledger intentionally uses only the
three primary lanes requested for this project.

## Routing decision

1. Can the task be stated with exact inputs, outputs, files and automated
   evidence? Use Luna.
2. Does it cross two or more authorities, touch persistence/recovery, native
   boundaries, untrusted input or replication? Use Sol.
3. Does success depend on screenshots, animation, encounter readability,
   perceived responsiveness, spatial composition or an unresolved architecture
   choice? Use Astra.
4. Does the task combine correctness and feel? Split it. Sol establishes the
   canonical mechanics; Astra evaluates and tunes presentation.
5. After two focused failed attempts with the same blocker, stop expanding the
   prompt and escalate one lane with the failure evidence.

## Recommended two-pass patterns

### Routine implementation

```text
Luna implements one accepted task -> automated checks -> Sol reviews only if
the diff touches authority, persistence, shared contracts or native boundaries
```

Examples: content Resources, stable-ID fixtures, atlas metadata, deterministic
event enums, view-model plumbing, smoke tests and UI action definitions.

### UI and visual work

```text
Astra defines the desired result from current captures -> Luna performs bounded
layout/style/state edits -> Astra compares new native captures -> human accepts
```

Use current exact 1920x1080 native evidence for first-playable visual
decisions. Existing smaller and compact captures are historical audit
artifacts; current agents, tests and reviewers MUST NOT execute their suites or
regenerate their outputs. Do not spend implementation or review scope adapting
them until task 11.8 or a later approved proposal reopens display support.
Never ask an implementation model to improve a screen based only on words when
a current native capture can be provided.

### Combat work

```text
Sol implements cadence/hit/damage/reload authority -> deterministic tests ->
Astra tunes animation, camera, VFX, timing perception and readability -> human
blind playtest
```

Combat feel must not change canonical outcomes through animation callbacks,
frame rate, camera motion, audio completion or particle timing.

### Networking and recovery

```text
Sol max implements one threat/recovery slice -> hostile and process tests ->
fresh Sol max security review -> Astra reviews only correction presentation
```

Do not use a visual pass as evidence that authorization, privacy, idempotency or
reconnect convergence is correct.

## Task dispatch template

Use one task ID per request:

```text
Implement only task <ID> from
docs/spec/changes/add-zerkov-playable-raid-2026-09-09/tasks.md.

Read proposal.md, design.md, the matching capability spec, and any AGENTS.md
that applies. Preserve unrelated UI and user changes. Do not modify sibling
addon source unless the approved task explicitly says so.

Before editing, restate:
- in-scope files and behavior;
- dependencies already assumed complete;
- verification commands/evidence;
- any blocker that would expand scope.

After implementation, update only this task when all evidence passes. Report
changed files, commands, results, remaining risks, and the next unblocked task.
```

For an Astra visual task, append:

```text
Inspect the current native captures before editing. Define observable success
criteria, capture the same states at 1920x1080 afterward, and compare them.
Separate canonical combat/gameplay behavior from presentation changes.
```

For a Sol network/persistence task, append:

```text
Treat all remote/persisted bytes and identities as untrusted. Enumerate failure
and replay cases before implementation. Require fail-atomic behavior and prove
duplicate, stale, malformed, interrupted and recovery paths.
```

## Review and escalation rules

- A task implementer does not approve its own architecture or subjective visual
  gate in the same pass.
- Luna may fix a clear test failure it introduced. It escalates when fixing the
  failure requires changing an accepted contract.
- Sol owns correctness of cross-domain, persistence and network invariants.
- Astra may request a bounded implementation follow-up; it should not silently
  redesign unrelated systems during visual review.
- Human approval is required for first-playable scope, secure-container loss
  policy, combat feel, accessibility trade-offs and public support claims.
- Every handoff includes the exact task ID and evidence paths. “Looks good” or
  “tests pass” without named evidence is not a complete handoff.

## Good task splits

| Broad request | Split |
| --- | --- |
| Make the AKM feel good | Sol: canonical fire/recoil state; Luna: presenters and fixtures; Astra: camera/VFX/audio/readability tuning; human playtest. |
| Build inventory | Sol: authority/adapters; Luna: item data and bounded UI wiring; Astra: inventory readability review. |
| Add multiplayer | Sol max: sessions/admission/replicas/recovery in separate tasks; Astra: correction feedback only; human: perceived responsiveness. |
| Make Sawmill | Astra: layout/readability direction; Luna: TileSet/markers; Sol: collision/navigation/occluder contracts; Astra: final capture review. |
| Connect the UI | Sol: view contracts and lifecycle; Luna: individual screen binding/tests; Astra: visual QA; human: navigation test. |
