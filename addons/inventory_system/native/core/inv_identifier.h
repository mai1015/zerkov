#ifndef INVENTORY_SYSTEM_CORE_IDENTIFIER_H
#define INVENTORY_SYSTEM_CORE_IDENTIFIER_H

#include "core/inv_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace inv {

using DefinitionId = std::uint32_t;
constexpr DefinitionId INVALID_DEFINITION_ID = 0;

// Grammar: segment ('.' segment)+
// segment: [a-z][a-z0-9_]*
// ASCII lower case avoids locale and filesystem case behavior in canonical
// content identity.
Status validate_identifier(const std::string &p_identifier);
bool identifier_less(const std::string &p_a, const std::string &p_b);

using IdentifierHashFunction = std::uint64_t (*)(const std::string &);
std::uint64_t stable_identifier_hash(const std::string &p_identifier);

struct IdentifierConflict {
	std::string identifier;
	std::string existing_source;
	std::string incoming_source;
	std::string hash_owner_identifier;
	std::uint64_t content_hash = 0;
};

class IdentifierTable {
public:
	explicit IdentifierTable(IdentifierHashFunction p_hash_function = stable_identifier_hash) :
			hash_function(p_hash_function) {}

	Status intern(
			const std::string &p_identifier,
			const std::string &p_source_label,
			DefinitionId &r_id,
			IdentifierConflict *r_conflict = nullptr);

	Status seal();

	bool sealed() const { return is_sealed; }
	std::size_t size() const { return entries.size(); }
	DefinitionId lookup(const std::string &p_identifier) const;
	const std::string *name_of(DefinitionId p_id) const;
	const std::string *source_of(DefinitionId p_id) const;
	std::vector<DefinitionId> canonical_order() const;
	// Fingerprint is only defined for sealed tables; unsealed tables report 0.
	std::uint64_t fingerprint() const;

private:
	struct Entry {
		DefinitionId id = INVALID_DEFINITION_ID;
		std::string source_label;
		std::uint64_t content_hash = 0;
	};

	std::map<std::string, Entry> entries;
	std::map<std::uint64_t, std::string> hash_index;
	std::vector<std::string> id_to_name;
	std::vector<std::string> id_to_source;
	IdentifierHashFunction hash_function = stable_identifier_hash;
	bool is_sealed = false;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_IDENTIFIER_H
