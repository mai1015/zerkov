# Task-9 art pipeline and layered-animation candidate

Integrated main baseline: `8039a0c19570e022cfc6ec855b77dd014da3e553`.
Spec: `add-zerkov-playable-raid-2026-09-09`. PR: #5.

This is early task-9 implementation, not acceptance of the entire section.
Task checkboxes, authority modules, existing UI and distribution gates are
unchanged. No font or engine binaries are added.

## Implementation and assets

The explicit ZIP compiler checks hashes, PNG dimensions, integer grids and
arbitrary regions, frame order, layer counts/pivots, prohibited paths, duplicate
members, symlinks and budgets. It reads only selected members, never extracts
the whole archive. It publishes a create-only overlay with import presets,
AtlasTexture resources, compiled geometry and a checksummed receipt.

Registry promotion starts from the accepted record and updates materialization
fields only. It preserves atlas metadata, aliases, content links, family, kind,
custom authoring fields, license evidence and all distribution blockers.

The complete selected recipe contains 28 PNGs (619,029 original bytes) and 165
regions. Two local actual-source builds produced identical hashes for all 224
outputs. Source archive `zerkov.zip` SHA-256:
`ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006`.

Twenty player PNGs are checked into this branch, verified byte-for-byte. Their
five states are idle, walk, knife attack, grenade throw and death, each with four
ordered layers. The first four states use six 64x64 frames; death uses nine
49x33 frames. Both source-facing and horizontal mirroring are exercised.
No hit reaction or held-AKM/machete alignment is fabricated or approved.

`ZPlayerAnimationState` samples bounded clips from committed, sequenced,
generation-scoped events, holds terminal death, rejects malformed/stale inputs
and handles explicit release/replacement. `ZLayeredPlayerPresenter` validates
detached bindings, uses eight reusable nearest-filtered sprites, and never
advances the raid clock or moves the authoritative root body.

## Reproduce

```sh
python3 -m pip install 'Pillow==12.3.0'
python3 -m unittest discover -s tests/tooling -p 'test_art_*.py' -v
python3 tools/zerkov_art_pipeline.py --archive /path/to/zerkov.zip
python3 tools/zerkov_art_pipeline.py --archive /path/to/zerkov.zip \
  --registry game/content/asset_registry.json --output ../zerkov-art-overlay
python3 tests/tooling/run_art_module_headless_gate.py --godot "$ZERKOV_GODOT"
python3 tools/check_art_scope_delta.py
```

The native driver is registered under the existing independently discovered
`tests/tooling/run_*_gate.py` convention. It checks the exact standard engine
`4.7.2.stable.official.ed1daf0bf`, compiles synthetic negative-control textures
and the real supplied player assets, imports them in an isolated project, then
runs both suites twice with identical replay markers. All invocations specify
1920x1080. No add-on is replaced with a stub. This is not full-game Linux support
or graphical/human acceptance. Source contact sheets are not native captures.

## Diagnostics and acceptance boundaries

The first Python run exposed dropped atlas metadata; promotion was repaired and
55 Python tests passed. The first native run that reached the assertions
returned zero failures but logged invalid Variant comparisons. Those runs are
FAILURES, not accepted evidence. The driver rejects runtime diagnostics even
when Godot returns zero; guards now check types before comparing values.
Final accepted results must be taken from the successful current workflow run.

Main already contains eight exact-1080 policy findings: seven unregistered AI
GDScript entrypoints and one unreviewed AI PNG writer. The nonregression check
runs the unchanged checker on both pinned main and this branch, proves the
existing policy and affected AI files are unchanged, and rejects any additional
finding. It prints every baseline issue and `full_policy_pass=False`; a passing
nonregression result does NOT mean the complete source-policy gate passed.

9.2 still requires integrated import/filter-consumer review. 9.3 still requires
the full overlay's production registry integration. 9.4 requires a genuine hit
reaction, directional/held-equipment work and native visual approval. 9.5 needs
root-owned production projection/lifecycle binding. Tasks 9.6-9.11, integrated
encounters, VFX/audio/lighting and complete screen captures are not claimed.
