#include "core/ga_tag_container.h"

#include <algorithm>

namespace ga {

namespace {
// This container's only snapshot section. Scoped locally: nothing outside
// this file needs to agree on the value, only this file's own writer/reader
// pair (or a future orchestrator that nests this section inside a larger
// component snapshot and simply forwards the same `SnapshotWriter`/`SnapshotReader`).
constexpr std::uint8_t SECTION_TAG_CONTAINER = 1;
} // namespace

TagListenerId TagContainer::add_listener(TagChangeListener p_listener) {
	const TagListenerId id = ++next_listener_id;
	listeners.emplace(id, std::move(p_listener));
	return id;
}

void TagContainer::remove_listener(TagListenerId p_id) {
	listeners.erase(p_id);
}

Status TagContainer::apply_add(DefinitionId p_tag, SourceToken p_source, Transaction &p_txn, std::vector<TagMutationOp> &r_applied) {
	if (registry->definition(p_tag) == nullptr) {
		const Status status = make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::NONE, p_tag);
		p_txn.fail(status);
		return status;
	}

	const auto tag_it = exact_owners.find(p_tag);
	if (tag_it != exact_owners.end() && tag_it->second.count(p_source) > 0) {
		// Already owned by this exact source -- idempotent no-op.
		return ok_status();
	}
	if (total_source_records >= MAX_TAG_SOURCES) {
		const Status status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_tag);
		p_txn.fail(status);
		return status;
	}

	const bool tag_newly_owned = (tag_it == exact_owners.end());
	exact_owners[p_tag].insert(p_source);
	++total_source_records;
	if (tag_newly_owned) {
		adjust_ancestor_index(p_tag, /*p_increment=*/true);
	}

	// Captured by value (not moved) so it can be invoked directly below if
	// `add_undo` itself fails to register it -- see file comment on why
	// `apply_add`/`apply_remove` revert their own provisional mutation in
	// that case, mirroring `AttributeSet::add_modifier`.
	const auto undo = [this, p_tag, p_source, tag_newly_owned]() {
		exact_owners[p_tag].erase(p_source);
		--total_source_records;
		if (tag_newly_owned) {
			exact_owners.erase(p_tag);
			adjust_ancestor_index(p_tag, /*p_increment=*/false);
		}
	};
	const Status undo_status = p_txn.add_undo(undo);
	if (!undo_status.ok()) {
		undo();
		p_txn.fail(undo_status);
		return undo_status;
	}

	r_applied.push_back(TagMutationOp{ TagMutationOp::Kind::ADD, p_tag, p_source });
	return ok_status();
}

Status TagContainer::apply_remove(DefinitionId p_tag, SourceToken p_source, Transaction &p_txn, std::vector<TagMutationOp> &r_applied) {
	if (registry->definition(p_tag) == nullptr) {
		const Status status = make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::NONE, p_tag);
		p_txn.fail(status);
		return status;
	}

	const auto tag_it = exact_owners.find(p_tag);
	if (tag_it == exact_owners.end() || tag_it->second.count(p_source) == 0) {
		// No underflow: nothing is mutated, counts and revision are untouched.
		const Status status = make_status(StatusCode::UNKNOWN_TAG_SOURCE, DiagnosticId::NONE, p_tag);
		p_txn.fail(status);
		return status;
	}

	tag_it->second.erase(p_source);
	--total_source_records;
	const bool tag_fully_removed = tag_it->second.empty();
	if (tag_fully_removed) {
		exact_owners.erase(tag_it);
		adjust_ancestor_index(p_tag, /*p_increment=*/false);
	}

	const auto undo = [this, p_tag, p_source, tag_fully_removed]() {
		exact_owners[p_tag].insert(p_source);
		++total_source_records;
		if (tag_fully_removed) {
			adjust_ancestor_index(p_tag, /*p_increment=*/true);
		}
	};
	const Status undo_status = p_txn.add_undo(undo);
	if (!undo_status.ok()) {
		undo();
		p_txn.fail(undo_status);
		return undo_status;
	}

	r_applied.push_back(TagMutationOp{ TagMutationOp::Kind::REMOVE, p_tag, p_source });
	return ok_status();
}

