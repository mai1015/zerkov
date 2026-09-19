# Phase A addon hardening candidate evidence

Date: 2026-09-19

This record closes the missing **candidate-side** Gameplay Abilities ENet evidence.
It does **not** promote the local fork, replace the installed addon pins, claim
sibling-repository signoff, or enable multiplayer.

## Exact reviewed revision

Candidate evidence head:

`f9dab499a7c7482933a05dcd4195e3f3d17d6691`

Workflow:

- Addon hardening candidates run `35416051729`

The workflow stages the six reviewed source transformations from
`tools/addon_hardening/changes.json` outside the checkout, builds fresh native
Weapon System and Gameplay Abilities candidates, registers only those fresh
extensions in isolated Godot projects, and runs the real-ENet contracts twice per
configuration.

## Native three-peer matrix

Each contract uses one authority/server peer, one owning client and one compatible
but unowned observer/hostile client over real `ENetMultiplayerPeer` instances.

| Platform | Configuration | Weapon | Gameplay Abilities |
| --- | --- | ---: | ---: |
| Linux x86_64 | debug | 80/0 twice | 47/0 twice |
| Linux x86_64 | release | 80/0 twice | 47/0 twice |
| macOS universal | debug | 80/0 twice | 47/0 twice |
| macOS universal | release | 80/0 twice | 47/0 twice |
| Windows x86_64 MinGW | debug | 80/0 twice | 47/0 twice |
| Windows x86_64 MinGW | release | 80/0 twice | 47/0 twice |

The Gameplay Abilities contract verifies:

- exact native compatibility handshake before authority use;
- server-controlled actor ownership;
- target authorization required by default;
- missing policy fails closed before gameplay mutation;
- the target policy receives peer, session, component, ability, targets,
  command sequence and prediction-key context;
- policy denial remains mutation-free;
- an allowed command commits exactly once;
- exact command replay cannot reauthorize or execute twice;
- a compatible unowned peer cannot self-authorize control;
- owner and observer projections are distinct;
- unset or empty relevance grants no recipients;
- explicit relevance can be granted and revoked;
- re-added recipients converge to current state;
- retiring the owner session invalidates the old command namespace.

The Weapon contract continues to cover its hardened WNB1 compatibility, identity,
recipient, command-admission, acknowledgement, resync and reconnect boundaries.

## Artifacts

| Artifact | ID | SHA-256 |
| --- | ---: | --- |
| addon-candidate-linux | 10575548013 | `87a53ca79715d4a329c979dd798c1e17fca9d28480998bcd5e88c56af650806a` |
| addon-candidate-macos | 10575981638 | `078646980b7c9e9fe7061fa789947980f63bcd9af442a91a1775b68e23a4f5b6` |
| addon-candidate-windows | 10576016188 | `21ab9c34e03af1116ea36bc9a418dc3c8f62a2bf1d95f44f7f944b9ae954d84b` |

Artifacts contain candidate build/test logs, verification JSON, toolchain
provenance and the freshly built native libraries.

## Installed-package distinction

The current checked-in Gameplay Abilities package is intentionally still the
pre-hardening pin. Its header keeps `require_target_authorization=false` and
the previous relevance semantics. Therefore a workflow that copies the candidate
contract into the normal checkout and expects the installed binary to expose the
candidate API is invalid until package promotion occurs.

The failed Addon network hardening run `35416051905` demonstrated this exact
mismatch: the installed binary lacked the candidate defaults/API. It is not
evidence of a failed fresh candidate build. The candidate matrix above is the
correct place to validate the local-fork hardening before promotion.

## Remaining 10.1 blockers

Task 10.1 itself remains open because its acceptance wording requires the actual
owning sibling hardening change/revision and rebuilt package provenance. The
GitHub installation available for this work exposes `mai1015/zerkov` but no
separate Gameplay Abilities or Weapon System repository. The following therefore
remain explicit blockers rather than being silently redefined:

1. reconcile the candidate with the owning sibling repository/change;
2. review the breaking optional-bridge migration under a truthful package
   identity;
3. resolve the documented cold editor-discovery prerequisite before promotion;
4. rebuild and publish truthful package manifests/artifacts;
5. re-vendor through the normal descriptor/manifest/lock pipeline;
6. run full game regressions against the promoted package bytes.

Until those steps are satisfied, the installed package remains unchanged and
multiplayer remains disabled.
