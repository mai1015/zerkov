#include "protocol/inv_persistence.h"

#include "core/inv_bytes.h"
#include "core/inv_hash.h"
#include "core/inv_limits.h"
#include "core/inv_snapshot.h"
#include "protocol/inv_protocol_codec.h"

#include <utility>

namespace inv::protocol {

Status InMemoryPersistenceAdapter::store(const PersistenceRecord &p_record) {
	records_[p_record.inventory] = p_record;
	return ok_status();
}

Status InMemoryPersistenceAdapter::load(InventoryId p_inventory, PersistenceRecord &r_record) {
	const auto found = records_.find(p_inventory);
	if (found == records_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_inventory.value);
	}
	r_record = found->second;
	return ok_status();
}

Status make_persistence_record(const DefinitionCatalog &p_catalog, const InventoryRuntime &p_runtime, PersistenceRecord &r_record) {
	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}

	InventorySnapshot snapshot;
	Status status = inv::snapshot(p_runtime, VisibilityScope::OWNER, snapshot);
	if (!status.ok()) {
		return status;
	}

	ByteWriter writer(MAX_SNAPSHOT_BYTES);
	status = encode_canonical(snapshot, writer);
	if (!status.ok()) {
		return status;
	}

	PersistenceRecord record;
	record.persistence_schema_version = PERSISTENCE_SCHEMA_VERSION;
	record.api_version_major = static_cast<std::uint8_t>(API_VERSION_MAJOR);
	record.api_version_minor = static_cast<std::uint8_t>(API_VERSION_MINOR);
	record.api_version_patch = static_cast<std::uint8_t>(API_VERSION_PATCH);
	record.protocol_version = PROTOCOL_VERSION;
	record.manifest_algorithm = MANIFEST_ALGORITHM;
	record.manifest_fingerprint = snapshot.manifest_fingerprint;
	record.profile_identifier = p_runtime.profile_identifier();
	record.inventory = p_runtime.id();
	record.revision = p_runtime.revision();
	record.canonical_snapshot_bytes = writer.bytes();
	record.record_hash = compute_persistence_record_hash(record);

	r_record = std::move(record);
	return ok_status();
}

Status load_inventory(const DefinitionCatalog &p_catalog, const PersistenceRecord &p_record, IdentityAuthority *p_authority, InventoryRuntime &r_runtime) {
	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	// Unknown/future schema rejects BEFORE anything else -- including before
	// the manifest/hash checks below, which a differently-shaped future
	// record might not even satisfy the same way (inventory-protocol spec:
	// "Unsupported versions ... return stable incompatibility diagnostics
	// before partially applying state").
	if (p_record.persistence_schema_version != PERSISTENCE_SCHEMA_VERSION) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::PERSISTENCE_SCHEMA_VERSION_UNSUPPORTED, p_record.persistence_schema_version);
	}
	if (p_record.manifest_algorithm != MANIFEST_ALGORITHM) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::SESSION_MANIFEST_ALGORITHM_MISMATCH, hash_string(p_record.manifest_algorithm));
	}
	const ContentManifest *manifest = p_catalog.manifest();
	if (manifest == nullptr || manifest->fingerprint != p_record.manifest_fingerprint) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_record.manifest_fingerprint);
	}
	const std::uint64_t expected_hash = compute_persistence_record_hash(p_record);
	if (expected_hash != p_record.record_hash) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::PERSISTENCE_RECORD_HASH_MISMATCH, p_record.record_hash);
	}

	ByteReader reader(p_record.canonical_snapshot_bytes);
	InventorySnapshot snapshot;
	Status status = decode_canonical(reader, snapshot);
	if (!status.ok()) {
		return status;
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRAILING_PAYLOAD_BYTES, reader.remaining());
	}
	if (snapshot.profile_identifier != p_record.profile_identifier ||
			snapshot.inventory_id != p_record.inventory.value ||
			snapshot.revision != p_record.revision) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::PERSISTENCE_RECORD_IDENTITY_MISMATCH, p_record.inventory.value);
	}

	// restore() is itself the atomic all-or-nothing installer: on any
	// failure r_runtime is left completely untouched (core/inv_snapshot.cpp).
	return restore(p_catalog, snapshot, r_runtime, p_authority);
}

Status MigrationChain::register_migration(std::uint16_t p_from_version, MigrationFn p_fn) {
	if (p_fn == nullptr) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_from_version);
	}
	if (migrations_.find(p_from_version) != migrations_.end()) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::DEFINITION_DUPLICATE, p_from_version);
	}
	migrations_.emplace(p_from_version, p_fn);
	return ok_status();
}

Status MigrationChain::migrate_record(PersistenceRecord &r_record, std::uint16_t p_target) const {
	if (r_record.persistence_schema_version == p_target) {
		return ok_status();
	}
	if (r_record.persistence_schema_version > p_target) {
		// No downgrade path is ever registered (migrations_ only maps
		// forward, N -> N+1), so this can never be reachable by walking the
		// chain; reject explicitly rather than looping.
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::PERSISTENCE_MIGRATION_GAP, r_record.persistence_schema_version);
	}

	// Run the whole chain on a WORKING COPY first; r_record is only
	// overwritten once every step to p_target has actually succeeded (see
	// this method's header doc comment: "leaves r_record completely
	// untouched" on any failure, including a gap discovered mid-chain).
	PersistenceRecord candidate = r_record;
	while (candidate.persistence_schema_version != p_target) {
		const auto step = migrations_.find(candidate.persistence_schema_version);
		if (step == migrations_.end()) {
			return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::PERSISTENCE_MIGRATION_GAP, candidate.persistence_schema_version);
		}
		const std::uint16_t before_version = candidate.persistence_schema_version;
		Status status = step->second(candidate);
		if (!status.ok()) {
			return status;
		}
		if (candidate.persistence_schema_version <= before_version) {
			// A conforming MigrationFn always advances the version by
			// exactly one (see MigrationFn's doc comment); a step that
			// reports success without doing so would loop forever below.
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::PERSISTENCE_MIGRATION_GAP, candidate.persistence_schema_version);
		}
	}

	r_record = std::move(candidate);
	return ok_status();
}

} // namespace inv::protocol
