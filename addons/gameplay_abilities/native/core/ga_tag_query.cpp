#include "core/ga_tag_query.h"

#include "core/ga_hash.h"
#include "core/ga_limits.h"
#include "core/ga_tag_container.h"

#include <algorithm>

namespace ga {

namespace {
// Not a second normative wire constant: this bounds the query arena's total
// flat node count (root + every nested sub-clause) so a decoded payload
// cannot claim wide branching at every one of MAX_QUERY_DEPTH levels and
// force an allocation before validation completes. Reusing MAX_QUERY_OPERANDS
// keeps a single documented "how big can one query get" number rather than
// inventing an unrelated one.
constexpr std::size_t MAX_QUERY_NODES = MAX_QUERY_OPERANDS;
} // namespace

TagQuery::TagQuery() {
	nodes.push_back(Node{});
	cached_depth = 1;
}

bool TagQuery::matches(const TagQueryOperand &p_operand, const TagContainer &p_container) {
	return p_operand.mode == TagMatchMode::EXACT ? p_container.has_exact(p_operand.tag) : p_container.has_parent_aware(p_operand.tag);
}

Status TagQuery::compute_depth(const std::vector<Node> &p_nodes, std::size_t &r_depth) {
	if (p_nodes.empty()) {
		r_depth = 0;
		return ok_status();
	}
	std::vector<std::size_t> depth(p_nodes.size(), 1);
	for (std::size_t i = p_nodes.size(); i-- > 0;) {
		std::size_t d = 1;
		for (std::uint32_t child : p_nodes[i].children) {
			d = std::max(d, std::size_t(1) + depth[child]);
		}
		depth[i] = d;
	}
	r_depth = depth[0];
	return ok_status();
}

Status TagQuery::build_clause(TagClauseKind p_kind, std::vector<TagQueryOperand> p_operands, TagQuery &r_query) {
	return compose(p_kind, std::move(p_operands), {}, r_query);
}

Status TagQuery::compose(TagClauseKind p_kind, std::vector<TagQueryOperand> p_operands, const std::vector<TagQuery> &p_children, TagQuery &r_query) {
	if (p_operands.size() + p_children.size() > MAX_QUERY_OPERANDS) {
		return make_status(StatusCode::INVALID_QUERY, DiagnosticId::QUERY_TOO_MANY_OPERANDS, p_operands.size() + p_children.size());
	}

	// Normal form, step 1: sort + dedupe this node's own operands.
	std::sort(p_operands.begin(), p_operands.end());
	p_operands.erase(std::unique(p_operands.begin(), p_operands.end()), p_operands.end());

	// Normal form, step 2: sort + dedupe sibling children by their OWN
	// already-canonical encoded bytes, computed bottom-up.
	struct ChildEntry {
		std::vector<std::uint8_t> bytes;
		const TagQuery *query = nullptr;
	};
	std::vector<ChildEntry> entries;
	entries.reserve(p_children.size());
	for (const TagQuery &child : p_children) {
		ByteWriter writer;
		const Status encoded = child.encode(writer);
		if (!encoded.ok()) {
			return encoded;
		}
		entries.push_back(ChildEntry{ writer.bytes(), &child });
	}
	std::stable_sort(entries.begin(), entries.end(), [](const ChildEntry &a, const ChildEntry &b) {
		return a.bytes < b.bytes;
	});
	entries.erase(std::unique(entries.begin(), entries.end(), [](const ChildEntry &a, const ChildEntry &b) {
		return a.bytes == b.bytes;
	}),
			entries.end());

	std::size_t total_nodes = 1; // the new root
	std::size_t max_child_depth = 0;
	for (const ChildEntry &entry : entries) {
		total_nodes += entry.query->nodes.size();
		max_child_depth = std::max(max_child_depth, entry.query->cached_depth);
	}
	if (total_nodes > MAX_QUERY_NODES) {
		return make_status(StatusCode::INVALID_QUERY, DiagnosticId::QUERY_TOO_MANY_OPERANDS, total_nodes);
	}
	const std::size_t new_depth = 1 + max_child_depth;
	if (new_depth > MAX_QUERY_DEPTH) {
		return make_status(StatusCode::INVALID_QUERY, DiagnosticId::QUERY_TOO_DEEP, new_depth);
	}

	TagQuery result;
	result.nodes.clear();
	Node root;
	root.kind = p_kind;
	root.operands = std::move(p_operands);
	result.nodes.push_back(std::move(root));

	std::vector<std::uint32_t> root_children;
	root_children.reserve(entries.size());
	for (const ChildEntry &entry : entries) {
		const std::uint32_t offset = static_cast<std::uint32_t>(result.nodes.size());
		for (Node node : entry.query->nodes) {
			for (std::uint32_t &child_index : node.children) {
				child_index += offset;
			}
			result.nodes.push_back(std::move(node));
		}
		root_children.push_back(offset);
	}
	result.nodes[0].children = std::move(root_children);
	result.cached_depth = new_depth;

	r_query = std::move(result);
	return ok_status();
}

Status TagQuery::build_requirements(std::vector<TagQueryOperand> p_all, std::vector<TagQueryOperand> p_any, std::vector<TagQueryOperand> p_none, TagQuery &r_query) {
	std::vector<TagQuery> groups;

	if (!p_all.empty()) {
		TagQuery q;
		const Status s = build_clause(TagClauseKind::ALL, std::move(p_all), q);
		if (!s.ok()) {
			return s;
		}
		groups.push_back(std::move(q));
	}
	if (!p_any.empty()) {
		TagQuery q;
		const Status s = build_clause(TagClauseKind::ANY, std::move(p_any), q);
		if (!s.ok()) {
			return s;
		}
		groups.push_back(std::move(q));
	}
	if (!p_none.empty()) {
		TagQuery q;
		const Status s = build_clause(TagClauseKind::NONE, std::move(p_none), q);
		if (!s.ok()) {
			return s;
		}
		groups.push_back(std::move(q));
	}

	if (groups.empty()) {
		r_query = TagQuery();
		return ok_status();
	}
	if (groups.size() == 1) {
		r_query = std::move(groups[0]);
		return ok_status();
	}
	return compose(TagClauseKind::ALL, {}, groups, r_query);
}

bool TagQuery::evaluate(const TagContainer &p_container) const {
	if (nodes.empty()) {
		return true;
	}

	std::vector<bool> results(nodes.size(), false);
	// Every child index is strictly greater than its own node's index, so
	// processing from the last node backward guarantees each node's children
	// are already resolved -- an iterative bottom-up pass, no recursion.
	for (std::size_t i = nodes.size(); i-- > 0;) {
		const Node &node = nodes[i];
		bool result = false;
		switch (node.kind) {
			case TagClauseKind::ALL: {
				result = true;
				for (const TagQueryOperand &op : node.operands) {
					if (!matches(op, p_container)) {
						result = false;
						break;
					}
				}
				if (result) {
					for (std::uint32_t child : node.children) {
						if (!results[child]) {
							result = false;
							break;
						}
					}
				}
				break;
			}
			case TagClauseKind::ANY: {
				result = false;
				for (const TagQueryOperand &op : node.operands) {
					if (matches(op, p_container)) {
						result = true;
						break;
					}
				}
				if (!result) {
					for (std::uint32_t child : node.children) {
						if (results[child]) {
							result = true;
							break;
						}
					}
				}
				break;
			}
			case TagClauseKind::NONE: {
				result = true; // true = no violation found yet
				for (const TagQueryOperand &op : node.operands) {
					if (matches(op, p_container)) {
						result = false;
						break;
					}
				}
				if (result) {
					for (std::uint32_t child : node.children) {
						if (results[child]) {
							result = false;
							break;
						}
					}
				}
				break;
			}
		}
		results[i] = result;
	}
	return results[0];
}

Status TagQuery::encode(ByteWriter &p_writer) const {
	p_writer.write_count(nodes.size(), MAX_QUERY_NODES);
	for (const Node &node : nodes) {
		p_writer.write_u8(static_cast<std::uint8_t>(node.kind));
		p_writer.write_count(node.operands.size(), MAX_QUERY_OPERANDS);
		for (const TagQueryOperand &op : node.operands) {
			p_writer.write_u32(op.tag);
			p_writer.write_u8(static_cast<std::uint8_t>(op.mode));
		}
		p_writer.write_count(node.children.size(), MAX_QUERY_OPERANDS);
		for (std::uint32_t child : node.children) {
			p_writer.write_u32(child);
		}
	}
	return p_writer.status();
}

Status TagQuery::decode(ByteReader &p_reader, TagQuery &r_query) {
	std::size_t node_count = 0;
	if (!p_reader.read_count(node_count, MAX_QUERY_NODES, /*p_min_bytes_per_element=*/5)) {
		return p_reader.status();
	}
	if (node_count == 0) {
		// Every query this file's own constructors produce has at least one
		// (root) node; a claimed empty arena is a structural malformation,
		// not an alternate encoding of "always true".
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}

	std::vector<Node> decoded(node_count);
	for (std::size_t i = 0; i < node_count; ++i) {
		std::uint8_t kind_raw = 0;
		if (!p_reader.read_u8(kind_raw)) {
			return p_reader.status();
		}
		if (kind_raw > static_cast<std::uint8_t>(TagClauseKind::NONE)) {
			p_reader.fail(DiagnosticId::INVALID_ENUM);
			return p_reader.status();
		}
		decoded[i].kind = static_cast<TagClauseKind>(kind_raw);

		std::size_t operand_count = 0;
		if (!p_reader.read_count(operand_count, MAX_QUERY_OPERANDS, /*p_min_bytes_per_element=*/5)) {
			return p_reader.status();
		}
		decoded[i].operands.reserve(operand_count);
		for (std::size_t j = 0; j < operand_count; ++j) {
			std::uint32_t tag_raw = 0;
			std::uint8_t mode_raw = 0;
			if (!p_reader.read_u32(tag_raw)) {
				return p_reader.status();
			}
			if (!p_reader.read_u8(mode_raw)) {
				return p_reader.status();
			}
			if (mode_raw > static_cast<std::uint8_t>(TagMatchMode::PARENT_AWARE)) {
				p_reader.fail(DiagnosticId::INVALID_ENUM);
				return p_reader.status();
			}
			decoded[i].operands.push_back(TagQueryOperand{ DefinitionId(tag_raw), static_cast<TagMatchMode>(mode_raw) });
		}
		for (std::size_t j = 1; j < decoded[i].operands.size(); ++j) {
			if (!(decoded[i].operands[j - 1] < decoded[i].operands[j])) {
				p_reader.fail(DiagnosticId::INVALID_ENUM);
				return p_reader.status();
			}
		}

		std::size_t child_count = 0;
		if (!p_reader.read_count(child_count, MAX_QUERY_OPERANDS, /*p_min_bytes_per_element=*/4)) {
			return p_reader.status();
		}
		if (operand_count + child_count > MAX_QUERY_OPERANDS) {
			return make_status(StatusCode::INVALID_QUERY, DiagnosticId::QUERY_TOO_MANY_OPERANDS, operand_count + child_count);
		}
		decoded[i].children.reserve(child_count);
		for (std::size_t j = 0; j < child_count; ++j) {
			std::uint32_t child_index = 0;
			if (!p_reader.read_u32(child_index)) {
				return p_reader.status();
			}
			// Strictly greater than this node's own index: bounds the index,
			// and rules out any cycle/self-reference in one check.
			if (child_index <= i || child_index >= node_count) {
				p_reader.fail(DiagnosticId::INVALID_ENUM);
				return p_reader.status();
			}
			decoded[i].children.push_back(child_index);
		}
		for (std::size_t j = 1; j < decoded[i].children.size(); ++j) {
			if (!(decoded[i].children[j - 1] < decoded[i].children[j])) {
				p_reader.fail(DiagnosticId::INVALID_ENUM);
				return p_reader.status();
			}
		}
	}

	std::size_t depth = 0;
	const Status depth_status = compute_depth(decoded, depth);
	if (!depth_status.ok()) {
		return depth_status;
	}
	if (depth > MAX_QUERY_DEPTH) {
		return make_status(StatusCode::INVALID_QUERY, DiagnosticId::QUERY_TOO_DEEP, depth);
	}

	r_query.nodes = std::move(decoded);
	r_query.cached_depth = depth;
	return ok_status();
}

std::uint64_t TagQuery::hash() const {
	ByteWriter writer;
	encode(writer); // a validly-constructed TagQuery's own encode() cannot fail
	return hash_bytes(writer.bytes());
}

bool TagQuery::operator==(const TagQuery &p_other) const {
	ByteWriter a;
	ByteWriter b;
	encode(a);
	p_other.encode(b);
	return a.bytes() == b.bytes();
}

} // namespace ga
