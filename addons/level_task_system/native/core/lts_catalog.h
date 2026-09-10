#ifndef LEVEL_TASK_SYSTEM_CORE_CATALOG_H
#define LEVEL_TASK_SYSTEM_CORE_CATALOG_H

#include "core/lts_definitions.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// Diagnostics are intentionally small and presentation-neutral.  `path` is
// a stable authored-resource path (for example
// `level.level.harbor.entry_graph.quest.harbor.intro`) and `related_path`
// identifies the other side of a duplicate/reference conflict when one is
// useful.  The paths are capped by MAX_DIAGNOSTIC_PATH_BYTES before they are
// retained by the catalog.
struct CatalogDiagnostic {
	Status status;
	std::string path;
	std::string related_path;

	bool operator==(const CatalogDiagnostic &p_other) const {
		return status == p_other.status && path == p_other.path && related_path == p_other.related_path;
	}
	bool operator!=(const CatalogDiagnostic &p_other) const { return !(*this == p_other); }
	bool operator<(const CatalogDiagnostic &p_other) const {
		if (path != p_other.path) return path < p_other.path;
		if (related_path != p_other.related_path) return related_path < p_other.related_path;
		if (status.code != p_other.status.code) {
			return static_cast<std::uint16_t>(status.code) < static_cast<std::uint16_t>(p_other.status.code);
		}
		if (status.diagnostic != p_other.status.diagnostic) {
			return static_cast<std::uint16_t>(status.diagnostic) < static_cast<std::uint16_t>(p_other.status.diagnostic);
		}
		return status.detail < p_other.status.detail;
	}
};

// Catalog validation never retains an unbounded list.  The total count lets
// callers distinguish a complete report from a bounded prefix.
constexpr std::size_t MAX_CATALOG_DIAGNOSTICS = 64;

struct CatalogValidationReport {
	Status status;
	std::vector<CatalogDiagnostic> findings;
	std::uint32_t total_finding_count = 0;
	bool truncated = false;

	bool ok() const { return status.ok() && total_finding_count == 0; }
};

// An explicit project catalog for all immutable Level Task System
// definitions.  Definitions are copied on registration, canonicalized before
// sealing, and exposed only through const accessors after a successful seal.
// Cross-resource identifiers are resolved by kind; identical text in two
// different kinds is therefore not an ambiguous lookup, while a reference to
// the wrong kind fails validation.
class LevelTaskCatalog {
public:
	LevelTaskCatalog() = default;
	LevelTaskCatalog(const LevelTaskCatalog &) = default;
	LevelTaskCatalog(LevelTaskCatalog &&) noexcept = default;
	LevelTaskCatalog &operator=(const LevelTaskCatalog &) = default;
	LevelTaskCatalog &operator=(LevelTaskCatalog &&) noexcept = default;

	// Registration validates each definition's local fields and makes a copy.
	// Cross-resource references are checked by seal().  The optional source
	// path is diagnostics-only and never participates in canonical bytes.
	Status add_level(const LevelDefinition &p_definition, const std::string &p_source_path = std::string());
	Status add_task_graph(const TaskGraphDefinition &p_definition, const std::string &p_source_path = std::string());
	Status add_conversation(const ConversationDefinition &p_definition, const std::string &p_source_path = std::string());
	Status add_speaker(const SpeakerDefinition &p_definition, const std::string &p_source_path = std::string());
	Status add_provider(const ProviderDeclaration &p_definition, const std::string &p_source_path = std::string());

	// Registration aliases are provided for adapters that use registry
	// terminology.  They have exactly the same copy, validation, and sealing
	// semantics as add_*().
	Status register_level(const LevelDefinition &p_definition, const std::string &p_source_path = std::string()) {
		return add_level(p_definition, p_source_path);
	}
	Status register_task_graph(const TaskGraphDefinition &p_definition, const std::string &p_source_path = std::string()) {
		return add_task_graph(p_definition, p_source_path);
	}
	Status register_conversation(const ConversationDefinition &p_definition, const std::string &p_source_path = std::string()) {
		return add_conversation(p_definition, p_source_path);
	}
	Status register_speaker(const SpeakerDefinition &p_definition, const std::string &p_source_path = std::string()) {
		return add_speaker(p_definition, p_source_path);
	}
	Status register_provider(const ProviderDeclaration &p_definition, const std::string &p_source_path = std::string()) {
		return add_provider(p_definition, p_source_path);
	}

	// Sealing is one-way.  It validates/canonicalizes a private copy first, so
	// a failed seal never leaves partially canonicalized definitions in the
	// caller's catalog.  A successful seal fixes the fingerprint and makes all
	// subsequent registration attempts fail closed.
	Status seal();
	bool sealed() const { return is_sealed; }
	bool is_sealed_catalog() const { return is_sealed; }

	// Validation is available before sealing for editor/headless diagnostics.
	// The no-output overload returns the first deterministic status.  The report
	// overload returns the same status and a bounded, path-addressable finding
	// list.  Neither overload mutates this catalog.
	Status validate() const;
	Status validate(CatalogValidationReport &r_report) const;
	const std::vector<CatalogDiagnostic> &diagnostics() const { return last_diagnostics; }
	std::uint32_t diagnostic_count() const { return last_diagnostic_count; }
	bool diagnostics_truncated() const { return last_diagnostics_truncated; }

