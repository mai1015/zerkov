# Cold editor discovery: root cause and promotion boundary

Date: 2026-09-16. Assignment: diagnose first-import abort after PR #20 without
promoting an addon, changing a lock, or deciding to maintain permanent forks.

**Result: the reproduced crash is in the pinned engine's editor-documentation
shutdown lifecycle, not in Weapon networking or Gameplay Abilities replication.**
It is now root-caused. A production engine fix has NOT been built or shipped.

## Exact scope

Zerkov main: `3122b24e91c8267883fe3ec797a6a79929e07326`.
Its tree `02b6420b7173c83a68d58de53d3b0f01b7bd3032` equals the tested PR #20
head `fc5d155cd6d0dcbf3923c3ba496800dc03c2ea5a`.

Engine: standard Linux x86-64 `4.7.2.stable.official.ed1daf0bf`.
Executable SHA-256:
`8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e`.
SDK: `godot-cpp@5ffd70e34d0ab87009a9f0ffa3361bc8f4b09731`, SCons 4.10.1,
GCC, template_debug, the existing candidate SDK build profile.

The original Weapon source was rebuilt separately. Its complete native source
subtree reconstructs Git tree `a10a6ed98a267f5ebad3ad6fff7f7d1f1b4feaa1`,
matching the actual main subtree fetched from GitHub, not merely two selected
bridge hashes. This is a Linux build from main's source, NOT an installed Linux
package: current main does not ship the corresponding Linux libraries.
Candidate libraries came from PR #20's hash-verified CI artifacts.

These are empty, headless editor projects using `--editor --import --quit`.
Each final control used a new project and new HOME/XDG user/cache directories.
No title/menu, scripts, inventory, RPC session, world or native gameplay object
was instantiated by the reproducer. Long-running graphical editor behavior,
macOS/Windows cold imports and full-game exports were not tested here.

## Runtime results

| Control | Automatic discovery | Explicit startup list |
| --- | --- | --- |
| Empty project, no extension | 0 | Not needed |
| Loaded extension registering zero classes | 0 | Not needed |
| Extension registering one empty RefCounted class | -6 | 0 |
| Unchanged main Weapon source, freshly rebuilt | -6 | 0 |
| PR #20 Weapon candidate | -6 | 0 |
| PR #20 Gameplay Abilities candidate | -6 | 0 |

All ten final matrix invocations completed within the timeout. The one-class
and zero-class controls were then rebuilt using the committed reproduction
recipe and repeated, with the same outcomes. No failing import was retried in
the same project. Explicit registration is a separately labelled control, not
fallback success for the automatic run. A crash leaves `invocation_succeeded`
false and diagnostic exit 2; it is never counted as a loader acceptance pass.

`-6` is SIGABRT from Godot's crash handler. With that handler disabled for the
debugger experiment, the original fault is SIGSEGV (`-11`). The one-class
extension has no methods, properties, networking, singleton or destructor logic.
The zero-class build uses the same SDK/entrypoint without registering the class.

This disproves a necessary dependency on the WNB1 rewrite. It does not prove
that every extension on every machine or an indefinitely running editor crashes.
Fresh HOME/XDG directories also reproduce it: deleting global caches is not an
evidenced fix for this path. Initial help generation can create a cache which
the subsequent extension-triggered generation reads within the same launch.

## Cause: queued static work outlives EditorHelp::doc

In the pinned engine source:

1. `EditorNode::_gdextensions_reloaded()` requests help regeneration following
   extension discovery.
2. `EditorHelp::_load_doc_thread()` queues `_gen_extensions_docs` as a static
   deferred callable after processing cached documentation.
3. `EditorNode` destruction invokes `EditorHelp::cleanup_doc()`. It joins the
   worker, deletes `doc` and assigns null.
4. Joining the worker does not execute or cancel its already queued callback.
   A later message-queue flush runs `_gen_extensions_docs`, which dereferences
   `doc` without a lifetime check.
5. `DocTools::generate()` reaches the class-map lookup for the discovered class
   with a null `this` pointer. The main-thread fault is deterministic in these
   controls even though the lifetime ordering involves a documentation worker.

Primary source references (symbol locators, not guessed debug line numbers):

- https://github.com/godotengine/godot/blob/4.7.2-stable/editor/doc/editor_help.cpp
  (`_load_doc_thread`, `_gen_extensions_docs`, `generate_doc`, `cleanup_doc`)
- https://github.com/godotengine/godot/blob/4.7.2-stable/editor/editor_node.cpp
  (`_gdextensions_reloaded`, destructor)
- https://github.com/godotengine/godot/blob/4.7.2-stable/editor/doc/doc_tools.cpp
  (`DocTools::generate`, extension filtering and class-map insertion)

The fetched `editor_help.cpp` Git blob is
`a469a509558f40d98a9bccf1ea8b414d115b3000`. The official executable is stripped;
this is source-correlated disassembly plus direct register/memory observation,
not a fabricated fully symbolized engine stack.

## Causal debugger control