Status TagContainer::apply_one(const TagMutationOp &p_op, Transaction &p_txn, std::vector<TagMutationOp> &r_applied) {
	switch (p_op.kind) {
		case TagMutationOp::Kind::ADD:
			return apply_add(p_op.tag, p_op.source, p_txn, r_applied);
		case TagMutationOp::Kind::REMOVE:
			return apply_remove(p_op.tag, p_op.source, p_txn, r_applied);
	}
	const Status status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, static_cast<std::uint64_t>(p_op.kind));
	p_txn.fail(status);
	return status;
}

Status TagContainer::apply_ops(const std::vector<TagMutationOp> &p_ops, Transaction &p_txn, std::vector<TagMutationOp> &r_applied) {
	for (const TagMutationOp &op : p_ops) {
		const Status status = apply_one(op, p_txn, r_applied);
		if (!status.ok()) {
			// `apply_one` (via `apply_add`/`apply_remove`) already failed
			// `p_txn` itself; calling `fail()` again here is a harmless
			// no-op (idempotent, see ga_transaction.h) but keeps this loop's
			// own failure handling self-evident without relying on that.
			p_txn.fail(status);
			return status;
		}
	}
	return ok_status();
}

std::vector<TagChangeRecord> TagContainer::build_change_records(const std::vector<TagMutationOp> &p_applied, std::uint64_t p_new_revision) const {
	// Built from the *final* post-batch state, then sorted into canonical
	// (definition id, runtime handle) order -- independent of the order the
	// ops happened to be applied in.
	std::vector<TagChangeRecord> records;
	records.reserve(p_applied.size());
	for (const TagMutationOp &op : p_applied) {
		TagChangeRecord record;
		record.tag = op.tag;
		record.source = op.source;
		record.added = (op.kind == TagMutationOp::Kind::ADD);
		record.owner_count_after = owner_count(op.tag);
		record.revision_after = p_new_revision;
		records.push_back(record);
	}
	std::stable_sort(records.begin(), records.end(), [](const TagChangeRecord &a, const TagChangeRecord &b) {
		if (a.tag != b.tag) {
			return a.tag < b.tag;
		}
		return a.source.value < b.source.value;
	});
	return records;
}

void TagContainer::adjust_ancestor_index(DefinitionId p_tag, bool p_increment) {
	std::vector<DefinitionId> ids;
	ids.push_back(p_tag);
	const std::vector<DefinitionId> ancestors = registry->ancestors_of(p_tag);
	ids.insert(ids.end(), ancestors.begin(), ancestors.end());

	for (DefinitionId id : ids) {
		if (p_increment) {
			++parent_aware_counts[id];
		} else {
			const auto it = parent_aware_counts.find(id);
			if (it == parent_aware_counts.end()) {
				continue; // defensive; balanced add/remove should never hit this
			}
			if (it->second <= 1) {
				parent_aware_counts.erase(it);
			} else {
				--it->second;
			}
		}
	}
}

void TagContainer::dispatch_record(TagChangeRecord p_record) const {
	for (const auto &entry : listeners) {
		if (entry.second) {
			entry.second(p_record);
		}
	}
}

