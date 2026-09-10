#ifndef LEVEL_TASK_SYSTEM_CORE_LOCALIZATION_H
#define LEVEL_TASK_SYSTEM_CORE_LOCALIZATION_H

#include "core/lts_identifier.h"
#include "core/lts_limits.h"
#include "core/lts_status.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// Localization keys are part of canonical runtime data.  They deliberately
// use the same ASCII local-identifier grammar as step/choice/level labels and
// are bounded before they are copied into a definition or a frame.
Status validate_localization_key(const std::string &p_key);
Status validate_optional_localization_key(const std::string &p_key);
Status canonicalize_localization_key(const std::string &p_key, std::string &r_canonical);

// Draft text and extraction metadata are editor values, not definition
// values.  Keeping this record outside ConversationDefinition is intentional:
// changing a translation or its source context must never change a runtime
// definition fingerprint.  A draft may have an empty key while an author is
// composing text; an extraction proposal supplies the key that an explicit
// apply operation would use.
constexpr std::size_t MAX_LOCALIZATION_DRAFT_TEXT_BYTES = MAX_STRING_BYTES;
constexpr std::size_t MAX_LOCALIZATION_SOURCE_PATH_BYTES = MAX_DIAGNOSTIC_PATH_BYTES;
constexpr std::size_t MAX_LOCALIZATION_CONTEXT_BYTES = MAX_STRING_BYTES;
constexpr std::size_t MAX_LOCALIZATION_EXTRACTION_ENTRIES = MAX_STEPS_PER_CONVERSATION;

struct LocalizationDraft {
	std::string key;
	std::string text;
	std::string source_path;
	std::string context;

	// Empty keys are valid only for an in-progress editor draft.  Callers that
	// are about to emit a runtime definition should use validate_key() (or the
	// standalone validate_localization_key()) so the boundary is explicit.
	Status validate() const;
	Status validate_key() const { return validate_localization_key(key); }
	bool has_key() const { return !key.empty(); }
	const std::string &localization_key() const { return key; }
	const std::string &draft_text() const { return text; }

	bool operator==(const LocalizationDraft &p_other) const {
		return key == p_other.key && text == p_other.text && source_path == p_other.source_path && context == p_other.context;
	}
	bool operator!=(const LocalizationDraft &p_other) const { return !(*this == p_other); }
};

// One editor-side entry in an extraction catalog.  It intentionally stores
// source text, never translated runtime text, and has no relationship to a
// canonical ConversationDefinition object.
struct LocalizationExtractionEntry {
	std::string key;
	std::string text;
	std::string source_path;
	std::string context;

	Status validate() const;
	bool operator==(const LocalizationExtractionEntry &p_other) const {
		return key == p_other.key && text == p_other.text && source_path == p_other.source_path && context == p_other.context;
	}
	bool operator!=(const LocalizationExtractionEntry &p_other) const { return !(*this == p_other); }
	bool operator<(const LocalizationExtractionEntry &p_other) const;
};

// A bounded, deterministic editor-side extraction store.  It is deliberately
// separate from LevelTaskCatalog and from every canonical definition.  Its
// fingerprint is only a stale-proposal guard; it is never a runtime
// definition/catalog fingerprint.
struct LocalizationExtractionCatalog {
	std::vector<LocalizationExtractionEntry> entries;

	Status validate() const;
	Status validate_and_canonicalize();
	CatalogFingerprint fingerprint() const;
	const LocalizationExtractionEntry *find(const std::string &p_key) const;
	std::size_t size() const { return entries.size(); }

	bool operator==(const LocalizationExtractionCatalog &p_other) const { return entries == p_other.entries; }
	bool operator!=(const LocalizationExtractionCatalog &p_other) const { return !(*this == p_other); }
};

