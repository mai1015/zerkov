#include "core/lts_localization.h"

#include "core/lts_hash.h"

#include <algorithm>
#include <cstddef>
#include <tuple>
#include <utility>

namespace lts {

namespace {

Status validate_bounded_text(const std::string &p_value, std::size_t p_limit) {
	if (p_value.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_value.size());
	}
	return ok_status();
}

Status invalid_extraction_argument() {
	return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
}

Status stale_extraction_proposal(CatalogFingerprint p_actual_fingerprint) {
	return make_status(StatusCode::CATALOG_FINGERPRINT_MISMATCH, DiagnosticId::CATALOG_FINGERPRINT_DIFFERS,
			p_actual_fingerprint);
}

} // namespace

Status validate_localization_key(const std::string &p_key) {
	// validate_local_identifier() enforces the byte ceiling, segment ceiling,
	// lower-case ASCII grammar, and separator rules.  Keep this wrapper rather
	// than duplicating that parser so definitions, frames, and editor adapters
	// cannot drift to subtly different key semantics.
	const Status status = validate_local_identifier(p_key);
	if (!status.ok()) return status;
	return validate_bounded_text(p_key, MAX_LOCALIZATION_KEY_BYTES);
}

Status validate_optional_localization_key(const std::string &p_key) {
	return p_key.empty() ? ok_status() : validate_localization_key(p_key);
}

Status canonicalize_localization_key(const std::string &p_key, std::string &r_canonical) {
	const Status status = validate_localization_key(p_key);
	if (!status.ok()) return status;
	r_canonical = p_key;
	return ok_status();
}

Status LocalizationDraft::validate() const {
	Status status = validate_optional_localization_key(key);
	if (!status.ok()) return status;
	status = validate_bounded_text(text, MAX_LOCALIZATION_DRAFT_TEXT_BYTES);
	if (!status.ok()) return status;
	status = validate_bounded_text(source_path, MAX_LOCALIZATION_SOURCE_PATH_BYTES);
	if (!status.ok()) return status;
	return validate_bounded_text(context, MAX_LOCALIZATION_CONTEXT_BYTES);
}

Status LocalizationExtractionEntry::validate() const {
	Status status = validate_localization_key(key);
	if (!status.ok()) return status;
	status = validate_bounded_text(text, MAX_LOCALIZATION_DRAFT_TEXT_BYTES);
	if (!status.ok()) return status;
	status = validate_bounded_text(source_path, MAX_LOCALIZATION_SOURCE_PATH_BYTES);
	if (!status.ok()) return status;
	return validate_bounded_text(context, MAX_LOCALIZATION_CONTEXT_BYTES);
}

bool LocalizationExtractionEntry::operator<(const LocalizationExtractionEntry &p_other) const {
	return std::tie(key, text, source_path, context) < std::tie(p_other.key, p_other.text, p_other.source_path, p_other.context);
}

Status LocalizationExtractionCatalog::validate() const {
	LocalizationExtractionCatalog copy = *this;
	return copy.validate_and_canonicalize();
}

Status LocalizationExtractionCatalog::validate_and_canonicalize() {
	LocalizationExtractionCatalog candidate = *this;
	if (candidate.entries.size() > MAX_LOCALIZATION_EXTRACTION_ENTRIES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, candidate.entries.size());
	}
	for (const LocalizationExtractionEntry &entry : candidate.entries) {
		const Status status = entry.validate();
		if (!status.ok()) return status;
	}
	std::sort(candidate.entries.begin(), candidate.entries.end());
	for (std::size_t index = 1; index < candidate.entries.size(); ++index) {
		if (candidate.entries[index - 1].key == candidate.entries[index].key) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, index);
		}
	}
	*this = std::move(candidate);
	return ok_status();
}

CatalogFingerprint LocalizationExtractionCatalog::fingerprint() const {
	LocalizationExtractionCatalog copy = *this;
	if (!copy.validate_and_canonicalize().ok()) return INVALID_CATALOG_FINGERPRINT;
	Hasher hasher;
	hasher.write_string("lts.localization-extraction.v1");
	hasher.write_u32(static_cast<std::uint32_t>(copy.entries.size()));
	for (const LocalizationExtractionEntry &entry : copy.entries) {
		hasher.write_string(entry.key);
		hasher.write_string(entry.text);
		hasher.write_string(entry.source_path);
		hasher.write_string(entry.context);
	}
	return hasher.digest();
}

const LocalizationExtractionEntry *LocalizationExtractionCatalog::find(const std::string &p_key) const {
	for (const LocalizationExtractionEntry &entry : entries) {
		if (entry.key == p_key) return &entry;
	}
	return nullptr;
}

