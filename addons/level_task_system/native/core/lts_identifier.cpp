#include "core/lts_identifier.h"

#include "core/lts_limits.h"

#include <cstddef>

namespace lts {

namespace {

bool is_lower_alpha(char p_character) {
	return p_character >= 'a' && p_character <= 'z';
}

bool is_segment_body(char p_character) {
	return is_lower_alpha(p_character) ||
			(p_character >= '0' && p_character <= '9') || p_character == '_';
}

Status validate_impl(const std::string &p_identifier, bool p_require_namespace) {
	if (p_identifier.empty()) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_EMPTY, 0);
	}
	if (p_identifier.size() > MAX_IDENTIFIER_BYTES) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_TOO_LONG, p_identifier.size());
	}

	std::size_t segment_count = 0;
	std::size_t segment_start = 0;
	for (std::size_t index = 0; index <= p_identifier.size(); ++index) {
		const bool boundary = index == p_identifier.size() || p_identifier[index] == '.';
		if (!boundary) continue;

		const std::size_t segment_length = index - segment_start;
		if (segment_length == 0) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_EMPTY, segment_start);
		}
		if (segment_length > MAX_IDENTIFIER_SEGMENT_BYTES) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_SEGMENT_TOO_LONG, segment_length);
		}
		if (!is_lower_alpha(p_identifier[segment_start])) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_BAD_CHARACTER, segment_start);
		}
		for (std::size_t character = segment_start + 1; character < index; ++character) {
			if (!is_segment_body(p_identifier[character])) {
				return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_BAD_CHARACTER, character);
			}
		}

		++segment_count;
		if (segment_count > MAX_IDENTIFIER_SEGMENTS) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_TOO_MANY_SEGMENTS, segment_count);
		}
		segment_start = index + 1;
	}

	if (p_require_namespace && segment_count < 2) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_NOT_NAMESPACED, segment_count);
	}
	return ok_status();
}

std::vector<std::string> split_valid(const std::string &p_identifier, bool p_require_namespace) {
	std::vector<std::string> result;
	if (!validate_impl(p_identifier, p_require_namespace).ok()) return result;

	std::size_t start = 0;
	for (std::size_t index = 0; index <= p_identifier.size(); ++index) {
		if (index == p_identifier.size() || p_identifier[index] == '.') {
			result.push_back(p_identifier.substr(start, index - start));
			start = index + 1;
		}
	}
	return result;
}

} // namespace

Status validate_identifier(const std::string &p_identifier) {
	return validate_impl(p_identifier, true);
}

Status validate_local_identifier(const std::string &p_identifier) {
	return validate_impl(p_identifier, false);
}

Status canonicalize_identifier(const std::string &p_identifier, std::string &r_canonical) {
	const Status status = validate_identifier(p_identifier);
	if (!status.ok()) return status;
	r_canonical = p_identifier;
	return ok_status();
}

Status canonicalize_local_identifier(const std::string &p_identifier, std::string &r_canonical) {
	const Status status = validate_local_identifier(p_identifier);
	if (!status.ok()) return status;
	r_canonical = p_identifier;
	return ok_status();
}

Status StableIdentifier::from_string(const std::string &p_value, StableIdentifier &r_out) {
	std::string canonical;
	const Status status = canonicalize_identifier(p_value, canonical);
	if (!status.ok()) {
		r_out.value.clear();
		return status;
	}
	r_out.value = canonical;
	return ok_status();
}

Status LocalIdentifier::from_string(const std::string &p_value, LocalIdentifier &r_out) {
	std::string canonical;
	const Status status = canonicalize_local_identifier(p_value, canonical);
	if (!status.ok()) {
		r_out.value.clear();
		return status;
	}
	r_out.value = canonical;
	return ok_status();
}

std::vector<std::string> identifier_segments(const std::string &p_identifier) {
	return split_valid(p_identifier, true);
}

std::vector<std::string> local_identifier_segments(const std::string &p_identifier) {
	return split_valid(p_identifier, false);
}

} // namespace lts
