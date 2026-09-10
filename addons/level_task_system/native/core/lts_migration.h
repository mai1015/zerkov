#ifndef LEVEL_TASK_SYSTEM_CORE_MIGRATION_H
#define LEVEL_TASK_SYSTEM_CORE_MIGRATION_H

#include "core/lts_catalog.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// Rename planning is deliberately kept outside the catalog and definition
// types.  A planner can therefore inspect a sealed catalog without opening a
// mutation path on the catalog itself, and an adapter can show the resulting
// paths before it writes any Resource or save file.

constexpr std::size_t MAX_RENAME_MAPPINGS = 256;
constexpr std::size_t MAX_RENAME_AFFECTED_PATHS = 8192;
constexpr std::size_t MAX_RENAME_SAVED_INSTANCE_ENTRIES = 8192;

enum class RenameIdentifierScope : std::uint8_t {
	GLOBAL = 1,
	LOCAL = 2,
};

// Global IDs are typed at reference sites.  `ANY` is useful for a deliberate
// project-wide rename; callers can select one type when an old spelling is
// intentionally shared by more than one definition family.
enum class RenameGlobalKind : std::uint8_t {
	ANY = 0,
	LEVEL = 1,
	TASK_GRAPH = 2,
	CONVERSATION = 3,
	SPEAKER = 4,
	PROVIDER = 5,
	FACT = 6,
	IDENTIFIER_VALUE = 7,
};

enum class RenameOwnerKind : std::uint8_t {
	NONE = 0,
	LEVEL = 1,
	TASK_GRAPH = 2,
	CONVERSATION = 3,
	SPEAKER = 4,
	PROVIDER = 5,
};

// Local kinds describe semantic identifier families rather than individual
// C++ fields.  For example, a conversation-step rename updates the entry
// label and every step edge that names the step.  `ANY` is accepted only when
// the old spelling occurs in one unambiguous family in the specified owner.
enum class RenameLocalKind : std::uint8_t {
	ANY = 0,
	TASK_NODE = 1,
	TASK_PORT = 2,
	TASK_EDGE = 3,
	TASK_OUTCOME = 4,
	CONVERSATION_STEP = 5,
	CONVERSATION_CHOICE = 6,
	CONVERSATION_OUTCOME = 7,
	LEVEL_ANCHOR = 8,
	LEVEL_EXIT = 9,
	LEVEL_OUTCOME = 10,
	LOCALIZATION_KEY = 11,
	PARAMETER = 12,
};

bool is_known_rename_scope(RenameIdentifierScope p_scope);
bool is_known_rename_global_kind(RenameGlobalKind p_kind);
bool is_known_rename_owner_kind(RenameOwnerKind p_kind);
bool is_known_rename_local_kind(RenameLocalKind p_kind);

// `owner_identifier` is required for LOCAL mappings and names the global
// definition whose local namespace is being changed.  For GLOBAL mappings it
// must remain empty.  Kind selectors are optional and default to ANY.
struct RenameMapping {
	std::string old_identifier;
	std::string new_identifier;
	RenameIdentifierScope scope = RenameIdentifierScope::GLOBAL;
	RenameGlobalKind global_kind = RenameGlobalKind::ANY;
	RenameOwnerKind owner_kind = RenameOwnerKind::NONE;
	std::string owner_identifier;
	RenameLocalKind local_kind = RenameLocalKind::ANY;
	// Ports, choices, and localized parameters have a local namespace below
	// their definition (node or step).  Empty means "infer only when there is
	// exactly one matching nested owner"; it is never a wildcard for an
	// ambiguous mapping.
	std::string nested_owner_identifier;

	RenameMapping() = default;
	RenameMapping(const std::string &p_old_identifier, const std::string &p_new_identifier,
			RenameIdentifierScope p_scope = RenameIdentifierScope::GLOBAL,
			RenameGlobalKind p_global_kind = RenameGlobalKind::ANY,
			RenameOwnerKind p_owner_kind = RenameOwnerKind::NONE,
			const std::string &p_owner_identifier = std::string(),
			RenameLocalKind p_local_kind = RenameLocalKind::ANY,
			const std::string &p_nested_owner_identifier = std::string()) :
			old_identifier(p_old_identifier),
			new_identifier(p_new_identifier), scope(p_scope), global_kind(p_global_kind),
			owner_kind(p_owner_kind), owner_identifier(p_owner_identifier), local_kind(p_local_kind),
			nested_owner_identifier(p_nested_owner_identifier) {}

	RenameMapping(const std::string &p_old_identifier, const std::string &p_new_identifier,
			RenameIdentifierScope p_scope, RenameOwnerKind p_owner_kind,
			const std::string &p_owner_identifier, RenameLocalKind p_local_kind = RenameLocalKind::ANY,
			const std::string &p_nested_owner_identifier = std::string()) :
			old_identifier(p_old_identifier), new_identifier(p_new_identifier), scope(p_scope),
			global_kind(RenameGlobalKind::ANY), owner_kind(p_owner_kind), owner_identifier(p_owner_identifier),
			local_kind(p_local_kind), nested_owner_identifier(p_nested_owner_identifier) {}

