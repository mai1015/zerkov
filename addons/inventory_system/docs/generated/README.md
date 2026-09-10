# Generated class reference (`--doctool`)

The 22 XML files in `doc_classes/` were produced by Godot's own
documentation generator, run headlessly against this addon's built
extension:

```sh
scons platform=macos target=template_debug arch=universal -j8   # build first
tools/bin/Godot.app/Contents/MacOS/Godot --headless --path . \
    --doctool addons/inventory_system/docs/generated --gdextension-docs
```

(`tools/godot.sh` has no `doctool` subcommand of its own; the command above
uses the same pinned binary `tools/godot.sh` wraps, invoked directly with the
extra `--doctool`/`--gdextension-docs` flags. `--gdextension-docs` restricts
generation to GDExtension-registered classes. Because this combined project
loads several extensions, regeneration also produces their class XML; only
the `Inventory*.xml` files belong in this directory.)

This confirms the pinned engine build (`tools/bin/Godot.app`, Godot 4.7.1
standard) CAN run `--doctool` headlessly with a GDExtension loaded — it is
not blocked the way some other headless GDExtension operations are (compare
`tools/godot.sh`'s own header comment about `--headless --import`
segfaulting on this build; `--doctool` does not hit that issue).

## What this output has, and does not have

Each file's `<methods>`/`<members>`/`<signals>`/`<constants>` sections are
accurate and complete — the exact same structural information
[`api.md`](../api.md) documents by hand, extracted directly from each
class's live `_bind_methods()`/`ADD_SIGNAL`/`ADD_PROPERTY`/`BIND_ENUM_CONSTANT`/
`BIND_BITFIELD_FLAG` registration, so it can never disagree with the actual
binding on a signature or a bound constant's name/value.

The pinned `_bind_methods()` calls (like `gameplay_abilities`' own) do not
provide prose through godot-cpp's doc-registration API, so the generator
primarily emits signatures and leaves most descriptions empty. The
security-sensitive gateway, observer, and lifecycle entries are intentionally
kept with small checked-in descriptions here so the generated reference
cannot suggest that raw authority bytes are RPC, packet identity is trusted,
raw `delta_ready` bytes are safe client broadcasts, or projected observer
bytes are canonical restore input. Gateway command acknowledgements also
retain detailed IDs/revisions only under complete OWNER replication scope.
Recipient-filtered OWNER `DeltaBatch` egress always clears
`source_command_id` to `0`; the authority-global id remains only in the raw
server-local `delta_ready`/`last_delta_batch_bytes()` batch, so it cannot
correlate other touched inventories or principals.
The installed world-policy Callable is trusted server code and must be pure
with respect to InventoryAuthority during evaluation: no typed/raw, lifecycle,
reservation, discovery, or other authority mutations and no external side
effects. Gateway recursion is blocked, but arbitrary trusted-callback side
effects cannot generally be rolled back.

SessionHello attempts share the authenticated command-ingress token bucket with
command bytes, including malformed/oversized attempts. Fresh logical session
ids strictly increase within an authority epoch; reconnect reuses the same id
with the same actor/authority epoch and a strictly higher connection epoch, may
move to a different peer, and
preserves grants/replay/sequence/rate state. A higher authority epoch starts a
fresh id domain only after all live sessions are gone. The Godot façade's
combined owner plus observer/redacted replication cap is 256, while the
engine-free observer
grant cap remains 64 per session. Custom executors are synchronous/immediate;
queued results must not enqueue or perform any side effects and are rejected.

[`api.md`](../api.md)
remains the primary hand-written deliverable for the complete behavior,
ownership, compatibility, and façade-gap explanations; this directory is the
structural cross-check plus those selected API safety notes.

This output is not wired into the Godot editor's own Script Reference / help
panel (that requires installing it under a path the engine's doc system
scans by default, e.g. alongside the project's own `doc_classes` if
configured via `ProjectSettings`); it is committed here purely as a
verifiable-by-regeneration reference artifact.
