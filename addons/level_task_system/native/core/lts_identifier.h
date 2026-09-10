#ifndef LEVEL_TASK_SYSTEM_CORE_IDENTIFIER_H
#define LEVEL_TASK_SYSTEM_CORE_IDENTIFIER_H

#include "core/lts_status.h"

#include <string>
#include <vector>

namespace lts {

// Resource/provider/speaker identifiers use a namespaced form such as
// `mission.harbor.escape`. Node, port, choice, outcome, anchor, and edge ids
// are local to their owning definition and may use one valid segment. Both
// grammars are ASCII-only and reject case folding, whitespace, and alternate
// separators so canonical bytes are locale/platform independent.
Status validate_identifier(const std::string &p_identifier);
Status validate_local_identifier(const std::string &p_identifier);

// Canonicalization is intentionally conservative: valid authored input is
// already canonical, while ambiguous spellings are rejected rather than
// silently lower-cased or trimmed. The output is unchanged on failure.
Status canonicalize_identifier(const std::string &p_identifier, std::string &r_canonical);
Status canonicalize_local_identifier(const std::string &p_identifier, std::string &r_canonical);

inline bool identifier_less(const std::string &p_a, const std::string &p_b) {
	return p_a.compare(p_b) < 0;
}

inline bool local_identifier_less(const std::string &p_a, const std::string &p_b) {
	return p_a.compare(p_b) < 0;
}

// A small value wrapper is useful at adapter boundaries where a caller wants
// validation at construction time, while definitions retain std::string
// fields for cheap copy-safe Godot conversion.
struct StableIdentifier {
	std::string value;

	static Status from_string(const std::string &p_value, StableIdentifier &r_out);
	Status validate() const { return validate_identifier(value); }

	bool empty() const { return value.empty(); }
	bool operator==(const StableIdentifier &p_other) const { return value == p_other.value; }
	bool operator!=(const StableIdentifier &p_other) const { return !(*this == p_other); }
	bool operator<(const StableIdentifier &p_other) const { return identifier_less(value, p_other.value); }
};

using Identifier = StableIdentifier;

struct LocalIdentifier {
	std::string value;

	static Status from_string(const std::string &p_value, LocalIdentifier &r_out);
	Status validate() const { return validate_local_identifier(value); }

	bool empty() const { return value.empty(); }
	bool operator==(const LocalIdentifier &p_other) const { return value == p_other.value; }
	bool operator!=(const LocalIdentifier &p_other) const { return !(*this == p_other); }
	bool operator<(const LocalIdentifier &p_other) const { return local_identifier_less(value, p_other.value); }
};

using LocalId = LocalIdentifier;

std::vector<std::string> identifier_segments(const std::string &p_identifier);
std::vector<std::string> local_identifier_segments(const std::string &p_identifier);

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_IDENTIFIER_H
