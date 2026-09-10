#include "core/wpn_identifier.h"

#include "core/wpn_limits.h"

#include <cctype>

namespace wpn {

Status validate_identifier(const std::string &p_identifier) {
	if (p_identifier.empty() || p_identifier.size() > MAX_IDENTIFIER_BYTES) {
		return make_status(StatusCode::INVALID_IDENTIFIER,
				p_identifier.empty() ? DiagnosticId::IDENTIFIER_INVALID : DiagnosticId::IDENTIFIER_TOO_LONG,
				p_identifier.size());
	}
	bool has_separator = false;
	bool segment_start = true;
	std::size_t index = 0;
	for (unsigned char c : p_identifier) {
		if (c == '.' || c == '-' || c == ':') {
			if (segment_start) return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_INVALID);
			has_separator = true;
			segment_start = true;
			continue;
		}
		if (segment_start) {
			const bool first = index == 0;
			const bool valid_start = (c >= 'a' && c <= 'z') || (!first && c >= '0' && c <= '9');
			if (!valid_start) return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_INVALID, c);
			segment_start = false;
			++index;
			continue;
		}
		if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_INVALID, c);
		}
		++index;
	}
	if (segment_start || !has_separator) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_INVALID);
	}
	return ok_status();
}

bool canonical_identifier_less(const std::string &p_a, const std::string &p_b) {
	return p_a < p_b;
}

} // namespace wpn
