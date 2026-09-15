# Task-9 art pipeline: recovery checkpoint

Base: `9369baec8858fdb95145ee1381254426f7b5d9aa`.
Spec: `add-zerkov-playable-raid-2026-09-09`.

This branch recovers the interrupted implementation. It is not task acceptance.
The source archive is supplied separately by the user. No full-game native,
visual, gameplay or human acceptance is claimed. Recorded results will be
added only after executing the current candidate.

## Candidate implementation

- Explicit allowlisted ZIP importer: SHA-256, exact PNG dimensions, integer
  grids/regions, ordered layers and pivots; no recursive extraction.
- Create-only output with import presets, AtlasTexture resources, derived
  animation manifest, registry promotion candidate and checksummed receipt.
- Presentation-only animation state and fixed eight-sprite layered presenter.
- Python negative controls and pinned Godot isolated module contract.

The checked-in source recipe selects 28 source PNGs. It is provisional until
verified against the supplied archive and visually reviewed. The recipe does
not invent hit-reaction artwork or authoritative melee/grenade mechanics.

## Commands

```sh
python3 -m pip install 'Pillow==12.3.0'
python3 -m unittest discover -s tests/tooling -p 'test_art_*.py' -v
python3 tools/zerkov_art_pipeline.py --archive /path/to/zerkov.zip
python3 tools/zerkov_art_pipeline.py --archive /path/to/zerkov.zip \
  --registry game/content/asset_registry.json --output ../zerkov-art-overlay
python3 tools/run_art_module_contract.py --godot "$ZERKOV_GODOT"
```

The Godot runner checks `4.7.2.stable.official.ed1daf0bf`, uses exactly
1920x1080 and runs only the isolated real presentation modules with explicitly
synthetic texture fixtures. It does not replace native add-ons with stubs.
A workflow declaration is not passing evidence. Runtime diagnostics fail even
when the process returns zero. Missing prerequisites are BLOCKED, never success.

9.2 integrated import/filtering consumers, 9.3 generated-content integration,
9.4 full character/held-equipment visual approval and 9.5 production projection
binding remain open until their evidence exists. 9.6-9.11 are not completed by
this checkpoint. Existing distribution blockers remain unchanged.
