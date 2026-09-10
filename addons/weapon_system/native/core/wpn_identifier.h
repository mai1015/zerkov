#ifndef WEAPON_SYSTEM_CORE_IDENTIFIER_H
#define WEAPON_SYSTEM_CORE_IDENTIFIER_H

#include "core/wpn_status.h"

#include <string>

namespace wpn {

Status validate_identifier(const std::string &p_identifier);
bool canonical_identifier_less(const std::string &p_a, const std::string &p_b);

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_IDENTIFIER_H
