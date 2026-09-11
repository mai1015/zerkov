# Isolated world render-scale spike

`surface_policy.gd` contains four comparison policies and reversible pointer
mapping. `world_probe.gd` draws the existing 640×360 handoff raid region and
synthetic pixel/tile/character-cell probes. Neither is wired into production.

Run `tests/visual/render_scale/capture.gd` using the native Godot renderer at
exact 1920×1080, or run `uv run --with pillow python
tests/visual/render_scale/verify.py` for the current exact-size capture subset,
UI regression suite and contact sheets. The old multi-resolution packet and
responsive source remain historical; current agents/tests MUST NOT regenerate
them until task 11.8 or a later approved display-support proposal.
Current captures are isolated under `docs/qa/render_scale/current_1080/` so the
historical root packet remains immutable.

The selected recommendation, measurable limits and exact evidence are in
[`docs/qa/render_scale/README.md`](../../../docs/qa/render_scale/README.md).
Human approval and production adoption are not implied by this fixture.
