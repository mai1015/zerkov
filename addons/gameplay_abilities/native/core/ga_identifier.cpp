#include "core/ga_identifier.h"

#include "core/ga_limits.h"

namespace ga {

namespace {

bool is_lower_alpha(char p_c) {
	return p_c >= 'a' && p_c <= 'z';
}

bool is_segment_body(char p_c) {
	return is_lower_alpha(p_c) || (p_c >= '0' && p_c <= '9') || p_c == '_';
}

} // namespace

Status validate_identifier(const std::string &p_identifier) {
	if (p_identifier.empty()) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_EMPTY_SEGMENT, 0);
	}
	if (p_identifier.size() > MAX_IDENTIFIER_BYTES) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_TOO_LONG, p_identifier.size());
	}

	std::size_t segments = 0;
	std::size_t segment_start = 0;
	for (std::size_t i = 0; i <= p_identifier.size(); ++i) {
		const bool boundary = (i == p_identifier.size()) || p_identifier[i] == '.';
		if (!boundary) {
			continue;
		}

		const std::size_t length = i - segment_start;
		if (length == 0) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_EMPTY_SEGMENT, segment_start);
		}
		if (!is_lower_alpha(p_identifier[segment_start])) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_BAD_CHARACTER, segment_start);
		}
		for (std::size_t j = segment_start + 1; j < i; ++j) {
			if (!is_segment_body(p_identifier[j])) {
				return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_BAD_CHARACTER, j);
			}
		}

		++segments;
		if (segments > MAX_IDENTIFIER_SEGMENTS) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_TOO_MANY_SEGMENTS, segments);
		}
		segment_start = i + 1;
	}

	if (segments < 2) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_NOT_NAMESPACED, segments);
	}
	return ok_status();
}

std::vector<std::string> identifier_segments(const std::string &p_identifier) {
	std::vector<std::string> segments;
	if (!validate_identifier(p_identifier).ok()) {
		return segments;
	}

	std::size_t start = 0;
	for (std::size_t i = 0; i <= p_identifier.size(); ++i) {
		if (i == p_identifier.size() || p_identifier[i] == '.') {
			segments.push_back(p_identifier.substr(start, i - start));
			start = i + 1;
		}
	}
	return segments;
}

std::string identifier_parent(const std::string &p_identifier) {
	if (!validate_identifier(p_identifier).ok()) {
		return std::string();
	}
	const std::size_t last_dot = p_identifier.find_last_of('.');
	if (last_dot == std::string::npos) {
		return std::string();
	}
	const std::string parent = p_identifier.substr(0, last_dot);
	// A parent must itself be a legal namespaced identifier; `state` alone is a
	// namespace root rather than a usable tag identity.
	return validate_identifier(parent).ok() ? parent : std::string();
}

std::vector<std::string> identifier_ancestors(const std::string &p_identifier) {
	std::vector<std::string> ancestors;
	std::string current = identifier_parent(p_identifier);
	while (!current.empty()) {
		ancestors.push_back(current);
		current = identifier_parent(current);
	}
	return ancestors;
}

bool identifier_is_descendant_of(const std::string &p_candidate, const std::string &p_ancestor) {
	if (p_ancestor.empty() || p_candidate.size() < p_ancestor.size()) {
		return false;
	}
	if (p_candidate.compare(0, p_ancestor.size(), p_ancestor) != 0) {
		return false;
	}
	if (p_candidate.size() == p_ancestor.size()) {
		return true;
	}
	// Require a segment boundary so `state.controller` never matches
	// `state.control`.
	return p_candidate[p_ancestor.size()] == '.';
}

} // namespace ga
