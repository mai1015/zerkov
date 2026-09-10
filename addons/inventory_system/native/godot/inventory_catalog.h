#ifndef INVENTORY_SYSTEM_GODOT_CATALOG_H
#define INVENTORY_SYSTEM_GODOT_CATALOG_H

#include "core/inv_catalog.h"

#include "resources/inventory_catalog_resource.h"
#include "resources/inventory_container_definition.h"
#include "resources/inventory_discovery_policy.h"
#include "resources/inventory_item_definition.h"
#include "resources/inventory_profile_definition.h"
#include "resources/inventory_trait_schema.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

// The engine-side sealed-catalog façade (tasks 7.1, 7.2, 7.4; design.md
// "Godot façade and authoring"). Owns one `inv::DefinitionCatalog` and
// exposes it only through validate/register/seal/query methods -- there is
// no accessor that returns a mutable reference to it, and every
// register_*() method VALIDATES and COPIES its input Resource's current
// field values into the native catalog via the core's own
// `validate_and_canonicalize`/`register_*` calls (native/core/inv_catalog.h,
// inv_definitions.h): later mutation of the authoring Resource can never
// reach the sealed catalog afterward (7.2's mutation-isolation guarantee;
// see tests/integration/inventory_probe.gd for the executable proof).
//
// RefCounted (not Node), matching this addon sibling's own precedent for a
// validation/registration-focused helper with no scene-tree lifecycle needs
// (GameplayDefinitionValidator, gameplay_abilities/native/godot/
// gameplay_definition_validator.h) -- a sealed catalog has no per-frame
// behavior and no owner to guard, so it needs neither `_process` nor the
// ObjectID lifetime-guard pattern `InventoryAuthority`/`InventoryReplicaNode`
// use for their post-commit signals.
namespace godot {

class InventoryCatalog : public RefCounted {
	GDCLASS(InventoryCatalog, RefCounted)

public:
	// Mirrors `inv::StatusCode` exactly (native/core/inv_status.h). Every
	// diagnostic Dictionary's "status_code" field carries one of these
	// values. `inv::DiagnosticId` is deliberately NOT mirrored as a bound
	// enum here (matching gameplay_abilities' own GameplayAbilityComponent::
	// StatusCode precedent, which likewise leaves ga::DiagnosticId as a
	// plain, unbound int) -- see native/core/inv_status.h for the full
	// diagnostic-id meaning behind a "diagnostic" field's numeric value.
	enum StatusCode {
		STATUS_OK = 0,
		STATUS_INVALID_ARGUMENT = 1,
		STATUS_NOT_FOUND = 2,
		STATUS_ALREADY_EXISTS = 3,
		STATUS_OUT_OF_BOUNDS = 4,
		STATUS_ARITHMETIC_ERROR = 5,
		STATUS_LIMIT_EXCEEDED = 6,
		STATUS_NOT_SUPPORTED = 7,
		STATUS_INTERNAL_ERROR = 8,
		STATUS_INVALID_IDENTIFIER = 20,
		STATUS_DUPLICATE_DEFINITION = 21,
		STATUS_UNKNOWN_DEFINITION = 22,
		STATUS_INVALID_REFERENCE = 23,
		STATUS_CATALOG_SEALED = 24,
		STATUS_CATALOG_NOT_SEALED = 25,
		STATUS_HASH_COLLISION = 26,
		STATUS_DEPENDENCY_MISSING = 27,
		STATUS_DEPENDENCY_CYCLE = 28,
		STATUS_INCOMPATIBLE_DEFINITION = 29,
		STATUS_MANIFEST_MISMATCH = 40,
		STATUS_PROTOCOL_MISMATCH = 41,
		STATUS_SCHEMA_MISMATCH = 42,
		STATUS_FEATURE_UNSUPPORTED = 43,
		STATUS_ENCODE_FAILED = 44,
		STATUS_DECODE_FAILED = 45,
		STATUS_PAYLOAD_TOO_LARGE = 46,
		STATUS_REVISION_MISMATCH = 60,
		STATUS_DUPLICATE_COMMAND = 61,
		STATUS_PERMISSION_DENIED = 62,
		STATUS_ROLE_VIOLATION = 63,
		STATUS_INVARIANT_VIOLATION = 64,
		STATUS_COMMAND_REJECTED = 65,
		STATUS_SNAPSHOT_REQUIRED = 66,
	};

	InventoryCatalog();
	~InventoryCatalog() override;

	// Registers the five built-in feature modules and five built-in trait
	// schemas (native/core/inv_builtin_features.h) that every profile may
	// reference by identifier without a game authoring them. Safe to call at
	// most once before seal(); a second call or a call after seal() fails
	// closed.
	Dictionary register_builtin_definitions();
	// Opt-in companion for inventory.feature.discovery. It is deliberately
	// separate from register_builtin_definitions() so legacy catalogs retain
	// byte-identical manifests.
	Dictionary register_discovery_definitions();

