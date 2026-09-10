#ifndef GAMEPLAY_ABILITIES_CORE_TAG_QUERY_H
#define GAMEPLAY_ABILITIES_CORE_TAG_QUERY_H

#include "core/ga_bytes.h"
#include "core/ga_ids.h"
#include "core/ga_status.h"

#include <cstdint>
#include <vector>

// Immutable, normalized tag-query expressions: `all`/`any`/`none` clauses over
// tag operands, each operand carrying its own exact-vs-parent-aware match mode.
//
// Representation: a `TagQuery` is a small flat arena (`nodes`), not a
// pointer-based tree. Node 0 is the root; a node's `children` are indices of
// nested sub-clauses, and by construction every child index is strictly
// greater than its own node's index. That single invariant makes the whole
// arena acyclic by construction, so encoding, decoding, evaluating, and
// depth-checking are all implemented as flat, iterative passes over `nodes`
// (a simple loop, or a loop from the last index backward so every node's
// children are already resolved) -- never recursive function calls -- which is
// what lets a decoded, attacker-controlled node count/nesting shape be
// rejected (`MAX_QUERY_DEPTH`, `MAX_QUERY_OPERANDS`) without ever growing the
// C++ call stack or allocating proportional to an unvalidated count.
//
// Normal form (what makes two differently-authored, logically-equivalent
// queries serialize to identical bytes/hash):
//   - Within one node, operands are sorted ascending by `(tag, mode)` and
//     exact duplicates are removed.
//   - Sibling child clauses are sorted ascending by their OWN canonical
//     encoded bytes (computed bottom-up, since children are already-built,
//     already-normalized `TagQuery` values by the time they are composed into
//     a parent) and exact duplicate children are removed.
//   - `build_requirements` additionally omits a group's clause entirely when
///    that group has no operands, and skips the synthetic wrapping root when
//     only one group is present -- so the extremely common "one all-list" or
//     "one any-list" query never carries an unnecessary extra node.
// This guarantees operand-order and clause-order invariance for any query
// built through this file's public constructors; it does not claim to unify
// every conceivable alternate construction path (e.g. `compose` around a
// single already-standalone child always keeps that wrapping node, while
// `build_requirements` collapses it -- both are documented, neither is hidden).
namespace ga {

class TagContainer;

enum class TagMatchMode : std::uint8_t {
	EXACT = 0,
	PARENT_AWARE = 1,
};

enum class TagClauseKind : std::uint8_t {
	ALL = 0,
	ANY = 1,
	NONE = 2,
};

// One leaf term: a tag id plus how it must be matched against a container.
struct TagQueryOperand {
	DefinitionId tag = INVALID_DEFINITION_ID;
	TagMatchMode mode = TagMatchMode::EXACT;

	bool operator==(const TagQueryOperand &p_other) const {
		return tag == p_other.tag && mode == p_other.mode;
	}
	bool operator<(const TagQueryOperand &p_other) const {
		if (tag != p_other.tag) {
			return tag < p_other.tag;
		}
		return static_cast<std::uint8_t>(mode) < static_cast<std::uint8_t>(p_other.mode);
	}
};

class TagQuery {
public:
	// The trivial always-true query: a single ALL clause with no operands and
	// no children (an empty AND).
	TagQuery();

	// Builds a leaf-level clause directly from tag operands, with no nested
	// sub-clauses. Equivalent to `compose(p_kind, p_operands, {})`.
	static Status build_clause(TagClauseKind p_kind, std::vector<TagQueryOperand> p_operands, TagQuery &r_query);

	// Composes a new root of kind `p_kind` over `p_operands` (attached
	// directly) and `p_children` (each an already-built, already-valid
	// `TagQuery`, nested as sub-clauses). Depth becomes `1 + max(child
	// depth)`; total node count is the sum of every child's node count plus
	// one for the new root.
	//
	// Fails (this `TagQuery` is left as the trivial always-true query) with:
	//   - `StatusCode::INVALID_QUERY` / `DiagnosticId::QUERY_TOO_MANY_OPERANDS`
	//     if `p_operands.size() + p_children.size()` exceeds
	//     `MAX_QUERY_OPERANDS`, or if the resulting total node count would.
	//   - `StatusCode::INVALID_QUERY` / `DiagnosticId::QUERY_TOO_DEEP` if the
	//     resulting depth would exceed `MAX_QUERY_DEPTH`.
	static Status compose(TagClauseKind p_kind, std::vector<TagQueryOperand> p_operands, const std::vector<TagQuery> &p_children, TagQuery &r_query);

	// Convenience matching the addon's common "activation requirements" shape:
	// an implicit AND of an all-list, an any-list (at least one), and a
	// none-list (none may match), skipping any list that is empty. See class
	// comment for the exact collapsing rule.
	static Status build_requirements(std::vector<TagQueryOperand> p_all, std::vector<TagQueryOperand> p_any, std::vector<TagQueryOperand> p_none, TagQuery &r_query);

	// Structural nesting depth (root = 1) and total flat node count.
	std::size_t depth() const { return cached_depth; }
	std::size_t node_count() const { return nodes.size(); }

	// Deterministic evaluation against `p_container`'s CURRENT state. Callers
	// must only call this against a container that is not mid-batch (see
	// `TagContainer::apply_mutations`): the container never exposes a
	// partially-applied state to any code that could observe it (including a
	// notification listener, which always runs after the whole batch has
	// already been applied), so any call site that has a live `const
	// TagContainer&` is, by construction, looking at a stable snapshot.
	bool evaluate(const TagContainer &p_container) const;

	// Canonical serialization (see class comment for the normal form).
	Status encode(ByteWriter &p_writer) const;

	// Untrusted-input decode: validates every count against
	// `MAX_QUERY_OPERANDS`, every child index against `[current_index + 1,
	// node_count)` (which simultaneously bounds it and rules out cycles/
	// self-references), every operand/child list's canonical ascending order,
	// and the resulting depth against `MAX_QUERY_DEPTH` -- all as flat,
	// non-recursive passes. Fails closed with `StatusCode::DECODE_FAILED` for
	// any structural malformation, or `StatusCode::INVALID_QUERY` /
	// `DiagnosticId::QUERY_TOO_DEEP` / `QUERY_TOO_MANY_OPERANDS` for a
	// payload that is well-formed but exceeds a documented bound.
	static Status decode(ByteReader &p_reader, TagQuery &r_query);

	// FNV1a64 over the same canonical bytes `encode()` produces.
	std::uint64_t hash() const;

	// Structural equality over canonical form (two queries built from
	// differently-ordered but logically-equivalent input compare equal).
	bool operator==(const TagQuery &p_other) const;
	bool operator!=(const TagQuery &p_other) const { return !(*this == p_other); }

private:
	struct Node {
		TagClauseKind kind = TagClauseKind::ALL;
		std::vector<TagQueryOperand> operands;
		std::vector<std::uint32_t> children; // each > this node's own index
	};

	static bool matches(const TagQueryOperand &p_operand, const TagContainer &p_container);
	static Status compute_depth(const std::vector<Node> &p_nodes, std::size_t &r_depth);

	std::vector<Node> nodes;
	std::size_t cached_depth = 1;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TAG_QUERY_H