	// Resolution is deliberately available only after sealing.  Pointer
	// find_* helpers fail closed (nullptr) for an unsealed or missing entry;
	// resolve_* helpers additionally return a useful StatusCode for adapters.
	const LevelDefinition *find_level(const std::string &p_identifier) const;
	const TaskGraphDefinition *find_task_graph(const std::string &p_identifier) const;
	const ConversationDefinition *find_conversation(const std::string &p_identifier) const;
	const SpeakerDefinition *find_speaker(const std::string &p_identifier) const;
	const ProviderDeclaration *find_provider(const std::string &p_identifier) const;

	Status resolve_level(const std::string &p_identifier, const LevelDefinition *&r_definition) const;
	Status resolve_task_graph(const std::string &p_identifier, const TaskGraphDefinition *&r_definition) const;
	Status resolve_conversation(const std::string &p_identifier, const ConversationDefinition *&r_definition) const;
	Status resolve_speaker(const std::string &p_identifier, const SpeakerDefinition *&r_definition) const;
	Status resolve_provider(const std::string &p_identifier, const ProviderDeclaration *&r_definition) const;

	// Pointer-only convenience overloads mirror find_* while retaining the
	// resolve_* name used by adapters that do not need a status payload.
	const LevelDefinition *resolve_level(const std::string &p_identifier) const { return find_level(p_identifier); }
	const TaskGraphDefinition *resolve_task_graph(const std::string &p_identifier) const { return find_task_graph(p_identifier); }
	const ConversationDefinition *resolve_conversation(const std::string &p_identifier) const { return find_conversation(p_identifier); }
	const SpeakerDefinition *resolve_speaker(const std::string &p_identifier) const { return find_speaker(p_identifier); }
	const ProviderDeclaration *resolve_provider(const std::string &p_identifier) const { return find_provider(p_identifier); }

	// Canonical definitions are only readable after sealing.  Returning const
	// vectors prevents accidental mutation of the content that was fingerprinted.
	const std::vector<LevelDefinition> &levels() const { return level_definitions; }
	const std::vector<TaskGraphDefinition> &task_graphs() const { return task_graph_definitions; }
	const std::vector<ConversationDefinition> &conversations() const { return conversation_definitions; }
	const std::vector<SpeakerDefinition> &speakers() const { return speaker_definitions; }
	const std::vector<ProviderDeclaration> &providers() const { return provider_definitions; }

	std::size_t level_count() const { return level_definitions.size(); }
	std::size_t task_graph_count() const { return task_graph_definitions.size(); }
	std::size_t conversation_count() const { return conversation_definitions.size(); }
	std::size_t speaker_count() const { return speaker_definitions.size(); }
	std::size_t provider_count() const { return provider_definitions.size(); }

	// 0 means unsealed or invalid.  Once sealed, this is the digest of the
	// complete canonical catalog envelope, including schema versions, all
	// runtime-affecting V1 limits, provider declarations, and every definition.
	CatalogFingerprint fingerprint() const { return catalog_fingerprint; }
	CatalogFingerprint content_fingerprint() const { return catalog_fingerprint; }
	CatalogFingerprint catalog_fingerprint_value() const { return catalog_fingerprint; }

	// Returns the exact canonical byte stream used by fingerprint().  This is a
	// fail-closed operation before sealing and is useful for golden fixtures,
	// compatibility handshakes, and deterministic replay tooling.
	Status encode_canonical(std::vector<std::uint8_t> &r_bytes) const;

private:
	Status validate_and_canonicalize_in_place(CatalogValidationReport &r_report);
	void clear_last_diagnostics();
	void remember_status(const Status &p_status, const std::string &p_path);

	std::vector<LevelDefinition> level_definitions;
	std::vector<TaskGraphDefinition> task_graph_definitions;
	std::vector<ConversationDefinition> conversation_definitions;
	std::vector<SpeakerDefinition> speaker_definitions;
	std::vector<ProviderDeclaration> provider_definitions;

	// Source paths are diagnostics-only and stay parallel to the definition
	// vectors. They are intentionally excluded from canonical bytes/fingerprints.
	std::vector<std::string> level_source_paths;
	std::vector<std::string> task_graph_source_paths;
	std::vector<std::string> conversation_source_paths;
	std::vector<std::string> speaker_source_paths;
	std::vector<std::string> provider_source_paths;

	std::vector<CatalogDiagnostic> last_diagnostics;
	std::uint32_t last_diagnostic_count = 0;
	bool last_diagnostics_truncated = false;
	CatalogFingerprint catalog_fingerprint = INVALID_CATALOG_FINGERPRINT;
	bool is_sealed = false;
};

// The level/task catalog is the sole V1 catalog type.  This alias keeps the
// shorter name available to integrations without introducing a second type.
using LevelCatalog = LevelTaskCatalog;

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_CATALOG_H