	// Each VALIDATES p_resource's current field values via the core's own
	// `inv::validate_and_canonicalize()` and, only on success, COPIES the
	// canonicalized value into this catalog (7.2) -- p_resource itself is
	// never retained or mutated. Returns one stable-path diagnostic
	// Dictionary {status_code, diagnostic, detail, identifier, source}.
	Dictionary register_trait_schema(const Ref<InventoryTraitSchema> &p_resource);
	Dictionary register_discovery_policy(const Ref<InventoryDiscoveryPolicy> &p_resource);
	Dictionary register_item(const Ref<InventoryItemDefinition> &p_resource);
	Dictionary register_container(const Ref<InventoryContainerDefinition> &p_resource);
	Dictionary register_profile(const Ref<InventoryProfileDefinition> &p_resource);

	// One-call registration of every array on p_catalog, in dependency-
	// friendly order (trait schemas, then containers, then items, then
	// profiles). Returns one diagnostic Dictionary per attempted
	// registration, in that same order (bounded by the resource's own array
	// sizes); a caller checks `is_ok(result)` for overall success.
	Array register_catalog_resource(const Ref<InventoryCatalogResource> &p_catalog);

	// Registers an opaque, adapter-owned canonical mapping payload (e.g. an
	// equipped-trait-to-GAS-grant table from inventory_gameplay_abilities)
	// under p_identifier. p_canonical_bytes is trusted to already be in
	// canonical form -- this validates only the identifier and the
	// MAX_MANIFEST_ENTRY_BYTES bound (native/core/inv_catalog.h's
	// `register_integration_mapping()`), then participates in the sealed
	// manifest and fingerprint like every other registration. Pre-seal only:
	// a call after seal() fails closed with STATUS_CATALOG_SEALED, matching
	// every other register_*() method above. p_source is a caller-supplied
	// stable-path label for the returned diagnostic Dictionary (7.1's
	// stable-path diagnostics contract); defaults to "<script>" since this
	// call has no backing Resource to derive one from.
	Dictionary register_integration_mapping(const String &p_identifier, const PackedByteArray &p_canonical_bytes, const String &p_source = String("<script>"));

	// Seals the catalog: no further register_*() call succeeds afterward.
	// Building the content manifest fails closed on an unresolved cross-
	// reference, a layout/feature conflict, or an unsealed dependency (see
	// native/core/inv_catalog.cpp for the exact validation passes).
	Dictionary seal();
	bool is_sealed() const { return catalog.sealed(); }

	// 0 before seal() succeeds. A pure function of every authority-affecting
	// definition, module, limit, and integration mapping registered before
	// sealing (contracts.md "fnv1a64-canonical-v1"); unaffected by
	// registration order (native/core/inv_catalog.cpp's own ordering-
	// independence tests).
	int64_t manifest_fingerprint() const;

	// -- Version/compatibility surface (2.3's release-manifest agreement) --
	String api_version() const;
	int api_version_major() const;
	int api_version_minor() const;
	int api_version_patch() const;
	int protocol_version() const;
	int resource_schema_version() const;
	int feature_module_version() const;
	int persistence_schema_version() const;
	String manifest_algorithm() const;
	String mass_unit() const;

	// Runs the SAME validation `register_*()` above performs, over a scratch
	// catalog that is discarded afterward -- p_resource is never registered
	// into `this` and this catalog's own sealed/registered state is
	// unaffected either way (3.9's runtime-side validator, independent of
	// the editor plugin's own call path). Accepts an
	// `InventoryTraitSchema`/`InventoryItemDefinition`/
	// `InventoryContainerDefinition`/`InventoryProfileDefinition`/
	// `InventoryCatalogResource`; any other Resource type, or a null
	// Resource, reports one INVALID_ARGUMENT diagnostic. Returns a bounded
	// Array of the same {status_code, diagnostic, detail, identifier,
	// source} diagnostic Dictionaries register_*() above uses.
	Array validate_resource(const Ref<Resource> &p_resource) const;

	// C++-only accessor (NOT ClassDB-bound -- `inv::DefinitionCatalog` is not
	// Variant-marshalable) for `InventoryAuthority`/`InventoryReplicaNode` in
	// the SAME module to reach the sealed catalog they build runtimes and
	// decode protocol payloads against. Mirrors gameplay_abilities'
	// "C++-only collaborator seams" precedent (gameplay_ability_component.h).
	const inv::DefinitionCatalog &native_catalog() const { return catalog; }

protected:
	static void _bind_methods();

private:
	inv::DefinitionCatalog catalog;
};

} // namespace godot

VARIANT_ENUM_CAST(InventoryCatalog::StatusCode);

#endif // INVENTORY_SYSTEM_GODOT_CATALOG_H
