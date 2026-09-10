#include "protocol/gap_identity.h"

namespace ga::proto {

Status SessionScope::validate_definition(DefinitionId p_id) const {
	if (p_id == INVALID_DEFINITION_ID || identifiers == nullptr || !identifiers->sealed()) {
		return make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY, DiagnosticId::NONE, p_id);
	}
	if (identifiers->name_of(p_id) == nullptr) {
		return make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY, DiagnosticId::NONE, p_id);
	}
	return ok_status();
}

} // namespace ga::proto