Status TagContainer::apply_mutations(const std::vector<TagMutationOp> &p_ops, Transaction &p_txn, NotificationQueue &p_queue, std::vector<TagChangeRecord> *r_records) {
	// `p_queue` is threaded through only for signature symmetry with every
	// other subsystem's `Transaction&`-participating mutating API
	// (`AttributeSet::add_modifier`, `EffectRuntime::apply`, ...), so a
	// caller composing several subsystems in one transaction never has to
	// remember which ones need a queue reference and which don't. This
	// method itself never touches it: unlike `AttributeSet`'s listener,
	// `TagChangeListener` (see ga_tag_container.h) does not take a
	// `NotificationQueue&`, so there is nothing here to forward it to.
	(void)p_queue;

	if (r_records) {
		r_records->clear();
	}
	if (p_ops.empty()) {
		return ok_status();
	}

	std::vector<TagMutationOp> applied; // ops that produced a real state change
	const Status apply_status = apply_ops(p_ops, p_txn, applied);
	if (!apply_status.ok()) {
		return apply_status;
	}

	if (applied.empty()) {
		// Every op was a redundant no-op ADD; nothing actually changed, so no
		// revision bump and no notifications.
		return ok_status();
	}

	const std::uint64_t prior_revision = revision_counter.value;
	revision_counter.bump();
	const std::uint64_t new_revision = revision_counter.value;
	const Status revision_undo_status = p_txn.add_undo([this, prior_revision]() {
		revision_counter.value = prior_revision;
	});
	if (!revision_undo_status.ok()) {
		// The bump above was never registered for undo -- revert it locally
		// (mirrors `apply_add`/`apply_remove`'s own local-revert-on-failure).
		revision_counter.value = prior_revision;
		p_txn.fail(revision_undo_status);
		return revision_undo_status;
	}

	const std::vector<TagChangeRecord> records = build_change_records(applied, new_revision);
	for (const TagChangeRecord &record : records) {
		const Status notify_status = p_txn.add_notification([this, record]() {
			dispatch_record(record);
		});
		if (!notify_status.ok()) {
			p_txn.fail(notify_status);
			return notify_status;
		}
	}

	if (r_records) {
		*r_records = records;
	}
	return ok_status();
}

Status TagContainer::add_tag(SourceToken p_source, DefinitionId p_tag, Transaction &p_txn, NotificationQueue &p_queue) {
	const std::vector<TagMutationOp> ops{ TagMutationOp{ TagMutationOp::Kind::ADD, p_tag, p_source } };
	return apply_mutations(ops, p_txn, p_queue);
}

Status TagContainer::remove_tag(SourceToken p_source, DefinitionId p_tag, Transaction &p_txn, NotificationQueue &p_queue) {
	const std::vector<TagMutationOp> ops{ TagMutationOp{ TagMutationOp::Kind::REMOVE, p_tag, p_source } };
	return apply_mutations(ops, p_txn, p_queue);
}

// ---------------------------------------------------------------------------
// Standalone convenience overloads (see class file comment) -- each builds
// and commits its own single-use `Transaction` around the SAME `apply_ops`/
// `build_change_records` helpers the `Transaction&` overloads above use.
//
// The revision-counter undo registration below is deliberately UNCHECKED,
// unlike the composed overload above: this preserves this convenience path's
// original (pre-Transaction&-overload) behavior byte-for-byte, including at
// exactly `MAX_TAG_SOURCES` applied in one batch, where the per-op undo
// registrations inside `apply_ops` alone already reach
// `MAX_TRANSACTION_UNDO_OPS` -- see
// `budget_tags_single_transaction_batch_reaches_max_tag_sources`
// (ga_test_budgets.cpp) and task 11.10's history in ga_transaction.h. A
// composed caller that needs this registration checked (as `AttributeSet`
// always does) uses the `Transaction&` overload instead, where it has
// headroom to share the same transaction with other subsystems' undo ops.
// ---------------------------------------------------------------------------

