# Inventory-to-ability equipment evidence

This is a retained historical task 4.10 evidence packet. Its visible native
validation command and smaller-output captures are not part of the current
first-playable UI matrix; current agents/tests MUST NOT invoke or regenerate
them until task 11.8 or a later approved display-support proposal. The
immutable packet remains audit history, not a current aggregate check.

This directory contains the task 4.10 final accepted checkpoint. The acceptance
authority is the fresh GPT-6 Astra packet:

- [Final Astra report](astra_final/REPORT.md)
- [Final gate result](astra_final/gate_result.json)
- [Ordinary flow](astra_final/ordinary_flow_1280x720.png)
- [Independent-source isolation](astra_final/external_isolation_1280x720.png)
- [Failure recovery](astra_final/recovery_1280x720.png)
- [Lifecycle teardown orders](astra_final/teardown_1280x720.png)

The decision is `ACCEPT` with `human_approval: false`. The pinned Godot 4.7.2
Compatibility runs recorded `21756` raw assertion executions and `0` failures
across 17 distinct test programs and 18 execution variants. The promoted
equipment reconciliation contract passed `546/0`; 16 promoted and adjacent
suites contributed `20842/0`; the independent real-add-on flow passed `451/0`
headless and `463/0` in a visible native window. Native repeats the same 451
core assertions and adds 12 renderer, window and capture checks. Four 1280x720
frames were inspected, and `packet_hashes.sha256` seals 80 evidence files.

The real flow drives inventory mutations only through `RaidAuthority` phase 5
and observes native ability grants/revokes plus adapter publication in phase 7.
It proves a mutation-free bind followed by revision-zero full reconciliation,
bounded accepted-delta hints, complete-snapshot authority, duplicate and replay
idempotency, batched revisions, gap healing, stable source identity,
add-before-remove replacement and foreign-source isolation. Equipped AKM and
machete items create real passive executions, infinite effects, tags and an
equipment attribute modifier; rig and backpack remain explicit no-grant gear.

The lifecycle and failure fixtures cover unequip, destruction, explicit release,
owner-first and component-first destruction, rejected/partial native mutations,
fail-stop raid recovery and terminal component quarantine. All owned live state
is either removed or explicitly accounted for before a failure is closed. The
native grant history retains 64 tombstones; a 65th grant fails preflight without
creating a new live contribution.

## Reproduction

From the repository root, using only the pinned executable:

```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_ability_reconciliation_contract.gd
python3 -B docs/qa/inventory_ability_equipment/astra_final/run_validation.py suites
python3 -B docs/qa/inventory_ability_equipment/astra_final/run_validation.py flow
python3 -B docs/qa/inventory_ability_equipment/astra_final/finalize_packet.py
```

The visible `native` mode remains an immutable historical packet reproduction;
it is intentionally omitted from the current matrix and must not be invoked
until task 11.8 or a later approved display-support proposal.

The accepted boundary is offline, synchronous and in-memory. Native signals do
not form a batch transaction boundary, and unexpected ambiguous failure may
quarantine the complete captured Gameplay Ability component. Accepted P2
follow-up for tasks 4.12/7.1: composition must release the adapter or tear down
the inventory owner/component before `RaidAuthority` terminalizes. Raid
terminalization alone clears the phase handler without revoking equipment
contributions. Automatic raid-terminal-first cleanup, production UI/input,
human playtest, the complete raid loop, multiplayer and release acceptance are
not claimed. Task 4.11 is next.
