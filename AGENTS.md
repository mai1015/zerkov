# AGENTS.md instructions

<!-- CODEGRAPH_START -->
## CodeGraph

This project uses CodeGraph for structural code discovery when a `.codegraph/`
index is present.

### When to prefer CodeGraph

Use CodeGraph for structural questions such as where a symbol is defined,
what calls it, what it calls, flow tracing, impact analysis, signatures, and
focused symbol context. Use `rg` or direct reads for literal text, comments,
messages, filenames, or a file that is already known.

| Question | Preferred tool |
| --- | --- |
| Where is `X` defined? | `codegraph_search` |
| What calls `Y`? | `codegraph_callers` |
| What does `Y` call? | `codegraph_callees` |
| How does `X` reach `Y`? | `codegraph_trace` |
| What would break if `Z` changes? | `codegraph_impact` |
| Show a symbol signature/source | `codegraph_node` |
| Focused context for an area | `codegraph_context` |
| Several related symbol bodies | `codegraph_explore` |
| Files under a path | `codegraph_files` |
| Index health or pending sync | `codegraph_status` |

For architecture questions, start with `codegraph_context` and then use one
`codegraph_explore`. For a specific flow, start with `codegraph_trace` and then
use one `codegraph_explore`. Trust fresh AST results and do not re-verify them
with grep. If CodeGraph reports pending files, read only those files directly.

If `.codegraph/` does not exist, ask before running `codegraph init -i`.
<!-- CODEGRAPH_END -->

<!-- SPEC:START -->
# Spec Instructions

Always follow the workflow in `docs/spec/AGENTS.md` for proposals, plans, new
capabilities, breaking changes, architecture changes, or behavior-changing
performance and security work.

Keep this managed block so it can be refreshed without replacing the CodeGraph
instructions above.
<!-- SPEC:END -->