Status LocalizationExtractionProposal::validate() const {
	Status status = validate_optional_localization_key(source_key);
	if (!status.ok()) return status;
	status = validate_localization_key(key);
	if (!status.ok()) return status;
	status = validate_bounded_text(text, MAX_LOCALIZATION_DRAFT_TEXT_BYTES);
	if (!status.ok()) return status;
	status = validate_bounded_text(source_path, MAX_LOCALIZATION_SOURCE_PATH_BYTES);
	if (!status.ok()) return status;
	status = validate_bounded_text(context, MAX_LOCALIZATION_CONTEXT_BYTES);
	if (!status.ok()) return status;
	if (changes_runtime_identity != (source_key != key)) {
		// The identity flag is part of the explicit editor boundary.  Reject a
		// caller that attempts to disguise a key change as a translation-only
		// update instead of silently accepting a different stable line identity.
		return invalid_extraction_argument();
	}
	return ok_status();
}

Status LocalizationExtractionPlanner::propose(const LocalizationDraft &p_draft,
		const LocalizationExtractionCatalog &p_catalog,
		const std::string &p_target_key,
		LocalizationExtractionProposal &r_proposal) {
	const Status draft_status = p_draft.validate();
	if (!draft_status.ok()) return draft_status;
	const Status catalog_status = p_catalog.validate();
	if (!catalog_status.ok()) return catalog_status;
	const Status key_status = validate_localization_key(p_target_key);
	if (!key_status.ok()) return key_status;

	LocalizationExtractionProposal candidate;
	candidate.source_key = p_draft.key;
	candidate.key = p_target_key;
	candidate.text = p_draft.text;
	candidate.source_path = p_draft.source_path;
	candidate.context = p_draft.context;
	candidate.source_catalog_fingerprint = p_catalog.fingerprint();
	candidate.creates_key = p_catalog.find(p_target_key) == nullptr;
	// Empty source keys are drafts that have not acquired a runtime identity;
	// assigning one is still an identity change and must be surfaced to the
	// editor.  A changed non-empty key likewise requires explicit migration.
	candidate.changes_runtime_identity = candidate.source_key != candidate.key;
	const Status proposal_status = candidate.validate();
	if (!proposal_status.ok()) return proposal_status;
	r_proposal = std::move(candidate);
	return ok_status();
}

Status LocalizationExtractionPlanner::apply(const LocalizationExtractionCatalog &p_source_catalog,
		const LocalizationExtractionProposal &p_proposal,
		LocalizationExtractionCatalog &r_destination_catalog) {
	const Status catalog_status = p_source_catalog.validate();
	if (!catalog_status.ok()) return catalog_status;
	const Status proposal_status = p_proposal.validate();
	if (!proposal_status.ok()) return proposal_status;
	const CatalogFingerprint actual_fingerprint = p_source_catalog.fingerprint();
	if (p_proposal.source_catalog_fingerprint != INVALID_CATALOG_FINGERPRINT &&
			p_proposal.source_catalog_fingerprint != actual_fingerprint) {
		return stale_extraction_proposal(actual_fingerprint);
	}

	LocalizationExtractionCatalog candidate = p_source_catalog;
	LocalizationExtractionEntry *existing = nullptr;
	for (LocalizationExtractionEntry &entry : candidate.entries) {
		if (entry.key == p_proposal.key) {
			existing = &entry;
			break;
		}
	}
	if (existing != nullptr) {
		existing->text = p_proposal.text;
		existing->source_path = p_proposal.source_path;
		existing->context = p_proposal.context;
	} else {
		if (candidate.entries.size() >= MAX_LOCALIZATION_EXTRACTION_ENTRIES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
					candidate.entries.size() + 1);
		}
		candidate.entries.push_back({ p_proposal.key, p_proposal.text, p_proposal.source_path, p_proposal.context });
	}
	const Status candidate_status = candidate.validate_and_canonicalize();
	if (!candidate_status.ok()) return candidate_status;
	r_destination_catalog = std::move(candidate);
	return ok_status();
}

Status LocalizationExtractionPlanner::apply(const LocalizationDraft &p_source_draft,
		const LocalizationExtractionProposal &p_proposal,
		LocalizationDraft &r_destination_draft,
		bool p_allow_runtime_identity_change) {
	const Status draft_status = p_source_draft.validate();
	if (!draft_status.ok()) return draft_status;
	const Status proposal_status = p_proposal.validate();
	if (!proposal_status.ok()) return proposal_status;
	if (p_source_draft.key != p_proposal.source_key) return invalid_extraction_argument();
	if (p_proposal.changes_runtime_identity && !p_allow_runtime_identity_change) {
		return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS);
	}

	LocalizationDraft candidate = p_source_draft;
	candidate.key = p_proposal.key;
	candidate.text = p_proposal.text;
	candidate.source_path = p_proposal.source_path;
	candidate.context = p_proposal.context;
	const Status candidate_status = candidate.validate();
	if (!candidate_status.ok()) return candidate_status;
	r_destination_draft = std::move(candidate);
	return ok_status();
}

} // namespace lts
