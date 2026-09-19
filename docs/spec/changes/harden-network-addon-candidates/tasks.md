# Work and acceptance gates

- [x] Preserve installed sources/locks and stage six exact-base candidate transformations.
- [x] Implement connection compatibility, namespaced identity and no direct RPC mutations.
- [x] Require explicit recipient grants, sent-revision acknowledgement and reconnect cleanup.
- [x] Default GAS target authorization and relevance to fail closed.
- [x] Add staging/verifier negative controls and a real native ENet contract.
- [x] Obtain final debug/release native build and test evidence for each selected host. Evidence: `fc5d155cd6d0dcbf3923c3ba496800dc03c2ea5a`, workflow `35042265604`; Linux/macOS/Windows, two 80/0 runs per configuration. Explicit-startup candidate evidence only.
- [x] Independently reproduce complete GAS targeted/relevance RPC behavior. Evidence: `f9dab499a7c7482933a05dcd4195e3f3d17d6691`, workflow `35416051729`; Linux/macOS/Windows debug+release, two 47/0 real-ENet three-peer runs per configuration. See `docs/qa/multiplayer_phase_a/CANDIDATE_EVIDENCE.md`.
- [x] Root-cause the pinned Linux fast-exit cold-discovery abort with a minimal extension and causal debugger control. See `docs/qa/cold_discovery/REPORT.md`.
- [ ] Resolve cold editor discovery abort before artifact promotion. Engine documentation-lifetime cause identified; no patched engine build or shipped-loader acceptance yet.
- [ ] Reconcile the candidate with the actual owning sibling repository and hardening change.
- [ ] Review breaking optional bridge migration and rebuild truthful release packages.
- [ ] Run full game regressions against promoted candidate artifacts, not old pins.
- [ ] Update package descriptors/manifests/locks through the normal import pipeline.
- [ ] Obtain explicit multiplayer and platform qualification; do not infer from this candidate job.
