# Tasks

- [x] Put the layered player artwork in the hideout world behind the existing
  sha256 provenance check.
- [x] Move per axis so a wall on one does not cancel the other, and sort the
  operator against props by its feet so doorways and benches overlap correctly.
- [x] Settle an authored spawn that lands inside a prop footprint onto the
  nearest free floor instead of starting the walk stuck.
- [x] Follow the operator with the room inspector and emit `station_entered` /
  `station_left`.
- [x] Delete the hidden placeholder station layout and the resources, styling
  and `_bind_static_scene` / `_sync_station_details` code that existed only for
  it.
- [ ] Add a contract for `enable_walk`: provenance rejection, blocked-axis
  movement, spawn settling and room transition. No test currently constructs
  `ZBunkerOperator`, so the walk is verified only by playing it.
- [ ] Give `station_entered` / `station_left` a consumer, or record why they
  are emitted with none. They are currently connected nowhere.
- [ ] Repair `tests/bunker_smoke.gd`, which still clicks the deleted station
  layout at (150, 196) and asserts the prototype toast. See task 8.14 of
  `add-zerkov-playable-raid-2026-09-09`; this fails on `main` already.
- [ ] Resolve the competing rewrite of `bunker_hideout_view.gd` against PR #26
  before either lands. See the open decision in `proposal.md`.
- [ ] User visual acceptance of the walk: speed, collision feel and the
  inspector following the operator.

Evidence: local flow scenarios pass unchanged -- full 4063, death 585, launch
54, clock 293, zero failures -- and `ui_composition` 103 / `ui_smoke` 933 pass
with zero failures. `bunker_smoke` reports one failure that also reproduces on
`main` at `36e3636`. The first three open items are not covered by any
automated check.
