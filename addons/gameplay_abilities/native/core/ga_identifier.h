#ifndef GAMEPLAY_ABILITIES_CORE_IDENTIFIER_H
#define GAMEPLAY_ABILITIES_CORE_IDENTIFIER_H

#include "core/ga_status.h"

#include <cstdint>
#include <string>
#include <vector>

// Every tag, attribute, effect, ability, cue, and target schema is named by a
// namespaced dotted identifier such as `state.control.stunned`. One validator
// serves the whole addon so an identifier accepted by the editor is exactly the
// identifier accepted by the network decoder.
//
// Grammar: segment ('.' segment)+ with at least two segments,
//          segment = [a-z][a-z0-9_]*
// Bounds:  <= MAX_IDENTIFIER_BYTES bytes, <= MAX_IDENTIFIER_SEGMENTS segments.
//
// The grammar is deliberately ASCII-lowercase-only: it removes locale-dependent
// case folding and filesystem case behavior from canonical state.
namespace ga {

// Validates the grammar and bounds. Returns OK or an INVALID_IDENTIFIER status
// whose diagnostic names the specific rule that failed.
Status validate_identifier(const std::string &p_identifier);

// Splits a validated identifier into its segments. Returns an empty vector for
// an identifier that would not validate.
std::vector<std::string> identifier_segments(const std::string &p_identifier);

// Returns the immediate parent (`state.control.stunned` -> `state.control`), or
// an empty string when the identifier has no parent inside the grammar.
std::string identifier_parent(const std::string &p_identifier);

// Returns every ancestor from the immediate parent up to the outermost
// namespace, in that order. Used to build parent-aware tag indexes.
std::vector<std::string> identifier_ancestors(const std::string &p_identifier);

// True when `p_candidate` is `p_ancestor` itself or is nested beneath it.
// Segment-aware: `state.controller` is NOT a descendant of `state.control`.
bool identifier_is_descendant_of(const std::string &p_candidate, const std::string &p_ancestor);

// Canonical ordering for identifiers. Plain byte comparison over the ASCII
// grammar is stable, locale-independent, and identical on every platform.
inline bool identifier_less(const std::string &p_a, const std::string &p_b) {
	return p_a.compare(p_b) < 0;
}

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_IDENTIFIER_H
