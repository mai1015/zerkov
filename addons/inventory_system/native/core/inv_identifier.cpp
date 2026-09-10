#include "core/inv_identifier.h"

#include "core/inv_hash.h"
#include "core/inv_limits.h"

namespace inv {

namespace {

bool is_lower_alpha(char p_char) {
	return p_char >= 'a' && p_char <= 'z';
}

bool is_segment_body(char p_char) {
	return is_lower_alpha(p_char) || (p_char >= '0' && p_char <= '9') || p_char == '_';
}

void clear_conflict(IdentifierConflict *r_conflict) {
	if (r_conflict != nullptr) {
		*r_conflict = IdentifierConflict{};
	}
}

} // namespace

Status validate_identifier(const std::string &p_identifier) {
	if (p_identifier.empty()) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_EMPTY_SEGMENT);
	}
	if (p_identifier.size() > MAX_IDENTIFIER_BYTES) {
		return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_TOO_LONG, p_identifier.size());
	}

	std::size_t segments = 0;
	std::size_t segment_start = 0;
	for (std::size_t i = 0; i <= p_identifier.size(); ++i) {
		const bool boundary = i == p_identifier.size() || p_identifier[i] == '.';
		if (!boundary) {
			continue;
		}

		if (i == segment_start) {
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

bool identifier_less(const std::string &p_a, const std::string &p_b) {
	return p_a.compare(p_b) < 0;
}

std::uint64_t stable_identifier_hash(const std::string &p_identifier) {
	return hash_string(p_identifier);
}

Status IdentifierTable::intern(
		const std::string &p_identifier,
		const std::string &p_source_label,
		DefinitionId &r_id,
		IdentifierConflict *r_conflict) {
	r_id = INVALID_DEFINITION_ID;
	clear_conflict(r_conflict);

	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}

	Status status = validate_identifier(p_identifier);
	if (!status.ok()) {
		return status;
	}
	if (p_source_label.size() > MAX_SOURCE_LABEL_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::SOURCE_LABEL_TOO_LONG, p_source_label.size());
	}

	const auto duplicate = entries.find(p_identifier);
	if (duplicate != entries.end()) {
		if (r_conflict != nullptr) {
			r_conflict->identifier = p_identifier;
			r_conflict->existing_source = duplicate->second.source_label;
			r_conflict->incoming_source = p_source_label;
			r_conflict->content_hash = duplicate->second.content_hash;
		}
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
	}

	const std::uint64_t content_hash = hash_function(p_identifier);
	const auto collision = hash_index.find(content_hash);
	if (collision != hash_index.end() && collision->second != p_identifier) {
		if (r_conflict != nullptr) {
			r_conflict->identifier = p_identifier;
			r_conflict->incoming_source = p_source_label;
			r_conflict->hash_owner_identifier = collision->second;
			r_conflict->existing_source = entries.at(collision->second).source_label;
			r_conflict->content_hash = content_hash;
		}
		return make_status(StatusCode::HASH_COLLISION, DiagnosticId::DEFINITION_HASH_COLLISION, content_hash);
	}

	entries.emplace(p_identifier, Entry{ INVALID_DEFINITION_ID, p_source_label, content_hash });
	hash_index.emplace(content_hash, p_identifier);
	return ok_status();
}

Status IdentifierTable::seal() {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	if (entries.size() > MAX_CATALOG_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, entries.size());
	}

	id_to_name.assign(entries.size() + 1, std::string());
	id_to_source.assign(entries.size() + 1, std::string());
	DefinitionId id = 1;
	for (auto &pair : entries) {
		pair.second.id = id;
		id_to_name[id] = pair.first;
		id_to_source[id] = pair.second.source_label;
		++id;
	}
	is_sealed = true;
	return ok_status();
}

DefinitionId IdentifierTable::lookup(const std::string &p_identifier) const {
	if (!is_sealed) {
		return INVALID_DEFINITION_ID;
	}
	const auto found = entries.find(p_identifier);
	return found == entries.end() ? INVALID_DEFINITION_ID : found->second.id;
}

const std::string *IdentifierTable::name_of(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= id_to_name.size()) {
		return nullptr;
	}
	return &id_to_name[p_id];
}

const std::string *IdentifierTable::source_of(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= id_to_source.size()) {
		return nullptr;
	}
	return &id_to_source[p_id];
}

std::vector<DefinitionId> IdentifierTable::canonical_order() const {
	std::vector<DefinitionId> result;
	if (!is_sealed) {
		return result;
	}
	result.reserve(entries.size());
	for (const auto &pair : entries) {
		result.push_back(pair.second.id);
	}
	return result;
}

std::uint64_t IdentifierTable::fingerprint() const {
	if (!is_sealed) {
		return 0;
	}
	Hasher hasher;
	for (const auto &pair : entries) {
		hasher.write_string(pair.first);
		hasher.write_u32(pair.second.id);
	}
	return hasher.digest();
}

} // namespace inv