Status TagContainer::apply_mutations(const std::vector<TagMutationOp> &p_ops, Tick p_tick, TransactionId p_transaction_id, NotificationQueue &p_queue, std::vector<TagChangeRecord> *r_records) {
	Transaction txn(p_transaction_id, p_tick);

	if (p_ops.empty()) {
		if (r_records) {
			r_records->clear();
		}
		return txn.commit(p_queue);
	}

	std::vector<TagMutationOp> applied; // ops that produced a real state change
	const Status apply_status = apply_ops(p_ops, txn, applied);
	if (!apply_status.ok()) {
		return txn.commit(p_queue); // already failed; commit() rolls back and surfaces it.
	}

	if (applied.empty()) {
		// Every op was a redundant no-op ADD; nothing actually changed, so no
		// revision bump and no notifications -- but the batch still commits.
		if (r_records) {
			r_records->clear();
		}
		return txn.commit(p_queue);
	}

	const std::uint64_t prior_revision = revision_counter.value;
	revision_counter.bump();
	txn.add_undo([this, prior_revision]() {
		revision_counter.value = prior_revision;
	});
	const std::uint64_t new_revision = revision_counter.value;

	const std::vector<TagChangeRecord> records = build_change_records(applied, new_revision);
	for (const TagChangeRecord &record : records) {
		const Status notify_status = txn.add_notification([this, record]() {
			dispatch_record(record);
		});
		if (!notify_status.ok()) {
			txn.fail(notify_status);
			return txn.commit(p_queue);
		}
	}

	if (r_records) {
		*r_records = records;
	}
	return txn.commit(p_queue);
}

Status TagContainer::add_tag(SourceToken p_source, DefinitionId p_tag, Tick p_tick, TransactionId p_transaction_id, NotificationQueue &p_queue) {
	const std::vector<TagMutationOp> ops{ TagMutationOp{ TagMutationOp::Kind::ADD, p_tag, p_source } };
	return apply_mutations(ops, p_tick, p_transaction_id, p_queue);
}

Status TagContainer::remove_tag(SourceToken p_source, DefinitionId p_tag, Tick p_tick, TransactionId p_transaction_id, NotificationQueue &p_queue) {
	const std::vector<TagMutationOp> ops{ TagMutationOp{ TagMutationOp::Kind::REMOVE, p_tag, p_source } };
	return apply_mutations(ops, p_tick, p_transaction_id, p_queue);
}

bool TagContainer::has_exact(DefinitionId p_tag) const {
	return exact_owners.find(p_tag) != exact_owners.end();
}

bool TagContainer::has_parent_aware(DefinitionId p_tag) const {
	const auto it = parent_aware_counts.find(p_tag);
	return it != parent_aware_counts.end() && it->second > 0;
}

std::uint32_t TagContainer::owner_count(DefinitionId p_tag) const {
	const auto it = exact_owners.find(p_tag);
	return it == exact_owners.end() ? 0 : static_cast<std::uint32_t>(it->second.size());
}

std::vector<DefinitionId> TagContainer::owned_tags() const {
	std::vector<DefinitionId> result;
	result.reserve(exact_owners.size());
	for (const auto &entry : exact_owners) {
		result.push_back(entry.first);
	}
	return result;
}

Status TagContainer::write_snapshot(SnapshotWriter &p_writer) const {
	return write_snapshot_filtered(p_writer, [](DefinitionId) { return true; });
}

