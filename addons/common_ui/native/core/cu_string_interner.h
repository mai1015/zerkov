#ifndef COMMON_UI_CORE_STRING_INTERNER_H
#define COMMON_UI_CORE_STRING_INTERNER_H

#include "core/cu_ids.h"

#include <string>
#include <unordered_map>
#include <vector>

namespace cu {

// Maps names to dense integer ids so the core can compare and sort identifiers
// without depending on StringName. Ids are stable for the interner's lifetime
// and are never recycled.
class StringInterner {
public:
	// Returns the id for p_text, creating one if needed. Never returns INVALID_ID
	// for a non-empty string; an empty string always interns to INVALID_ID.
	Id intern(const std::string &p_text);

	// Returns the id for p_text, or INVALID_ID if it was never interned.
	Id find(const std::string &p_text) const;

	// Returns the text behind p_id, or an empty string for INVALID_ID and
	// out-of-range ids.
	const std::string &text(Id p_id) const;

	std::size_t size() const { return texts.size(); }

private:
	// Index 0 is reserved for INVALID_ID and holds the empty string.
	std::vector<std::string> texts{ std::string() };
	std::unordered_map<std::string, Id> ids;
};

} // namespace cu

#endif // COMMON_UI_CORE_STRING_INTERNER_H