// A proposal is an explicit editor action.  `source_key` records the key on
// the draft at proposal time; `key` is the destination key.  When they differ
// (including an empty source key), `changes_runtime_identity` is true so the
// editor can require an explicit migration/confirmation instead of silently
// changing a saved line identity.
struct LocalizationExtractionProposal {
	std::string source_key;
	std::string key;
	std::string text;
	std::string source_path;
	std::string context;
	CatalogFingerprint source_catalog_fingerprint = INVALID_CATALOG_FINGERPRINT;
	bool creates_key = false;
	bool changes_runtime_identity = false;

	Status validate() const;
	bool is_identity_preserving() const { return !changes_runtime_identity; }
	const std::string &localization_key() const { return key; }

	bool operator==(const LocalizationExtractionProposal &p_other) const {
		return source_key == p_other.source_key && key == p_other.key && text == p_other.text &&
				source_path == p_other.source_path && context == p_other.context &&
				source_catalog_fingerprint == p_other.source_catalog_fingerprint && creates_key == p_other.creates_key &&
				changes_runtime_identity == p_other.changes_runtime_identity;
	}
	bool operator!=(const LocalizationExtractionProposal &p_other) const { return !(*this == p_other); }
};

class LocalizationExtractionPlanner {
public:
	// Build a deterministic proposal without mutating either input.  The
	// catalog fingerprint is captured so apply() can reject stale proposals.
	static Status propose(const LocalizationDraft &p_draft,
			const LocalizationExtractionCatalog &p_catalog,
			const std::string &p_target_key,
			LocalizationExtractionProposal &r_proposal);

	static Status propose(const LocalizationDraft &p_draft,
			const LocalizationExtractionCatalog &p_catalog,
			LocalizationExtractionProposal &r_proposal) {
		return propose(p_draft, p_catalog, p_draft.key, r_proposal);
	}

	// Apply to a copied extraction catalog.  The source catalog and proposal
	// remain untouched, and the destination is unchanged on every failure.
	static Status apply(const LocalizationExtractionCatalog &p_source_catalog,
			const LocalizationExtractionProposal &p_proposal,
			LocalizationExtractionCatalog &r_destination_catalog);

	// Apply to a copied editor draft.  Key changes are rejected unless the
	// caller explicitly opts in; source text/metadata changes never touch a
	// ConversationDefinition or its runtime fingerprint.
	static Status apply(const LocalizationDraft &p_source_draft,
			const LocalizationExtractionProposal &p_proposal,
			LocalizationDraft &r_destination_draft,
			bool p_allow_runtime_identity_change = false);
};

using LocalizationExtractor = LocalizationExtractionPlanner;
using LocalizationBoundary = LocalizationExtractionPlanner;

inline Status propose_localization_extraction(const LocalizationDraft &p_draft,
		const LocalizationExtractionCatalog &p_catalog,
		const std::string &p_target_key,
		LocalizationExtractionProposal &r_proposal) {
	return LocalizationExtractionPlanner::propose(p_draft, p_catalog, p_target_key, r_proposal);
}

inline Status propose_localization_extraction(const LocalizationDraft &p_draft,
		const LocalizationExtractionCatalog &p_catalog,
		LocalizationExtractionProposal &r_proposal) {
	return LocalizationExtractionPlanner::propose(p_draft, p_catalog, r_proposal);
}

inline Status apply_localization_extraction(const LocalizationExtractionCatalog &p_source_catalog,
		const LocalizationExtractionProposal &p_proposal,
		LocalizationExtractionCatalog &r_destination_catalog) {
	return LocalizationExtractionPlanner::apply(p_source_catalog, p_proposal, r_destination_catalog);
}

inline Status apply_localization_extraction(const LocalizationDraft &p_source_draft,
		const LocalizationExtractionProposal &p_proposal,
		LocalizationDraft &r_destination_draft,
		bool p_allow_runtime_identity_change = false) {
	return LocalizationExtractionPlanner::apply(p_source_draft, p_proposal, r_destination_draft,
			p_allow_runtime_identity_change);
}

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_LOCALIZATION_H