Status TagContainer::write_snapshot_filtered(SnapshotWriter &p_writer, const std::function<bool(DefinitionId)> &p_is_public) const {
	if (!p_writer.begin_section(SECTION_TAG_CONTAINER)) {
		return p_writer.status();
	}
	p_writer.write_u64(revision_counter.value);
	std::size_t visible_count = 0;
	for (const auto &tag_entry : exact_owners) {
		if (p_is_public(tag_entry.first)) {
			visible_count += tag_entry.second.size();
		}
	}
	p_writer.write_count(visible_count, MAX_TAG_SOURCES);
	// `exact_owners` is a std::map<DefinitionId, std::set<SourceToken>>, so
	// this double loop already visits every (tag, source) pair in ascending
	// (definition id, runtime handle) order regardless of insertion history.
	for (const auto &tag_entry : exact_owners) {
		if (!p_is_public(tag_entry.first)) {
			continue;
		}
		for (const SourceToken &source : tag_entry.second) {
			p_writer.write_u32(tag_entry.first);
			p_writer.write_u64(source.value);
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

std::map<SourceToken, DefinitionId> TagContainer::all_source_records() const {
	std::map<SourceToken, DefinitionId> result;
	for (const auto &tag_entry : exact_owners) {
		for (const SourceToken &source : tag_entry.second) {
			result.emplace(source, tag_entry.first);
		}
	}
	return result;
}

Status TagContainer::write_tag_source_delta_record(SnapshotWriter &p_writer, DefinitionId p_tag) const {
	if (registry->definition(p_tag) == nullptr) {
		return make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::NONE, p_tag);
	}
	p_writer.write_u32(p_tag);
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status TagContainer::decode_tag_source_delta_record(SnapshotReader &p_reader, DefinitionId &r_tag) const {
	std::uint32_t tag_raw = 0;
	if (!p_reader.read_u32(tag_raw)) {
		return p_reader.status();
	}
	if (registry->definition(tag_raw) == nullptr) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, tag_raw);
	}
	r_tag = tag_raw;
	return ok_status();
}

void TagContainer::install_records(std::map<DefinitionId, std::set<SourceToken>> p_owners, std::uint64_t p_revision) {
	std::size_t new_total = 0;
	for (const auto &entry : p_owners) {
		new_total += entry.second.size();
	}
	exact_owners = std::move(p_owners);
	total_source_records = new_total;
	revision_counter.value = p_revision;
	parent_aware_counts.clear();
	for (const auto &tag_entry : exact_owners) {
		adjust_ancestor_index(tag_entry.first, /*p_increment=*/true);
	}
}

Status TagContainer::restore_snapshot(SnapshotReader &p_reader) {
	std::map<DefinitionId, std::set<SourceToken>> new_owners;
	std::uint64_t new_revision = 0;
	const Status decode_status = decode_snapshot_section(p_reader, new_owners, new_revision);
	if (!decode_status.ok()) {
		return decode_status;
	}
	// Every check passed -- replace this container's live state in one shot.
	// No Transaction/NotificationQueue is involved: restoration reconstructs a
	// previously-observed state wholesale, it never emits change records.
	install_records(std::move(new_owners), new_revision);
	return ok_status();
}

Status TagContainer::decode_snapshot_section(SnapshotReader &p_reader, std::map<DefinitionId, std::set<SourceToken>> &r_owners, std::uint64_t &r_revision) const {
	if (!p_reader.begin_section(SECTION_TAG_CONTAINER)) {
		return p_reader.status();
	}

	std::uint64_t new_revision = 0;
	if (!p_reader.read_u64(new_revision)) {
		return p_reader.status();
	}

	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_TAG_SOURCES, /*p_min_bytes_per_element=*/12)) {
		return p_reader.status();
	}

	std::map<DefinitionId, std::set<SourceToken>> new_owners;
	bool have_prior = false;
	DefinitionId prior_tag = INVALID_DEFINITION_ID;
	SourceToken prior_source{};

	for (std::size_t i = 0; i < count; ++i) {
		std::uint32_t tag_raw = 0;
		std::uint64_t source_raw = 0;
		if (!p_reader.read_u32(tag_raw)) {
			return p_reader.status();
		}
		if (!p_reader.read_u64(source_raw)) {
			return p_reader.status();
		}
		const DefinitionId tag = tag_raw;
		const SourceToken source{ source_raw };

		if (registry->definition(tag) == nullptr) {
			// `SnapshotReader::fail` is private (its own read calls are the
			// only thing allowed to set its internal failure state), so a
			// container-level validation failure is reported directly as its
			// own `Status` instead.
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, tag);
		}

		if (have_prior) {
			const bool ascending = (tag > prior_tag) || (tag == prior_tag && source.value > prior_source.value);
			if (!ascending) {
				// Non-canonical (out-of-order or duplicate) entry -- a
				// well-formed snapshot never encodes one, so reject rather
				// than silently accepting untrusted, possibly-crafted bytes.
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, tag);
			}
		}
		prior_tag = tag;
		prior_source = source;
		have_prior = true;

		new_owners[tag].insert(source);
	}

	if (!p_reader.end_section()) {
		return p_reader.status();
	}

	r_owners = std::move(new_owners);
	r_revision = new_revision;
	return ok_status();
}

} // namespace ga
