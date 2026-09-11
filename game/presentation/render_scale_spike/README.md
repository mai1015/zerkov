# Isolated world render-scale spike

`surface_policy.gd` contains four comparison policies and reversible pointer
mapping. `world_probe.gd` draws the existing 640×360 handoff raid region and
synthetic pixel/tile/character-cell probes. Neither is wired into production.

`tests/visual/render_scale/capture.gd` and
`tests/visual/render_scale/verify.py` are retired historical entry points. Both
fail closed before setup or writes; no command mode or `current_1080/` subset
is available for current acceptance. Do not invoke or regenerate this packet
until task 11.8 or a later approved display-support proposal reopens it.

Current visual work requires a genuine exact 1920×1080 renderer output. The
selected fixed 640×360 world surface is permitted only when nearest-mapped
exactly 3× into that output. Requested window dimensions alone are insufficient;
the actual output/readback must pass the exact-size preflight before any paths
or captures. See [`docs/qa/1080-only-scope.md`](../../../docs/qa/1080-only-scope.md).

The selected recommendation, measurable limits and exact evidence are in
[`docs/qa/render_scale/README.md`](../../../docs/qa/render_scale/README.md).
Human approval and production adoption are not implied by this fixture.
