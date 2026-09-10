#ifndef GAMEPLAY_ABILITIES_CORE_MANIFEST_H
#define GAMEPLAY_ABILITIES_CORE_MANIFEST_H

#include "core/ga_hash.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

// At session start, every peer folds its sorted canonical definitions into a
// single content-manifest fingerprint. Client and server compare fingerprints
// during the handshake and refuse to exchange gameplay commands on a
// mismatch (see `ContentManifest::compare`), so a version skew, a missed
// content file, or a definition edit fails loudly instead of silently
// diverging simulation.
namespace ga {

// One canonical entry's category. Declaration order here IS the canonical
// sort order's primary key (`(kind, identifier)`), so appending a new kind
// must go at the end to avoid reshuffling every existing fingerprint.
enum class ManifestEntryKind : std::uint8_t {
	TAG = 0,
	ATTRIBUTE = 1,
	EFFECT = 2,
	ABILITY = 3,
	CUE = 4,
	TARGET_SCHEMA = 5,
	// Declarative tag-reaction definitions (native/core/ga_tag_reactions.h;
	// see that file's own header comment). Appended at the end per this
	// enum's own ordering rule.
	REACTION = 6,
};

struct ContentManifest;

// Accumulates one session's definitions and folds them into a
// `ContentManifest`. Each definition contributes its own already-canonical
// byte encoding (`p_canonical_fields`) -- `ManifestBuilder` does not know or
// care about tag/attribute/effect/ability internals, only that the bytes are
// deterministic for equivalent content.
class ManifestBuilder {
public:
	explicit ManifestBuilder(std::uint32_t p_tick_rate = DEFAULT_TICK_RATE) :
			tick_rate(p_tick_rate) {}

	// Validates `p_identifier` and registers one canonical entry. Fails with
	// the identifier grammar's own `Status` if malformed, or with
	// `StatusCode::DUPLICATE_DEFINITION` / `DiagnosticId::DEFINITION_DUPLICATE`
	// if `(p_kind, p_identifier)` was already added. The same identifier
	// string may be reused across different kinds (a tag and an attribute
	// could coincidentally share spelling); uniqueness is only enforced
	// within one kind.
	Status add(ManifestEntryKind p_kind, const std::string &p_identifier, const std::vector<std::uint8_t> &p_canonical_fields);

	// Sorts every entry by `(kind, identifier)` and hashes them in that
	// order with `ga::Hasher`, additionally mixing in `GA_PROTOCOL_VERSION`,
	// `FIXED_SCALE`, and the tick rate this builder was constructed with, so
	// a protocol, numeric-scale, or tick-rate skew changes the fingerprint
	// even if every definition byte is identical.
	Status build(ContentManifest &r_out) const;

private:
	using Key = std::pair<ManifestEntryKind, std::string>;

	std::map<Key, std::vector<std::uint8_t>> entries;
	std::uint32_t tick_rate = DEFAULT_TICK_RATE;
};

// The exchanged, compared handshake artifact. Two components (or two peers)
// that agree on every field are guaranteed -- barring an FNV1a64 collision --
// to be running identical content against an identical tick rate.
struct ContentManifest {
	std::uint64_t fingerprint = 0;
	std::uint32_t entry_count = 0;
	std::uint32_t tick_rate = 0;

	// `StatusCode::MANIFEST_MISMATCH` / `DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS`
	// if any field differs; `detail` carries `p_other.fingerprint`.
	Status compare(const ContentManifest &p_other) const;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_MANIFEST_H
