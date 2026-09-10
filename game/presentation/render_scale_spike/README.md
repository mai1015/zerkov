# Isolated world render-scale spike

`surface_policy.gd` contains four comparison policies and reversible pointer
mapping. `world_probe.gd` draws the existing 640×360 handoff raid region and
synthetic pixel/tile/character-cell probes. Neither is wired into production.

Run `tests/visual/render_scale/capture.gd` using the native Godot renderer, or
run `uv run --with pillow python tests/visual/render_scale/verify.py` for the
capture matrix, unchanged UI regression suites and contact sheets.

The selected recommendation, measurable limits and exact evidence are in
[`docs/qa/render_scale/README.md`](../../../docs/qa/render_scale/README.md).
Human approval and production adoption are not implied by this fixture.
