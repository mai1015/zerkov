# Current first-playable display scope: exact 1920×1080

The current Zerkov first-playable and its acceptance work target one output:
exact 1920×1080. The pixel world is a 640×360 surface mapped at exact nearest
3×, while the interface remains a separate crisp 1920×1080 composition.

Smaller, compact, responsive, and multi-resolution code and historical evidence
may remain in the repository for later work. They are not current acceptance
paths and must not be executed or regenerated before task 11.8 or a separately
approved display-support proposal.

## Practical repository gate

`config/first_playable_1080_gate.json` is the reviewed inventory for display-
relevant entrypoints. `tools/check_first_playable_1080.py` independently
discovers repository runners and validates the inventory. The gate currently
distinguishes:

- 26 active visual GDScript entrypoints whose complete bytes are SHA-256
  allowlisted;
- two active Python command drivers whose complete bytes are SHA-256
  allowlisted and whose literal Godot commands request `1920x1080`;
- 35 current headless contracts, which are classified separately and scanned
  for literal output mutations;
- 14 retired display GDScripts and two retired display Python drivers;
- 21 historical-evidence GDScripts and ten historical-evidence Python drivers;
- exact-current support files, including the runtime QA writer, the Sawmill
  output/world guard, and an export-safe shared physical capture guard; and
- a separate inventory for non-executable `.source_only` fixtures (currently
  empty).

Those categories are not accepted by self-declaration. The checker discovers
all tracked and untracked GDScript `SceneTree` runners (including an inline
comment after `extends`), single- or double-quoted inherited test runners,
`tests/visual/**`, `docs/qa/**/*.gd`, the known Python display-driver roots, and
`.source_only` files, then requires an exact one-category match. Retired and
historical categories are distinct and may not overlap. A newly added runner
fails until it is reviewed and classified.

The bounded checks enforce:

- exact `project.godot` viewport and window override values of 1920×1080;
- reviewed SHA-256 bytes for every active visual entrypoint, active command
  driver, and output-sensitive support file;
- exactly one applicable hashed current classification for every sanctioned
  PNG writer, so a writer cannot be omitted from or duplicated across the
  reviewed current categories;
- no literal smaller output assignment on root/window/SubViewport targets and
  no literal smaller `DisplayServer` or `RenderingServer` size/attach call in
  current files;
- no literal non-1920×1080 `--resolution` in active Godot command drivers;
- a fail-first `_initialize()` stub for retired/historical GDScript drivers and
  a first-statement literal `SystemExit` for retired/historical Python drivers;
- no current command, config, QA entrypoint, or reviewed support file importing
  a retired/historical display driver through a literal `extends`, `load`, or
  `preload`, an enabled bare/starred autoload, or a direct literal
  `OS.execute`/process `--script` argument; both `res://` and owner-relative
  paths are normalized, while quoted explanations and comments remain inert;
- a complete nine-file active PNG-writer inventory whose every PNG write is
  immediately preceded by the declared fail-closed shared guard, writes the
  exact guarded Image, has no same-line yield or state-changing prefix, and
  contains no `await` anywhere in the complete save-call expression;
- runtime rejection of headless capture or any nonexact physical DisplayServer
  window, root/window size, root visible rect/texture, capture visible rect/
  texture, or raw image immediately before a PNG write; and
- the Sawmill `640×360` world surface, nearest filtering, and exact `3×` mapping
  into the sole 1920×1080 output.

Historical bodies can retain old-size literals after their fail-first stubs.
Their presence is archival, not permission to run them. The active inventory-
loot capture no longer inherits the retired multi-resolution launcher: its
small exact-current setup retains the same authority/bridge/controller seam and
the capture continues to mount the existing designed inventory UI.
No replacement inventory screen or production UI implementation is introduced.

## Deliberate limit

This is not a general GDScript verifier, sandbox, capability analyzer, or proof
against arbitrary hostile source semantics. It does not attempt to interpret
reflection, dynamic dispatch, helper return flows, every possible alias, engine
startup behavior, or arbitrary code hidden in a dependency.

The safety boundary is practical and reviewable: independent entrypoint
discovery, immutable reviewed bytes, direct reference edges, exact project and
command configuration, literal output operations, simple retirement stubs,
and explicit guard anchors. Changing an allowlisted file requires reviewing
the whole changed file and updating its hash. A new output-changing pattern
that is not covered by the literal checker requires an explicit checker/test
update or a reviewed manifest exception; an exception is not a claim of formal
semantic proof.

The source-only gate does not establish visual quality or prove that a native
framebuffer existed during this verification. When a sanctioned capture does
run, its hashed shared helper rejects headless mode and checks the actual
1920×1080 physical window, root, visible rectangles, textures, and fresh raw
image immediately before every PNG write. Headless and check-only runs are
useful for contracts and parsing, not visual approval.

## Safe verification

The repository-only checks do not start Godot or write capture artifacts:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/check_first_playable_1080.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.tooling.test_ui_first_playable_scope
```

Any Godot import or parse verification for this scope must use the pinned 4.7.2
engine and pass an explicit `--resolution 1920x1080`. No smaller-output runner,
responsive/compact suite, historical packet generator, or alternate-size
capture should be launched as part of this gate.

Earlier multi-resolution captures, logs, and reports remain historical records.
This scope note does not retroactively revalidate or regenerate them, and it
does not convert their recorded source seals into current acceptance evidence.
