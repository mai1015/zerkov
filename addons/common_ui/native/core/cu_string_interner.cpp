#include "core/cu_string_interner.h"

namespace cu {

Id StringInterner::intern(const std::string &p_text) {
	if (p_text.empty()) {
		return INVALID_ID;
	}
	auto found = ids.find(p_text);
	if (found != ids.end()) {
		return found->second;
	}
	const Id id = static_cast<Id>(texts.size());
	texts.push_back(p_text);
	ids.emplace(p_text, id);
	return id;
}

Id StringInterner::find(const std::string &p_text) const {
	if (p_text.empty()) {
		return INVALID_ID;
	}
	auto found = ids.find(p_text);
	return found == ids.end() ? INVALID_ID : found->second;
}

const std::string &StringInterner::text(Id p_id) const {
	if (p_id >= texts.size()) {
		return texts[0];
	}
	return texts[p_id];
}

} // namespace cu