	// Scope-first construction is convenient for adapters that expose the
	// scope as the first UI choice.  It also keeps the old/new order explicit in
	// call sites rather than relying on aggregate field order.
	RenameMapping(RenameIdentifierScope p_scope, const std::string &p_old_identifier,
			const std::string &p_new_identifier,
			RenameGlobalKind p_global_kind = RenameGlobalKind::ANY,
			RenameOwnerKind p_owner_kind = RenameOwnerKind::NONE,
			const std::string &p_owner_identifier = std::string(),
			RenameLocalKind p_local_kind = RenameLocalKind::ANY,
			const std::string &p_nested_owner_identifier = std::string()) :
			old_identifier(p_old_identifier), new_identifier(p_new_identifier), scope(p_scope),
			global_kind(p_global_kind), owner_kind(p_owner_kind), owner_identifier(p_owner_identifier), local_kind(p_local_kind),
			nested_owner_identifier(p_nested_owner_identifier) {}

	bool operator==(const RenameMapping &p_other) const;
	bool operator!=(const RenameMapping &p_other) const { return !(*this == p_other); }
};

// A save adapter supplies one entry for each stable identifier field it has
// decoded.  The core does not parse a game-specific save envelope: this
// record is the narrow, engine-independent seam that lets the planner report
// and rewrite those fields without retaining Object, Resource, or pointer
// values.  `path` is the deterministic path inside the save envelope.
struct SavedInstanceReference {
	std::string path;
	std::string identifier;
	RenameIdentifierScope scope = RenameIdentifierScope::GLOBAL;
	RenameGlobalKind global_kind = RenameGlobalKind::ANY;
	RenameOwnerKind owner_kind = RenameOwnerKind::NONE;
	std::string owner_identifier;
	RenameLocalKind local_kind = RenameLocalKind::ANY;
	std::string nested_owner_identifier;
	std::string instance_identifier;
	std::string scope_identifier;

	SavedInstanceReference() = default;
	SavedInstanceReference(const std::string &p_path, const std::string &p_identifier,
			RenameIdentifierScope p_scope = RenameIdentifierScope::GLOBAL,
			RenameGlobalKind p_global_kind = RenameGlobalKind::ANY,
			RenameOwnerKind p_owner_kind = RenameOwnerKind::NONE,
			const std::string &p_owner_identifier = std::string(),
			RenameLocalKind p_local_kind = RenameLocalKind::ANY,
			const std::string &p_instance_identifier = std::string(),
			const std::string &p_scope_identifier = std::string(),
			const std::string &p_nested_owner_identifier = std::string()) :
			path(p_path), identifier(p_identifier), scope(p_scope), global_kind(p_global_kind),
			owner_kind(p_owner_kind), owner_identifier(p_owner_identifier), local_kind(p_local_kind),
			nested_owner_identifier(p_nested_owner_identifier), instance_identifier(p_instance_identifier),
			scope_identifier(p_scope_identifier) {}

	SavedInstanceReference(const std::string &p_path, const std::string &p_identifier,
			RenameIdentifierScope p_scope, RenameOwnerKind p_owner_kind, const std::string &p_owner_identifier,
			RenameLocalKind p_local_kind = RenameLocalKind::ANY,
			const std::string &p_nested_owner_identifier = std::string(),
			const std::string &p_instance_identifier = std::string(),
			const std::string &p_scope_identifier = std::string()) :
			path(p_path), identifier(p_identifier), scope(p_scope), global_kind(RenameGlobalKind::ANY),
			owner_kind(p_owner_kind), owner_identifier(p_owner_identifier), local_kind(p_local_kind),
			nested_owner_identifier(p_nested_owner_identifier), instance_identifier(p_instance_identifier),
			scope_identifier(p_scope_identifier) {}

	bool operator==(const SavedInstanceReference &p_other) const;
	bool operator!=(const SavedInstanceReference &p_other) const { return !(*this == p_other); }
};

// A path is one concrete catalog slot that would change if the mapping is
// accepted.  `definition` distinguishes the declaration of a global ID from
// a cross-resource/local reference; callers can present both using the same
// deterministic path ordering.
struct RenameAffectedPath {
	std::string path;
	std::string old_identifier;
	std::string new_identifier;
	RenameIdentifierScope scope = RenameIdentifierScope::GLOBAL;
	RenameGlobalKind global_kind = RenameGlobalKind::ANY;
	RenameOwnerKind owner_kind = RenameOwnerKind::NONE;
	std::string owner_identifier;
	RenameLocalKind local_kind = RenameLocalKind::ANY;
	std::string nested_owner_identifier;
	bool definition = false;

	bool operator==(const RenameAffectedPath &p_other) const;
	bool operator!=(const RenameAffectedPath &p_other) const { return !(*this == p_other); }
	bool operator<(const RenameAffectedPath &p_other) const;
};