The exact executable has these independently checked instruction locations:

| Location | Meaning |
| --- | --- |
| `0x9012880` | `EditorHelp::doc` pointer slot |
| `0x1ac6b88` | instruction that writes null to the slot during cleanup |
| `0x1c84e60` | extension-doc generation entry, loading that slot and flags 3 |
| `0x1c7ae9f` | faulting class-map access, `mov eax,[rbx+0x20]` |

The fresh-project observation records:

```text
cleanup:                 doc = non-null
extension-doc callback:  doc = 0
SIGSEGV:                 RIP = 0x1c7ae9f, RBX = 0x8, doc = 0
process exit:            -11
```

`RBX=8` is the map member offset from the null DocTools object; the faulting
read is at address `0x28`. A second, independent fresh process uses the same
binary and library, but the debugger returns from only the callback whose doc
pointer is already null. It records `debugger_skipped_null_callback` and exits
0. Valid callbacks are not skipped. An earlier warm-user-cache trace also
records valid generation before cleanup and the invalid callback afterwards.

The diagnostic tracer pins the executable SHA and verifies instruction bytes
before setting breakpoints. It traces only the child it spawns, has a bounded
deadline, preserves the original signal in observation mode and writes no
executable/library file. The optional intervention changes child memory only.
**Its successful exit is causal evidence, not a tested replacement engine.**

## Repair belongs at the engine boundary

`tools/cold_discovery/proposed-engine-guard.patch` is an upstream-reviewable
minimal guard for the observed stale `_gen_extensions_docs` callback. It is
**not applied, not compiled, not installed, and not a complete shutdown audit**.
The engine owner should additionally review other static deferred documentation
callbacks and invalid-cache regeneration, then validate a patched build or a
verified upstream fixed release on the real automatic-discovery path.

Required fix validation: repeat cold project + fresh/warm user-cache controls,
zero-class/one-class/native-library imports, repeated imports, normal editor
lifetime/close, and the complete game's required native regressions with the
selected engine. No change to the current engine lock is proposed here.
Do not turn debugger intervention, `extension_list.cfg` pre-seeding, or a warm
second import into ordinary install/export qualification.

The loader cause can be repaired independently of choosing to maintain Weapon
or GAS forks. Their breaking bridge/API migration, provenance and maintenance
ownership remain a separate roadmap decision. No permanent fork is approved by
this report or by the fact that a branch was merged.

## Bookkeeping and unchanged gates

The prior candidate build item is now checked: workflow `35042265604` completed
successfully at `fc5d155...`, whose tree is now on main. The downloaded artifacts
were rechecked: six platform/configuration records, 12 native-library digests,
and two 80/0 network outputs per configuration. This is historical candidate
build evidence, not a new full-game run or cold-discovery result.

Cold discovery remains **unresolved for promotion** until an engine fix passes
the shipped loading mode. Full GAS targeted/relevance RPC coverage, owning-repo
reconciliation, truthful versioned packaging and full-game candidate-artifact
regressions stay open. Installed `addons/`, engine/addon locks and the candidate
verifier remain unchanged. No multiplayer session is enabled.

At investigation time PR #17 is an open, non-draft pre-raid bunker MVP with its
own input/save evidence; PR #19 is the broader open draft raid-flow workstream.
This PR does not edit either. Their work still has higher offline-product value
than adding game multiplayer integration before its gates are met.

## Reproduction

From the repository root, with the exact SDK available outside the checkout:

```sh
export GODOT_CPP=/absolute/path/to/pinned-godot-cpp
export DISCOVERY_BUILD=/tmp/zerkov-discovery-build
scons -f tools/cold_discovery/SConstruct platform=linux arch=x86_64 \
  target=template_debug build_profile="$PWD/tools/addon_hardening/build_profile.json" -j2
python3 tools/cold_discovery/test_probe.py
python3 tools/cold_discovery/probe_import.py --godot "$ZERKOV_GODOT" \
  --library "$DISCOVERY_BUILD/libone_class.so" --output /tmp/cold-one-new
python3 tools/cold_discovery/probe_import.py --godot "$ZERKOV_GODOT" \
  --library "$DISCOVERY_BUILD/libzero_classes.so" --output /tmp/cold-zero-new
python3 tools/cold_discovery/trace_lifetime.py --godot "$ZERKOV_GODOT" \
  --library "$DISCOVERY_BUILD/libone_class.so" --output /tmp/trace-observe-new
python3 tools/cold_discovery/trace_lifetime.py --godot "$ZERKOV_GODOT" \
  --library "$DISCOVERY_BUILD/libone_class.so" --output /tmp/trace-causal-new --skip-null
```

Use Python 3.11+ on Linux x86-64. Every output path must be new and outside the
checkout. The normal probe accepts an explicitly supplied expected engine hash
for future fix comparisons; the address-based tracer deliberately accepts only
the exact diagnosed binary. Tracing may be denied by host ptrace policy, which
is a diagnostic-environment failure, not a passing or skipped native result.
