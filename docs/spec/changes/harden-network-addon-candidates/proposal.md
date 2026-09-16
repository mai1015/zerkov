# Harden networking addon candidates

## Why

The merged task-10.1 report identifies Weapon handshake, identity, entropy,
auxiliary-RPC and reconnect gaps, and permissive Gameplay Abilities defaults.
The user approved reconciling and repairing these findings. The canonical
sibling repository/release evidence is not available through this connection.

## Scope

Provide a named, exact-base, non-installed local-fork candidate and reproducible
native build/tests for review. Stage only six enumerated source transformations
outside the checkout; preserve existing pinned addons and locks. This is an
implementation of the requested repair experiment, not upstream hardening
signoff or approval to deploy live multiplayer.

## Breaking optional bridge contract

WNB1 connection envelopes are incompatible with the old bridge transport.
The game must provide authenticated sessions, recipient grants, a queue admission
callback, canonical execution and explicit outcome completion. Old context and
reload provider names alone no longer enable RPC mutation. Game-side ownership,
server timing, entropy, inventory, persistence and Steam transport remain outside
the addon. GAS target authorization becomes required by default and empty or
unset relevance grants no recipients. Promotion requires explicit review of this
migration and a truthful new package identity, not an unchanged version label.

## Non-goals and gates

No production file replacement, task checkbox promotion, sibling signoff,
account service, Steam implementation, export or public-release claim. Cold
editor discovery currently aborts in the tested Linux baseline and remains an
open promotion prerequisite, independently of explicit-startup native tests.