// Saved migration entries are intentionally descriptive, not a save codec.
// `field` is normally "identifier" or "owner_identifier".  An adapter can
// use `path`, old/new, and the instance/scope identity to update its own
// versioned persistence envelope.
struct SavedInstanceMigrationEntry {
	std::string path;
	std::string field;
	std::string old_identifier;
	std::string new_identifier;
	RenameIdentifierScope scope = RenameIdentifierScope::GLOBAL;
	RenameGlobalKind global_kind = RenameGlobalKind::ANY;
	RenameOwnerKind owner_kind = RenameOwnerKind::NONE;
	std::string owner_identifier;
	RenameLocalKind local_kind = RenameLocalKind::ANY;
	std::string nested_owner_identifier;
	std::string instance_identifier;
	std::string scope_identifier;

	bool operator==(const SavedInstanceMigrationEntry &p_other) const;
	bool operator!=(const SavedInstanceMigrationEntry &p_other) const { return !(*this == p_other); }
	bool operator<(const SavedInstanceMigrationEntry &p_other) const;
};

struct RenamePlan {
	Status status;
	CatalogFingerprint source_catalog_fingerprint = INVALID_CATALOG_FINGERPRINT;
	std::vector<RenameMapping> mappings;
	std::vector<RenameAffectedPath> affected_paths;
	std::vector<SavedInstanceMigrationEntry> saved_instance_entries;
	bool preview_only = true;
	bool valid = false;

	bool ok() const { return valid && status.ok(); }
	std::size_t affected_path_count() const { return affected_paths.size(); }
	std::size_t saved_instance_entry_count() const { return saved_instance_entries.size(); }

	// Naming aliases keep adapter code readable without duplicating storage.
	const std::vector<RenameAffectedPath> &affected_references() const { return affected_paths; }
	const std::vector<SavedInstanceMigrationEntry> &saved_instance_migrations() const { return saved_instance_entries; }
};

using RenamePath = RenameAffectedPath;
using SavedInstanceMigration = SavedInstanceMigrationEntry;
using SavedInstanceIdentifierReference = SavedInstanceReference;

class LevelTaskMigrationPlanner {
public:
	// Build a bounded, read-only preview.  The catalog must be sealed: this
	// prevents planning against mutable/unresolved definitions and records the
	// exact fingerprint that an eventual apply must still match.
	static Status preview(const LevelTaskCatalog &p_catalog,
			const std::vector<RenameMapping> &p_mappings,
			const std::vector<SavedInstanceReference> &p_saved_instances,
			RenamePlan &r_plan);

	static Status preview(const LevelTaskCatalog &p_catalog,
			const RenameMapping &p_mapping, RenamePlan &r_plan) {
		return preview(p_catalog, std::vector<RenameMapping>{ p_mapping }, std::vector<SavedInstanceReference>(), r_plan);
	}

	static Status preview(const LevelTaskCatalog &p_catalog,
			const std::vector<RenameMapping> &p_mappings, RenamePlan &r_plan) {
		return preview(p_catalog, p_mappings, std::vector<SavedInstanceReference>(), r_plan);
	}

	// Rebuild a fresh sealed catalog from copied definition data.  The source
	// catalog is never mutated; aliasing source and destination is rejected.
	// The destination is assigned only after every rewrite, validation, and
	// seal succeeds.
	static Status apply(const LevelTaskCatalog &p_source_catalog,
			const RenamePlan &p_plan, LevelTaskCatalog &r_destination_catalog);

	// Apply the same preview to decoded save references.  The output is copied
	// and committed only after every supplied reference is represented by the
	// preview, preventing an unpreviewed identifier from being silently saved.
	static Status apply_saved_instance_migrations(const RenamePlan &p_plan,
			const std::vector<SavedInstanceReference> &p_source,
			std::vector<SavedInstanceReference> &r_destination);

	// Combined helper for hosts that commit catalog and save output together.
	// Neither output is changed if either candidate fails.
	static Status apply(const LevelTaskCatalog &p_source_catalog,
			const RenamePlan &p_plan, LevelTaskCatalog &r_destination_catalog,
			const std::vector<SavedInstanceReference> &p_source_saved_instances,
			std::vector<SavedInstanceReference> &r_destination_saved_instances);
};

using RenameMigrationPlanner = LevelTaskMigrationPlanner;
using LevelTaskRenamePlanner = LevelTaskMigrationPlanner;

inline Status preview_rename(const LevelTaskCatalog &p_catalog,
		const std::vector<RenameMapping> &p_mappings,
		const std::vector<SavedInstanceReference> &p_saved_instances,
		RenamePlan &r_plan) {
	return LevelTaskMigrationPlanner::preview(p_catalog, p_mappings, p_saved_instances, r_plan);
}

inline Status preview_rename(const LevelTaskCatalog &p_catalog,
		const std::vector<RenameMapping> &p_mappings, RenamePlan &r_plan) {
	return LevelTaskMigrationPlanner::preview(p_catalog, p_mappings, r_plan);
}

inline Status apply_rename(const LevelTaskCatalog &p_source_catalog,
		const RenamePlan &p_plan, LevelTaskCatalog &r_destination_catalog) {
	return LevelTaskMigrationPlanner::apply(p_source_catalog, p_plan, r_destination_catalog);
}

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_MIGRATION_H
