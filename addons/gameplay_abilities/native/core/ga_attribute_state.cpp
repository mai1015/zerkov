#include "core/ga_attribute_state.h"

#include "core/ga_fixed.h"

#include <algorithm>
#include <utility>

namespace ga {

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

bool AttributeSet::has_attribute(DefinitionId p_id) const {
	return attributes.find(p_id) != attributes.end();
}

Status AttributeSet::get_base(DefinitionId p_id, Fixed &r_value) const {
	auto it = attributes.find(p_id);
	if (it == attributes.end()) {
		return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
	}
	r_value = it->second.base;
	return ok_status();
}

Status AttributeSet::get_current(DefinitionId p_id, Fixed &r_value) const {
	auto it = attributes.find(p_id);
	if (it == attributes.end()) {
		return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
	}
	r_value = it->second.current;
	return ok_status();
}

Status AttributeSet::get_value(DefinitionId p_id, AttributeValue &r_value) const {
	auto it = attributes.find(p_id);
	if (it == attributes.end()) {
		return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
	}
	r_value = it->second;
	return ok_status();
}

std::vector<DefinitionId> AttributeSet::initialized_attributes() const {
	std::vector<DefinitionId> result;
	result.reserve(attributes.size());
	for (const auto &entry : attributes) {
		result.push_back(entry.first);
	}
	return result;
}

bool AttributeSet::has_modifier(ModifierHandle p_handle) const {
	return modifiers.find(p_handle) != modifiers.end();
}

Status AttributeSet::get_modifier(ModifierHandle p_handle, AttributeModifier &r_value) const {
	auto it = modifiers.find(p_handle);
	if (it == modifiers.end()) {
		return make_status(StatusCode::UNKNOWN_MODIFIER, DiagnosticId::NONE, p_handle.value);
	}
	r_value = it->second;
	return ok_status();
}

// ---------------------------------------------------------------------------
// Aggregation core
// ---------------------------------------------------------------------------

void AttributeSet::index_insert(DefinitionId p_target, ModifierHandle p_handle) {
	std::vector<ModifierHandle> &bucket = modifiers_by_attribute[p_target];
	// Sorted insert (not push_back) so this stays correct even when a
	// rollback re-inserts a handle smaller than one already present (e.g. a
	// later add within the same transaction that survives the rollback) --
	// see the header comment on why ascending-handle order must be exact,
	// not just "eventually consistent."
	const auto pos = std::lower_bound(bucket.begin(), bucket.end(), p_handle);
	bucket.insert(pos, p_handle);
}

void AttributeSet::index_erase(DefinitionId p_target, ModifierHandle p_handle) {
	auto it = modifiers_by_attribute.find(p_target);
	if (it == modifiers_by_attribute.end()) {
		return;
	}
	std::vector<ModifierHandle> &bucket = it->second;
	const auto pos = std::lower_bound(bucket.begin(), bucket.end(), p_handle);
	if (pos != bucket.end() && *pos == p_handle) {
		bucket.erase(pos);
	}
}

void AttributeSet::rebuild_modifier_index() {
	modifiers_by_attribute.clear();
	// `modifiers` is a std::map<ModifierHandle, AttributeModifier>, so this
	// iterates in ascending handle order already; appending preserves that
	// order per target bucket without needing the sorted-insert used
	// elsewhere.
	for (const auto &entry : modifiers) {
		modifiers_by_attribute[entry.second.target_attribute].push_back(entry.first);
	}
}

std::vector<const AttributeModifier *> AttributeSet::ordered_modifiers_for(DefinitionId p_id, ModifierOp p_op) const {
	std::vector<const AttributeModifier *> result;
	const auto index_it = modifiers_by_attribute.find(p_id);
	if (index_it != modifiers_by_attribute.end()) {
		result.reserve(index_it->second.size());
		for (ModifierHandle handle : index_it->second) {
			++modifier_scan_visits;
			const auto mod_it = modifiers.find(handle);
			if (mod_it == modifiers.end()) {
				continue; // unreachable if the index stays in sync with `modifiers`
			}
			const AttributeModifier &modifier = mod_it->second;
			if (modifier.op == p_op) {
				result.push_back(&modifier);
			}
		}
	}

	// Ascending priority, source, effect, declaration index -- the spec's
	// documented tie-breakers (see file comment). Ties across all four are
	// only possible for content the caller itself failed to disambiguate
	// (e.g. two modifiers sharing effect/declaration_index); this addon's
	// contract assumes real content never does that, so a stable sort over
	// whatever order the map happened to enumerate them in is sufficient in
	// practice while remaining well-defined (no UB) even if it did.
	std::stable_sort(result.begin(), result.end(), [](const AttributeModifier *a, const AttributeModifier *b) {
		if (a->priority != b->priority) {
			return a->priority < b->priority;
		}
		if (a->source.value != b->source.value) {
			return a->source.value < b->source.value;
		}
		if (a->effect.value != b->effect.value) {
			return a->effect.value < b->effect.value;
		}
		return a->declaration_index < b->declaration_index;
	});
	return result;
}

std::vector<ModifierHandle> AttributeSet::canonical_modifier_order() const {
	std::vector<ModifierHandle> handles;
	handles.reserve(modifiers.size());
	for (const auto &entry : modifiers) {
		handles.push_back(entry.first);
	}

	std::stable_sort(handles.begin(), handles.end(), [this](ModifierHandle p_a, ModifierHandle p_b) {
		const AttributeModifier &a = modifiers.at(p_a);
		const AttributeModifier &b = modifiers.at(p_b);
		if (a.target_attribute != b.target_attribute) {
			return a.target_attribute < b.target_attribute;
		}
		if (a.op != b.op) {
			return static_cast<std::uint8_t>(a.op) < static_cast<std::uint8_t>(b.op);
		}
		if (a.priority != b.priority) {
			return a.priority < b.priority;
		}
		if (a.source.value != b.source.value) {
			return a.source.value < b.source.value;
		}
		if (a.effect.value != b.effect.value) {
			return a.effect.value < b.effect.value;
		}
		return a.declaration_index < b.declaration_index;
	});
	return handles;
}

Status AttributeSet::recompute_value(DefinitionId p_id, Fixed p_base, Fixed &r_requested, Fixed &r_effective) const {
	const AttributeDefinition *def = registry->find(p_id);
	if (def == nullptr) {
		return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
	}

	Fixed value = p_base;

	// Phase 1: ADD, running sum.
	for (const AttributeModifier *modifier : ordered_modifiers_for(p_id, ModifierOp::ADD)) {
		Fixed next;
		const Status status = fixed_add(value, modifier->magnitude, next);
		if (!status.ok()) {
			return status;
		}
		value = next;
	}

	// Phase 2: MULTIPLY, running product.
	for (const AttributeModifier *modifier : ordered_modifiers_for(p_id, ModifierOp::MULTIPLY)) {
		Fixed next;
		const Status status = fixed_mul(value, modifier->magnitude, next);
		if (!status.ok()) {
			return status;
		}
		value = next;
	}

	// Phase 3: OVERRIDE -- the modifier that sorts first (see file comment)
	// replaces the running value outright, if any are active.
	const std::vector<const AttributeModifier *> overrides = ordered_modifiers_for(p_id, ModifierOp::OVERRIDE);
	if (!overrides.empty()) {
		value = overrides.front()->magnitude;
	}

	r_requested = value;

	// Phase 4: CLAMP -- the only place bounds are applied.
	Fixed effective = value;
	if (def->has_min) {
		effective = fixed_max(effective, def->min_value);
	}
	if (def->has_max) {
		effective = fixed_min(effective, def->max_value);
	}
	r_effective = effective;
	return ok_status();
}

void AttributeSet::dispatch(const AttributeChangeRecord &p_record, NotificationQueue &p_queue) const {
	for (const auto &listener : listeners) {
		listener(p_record, p_queue);
	}
}

void AttributeSet::add_listener(std::function<void(const AttributeChangeRecord &, NotificationQueue &)> p_listener) {
	listeners.push_back(std::move(p_listener));
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

Status AttributeSet::initialize_attribute(DefinitionId p_id, bool p_has_override, Fixed p_override_base,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	const AttributeDefinition *def = registry->find(p_id);
	if (def == nullptr) {
		const Status status = make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
		p_txn.fail(status);
		return status;
	}
	if (attributes.find(p_id) != attributes.end()) {
		const Status status = make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::NONE, p_id);
		p_txn.fail(status);
		return status;
	}
	if (attributes.size() >= MAX_ATTRIBUTES) {
		const Status status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, MAX_ATTRIBUTES);
		p_txn.fail(status);
		return status;
	}

	const Fixed base = p_has_override ? p_override_base : def->default_base;
	Fixed requested = Fixed::zero();
	Fixed effective = Fixed::zero();
	const Status recompute_status = recompute_value(p_id, base, requested, effective);
	if (!recompute_status.ok()) {
		p_txn.fail(recompute_status);
		return recompute_status;
	}

	AttributeChangeRecord record;
	record.attribute = p_id;
	record.old_base = Fixed::zero();
	record.new_base = base;
	record.old_current = Fixed::zero();
	record.new_current = effective;
	record.requested_current = requested;
	record.revision = 0;
	record.transaction = p_txn.id();
	record.provenance = p_provenance;

	const Status undo_status = p_txn.add_undo([this, p_id]() {
		attributes.erase(p_id);
	});
	if (!undo_status.ok()) {
		p_txn.fail(undo_status);
		return undo_status;
	}

	const Status notify_status = p_txn.add_notification([this, record, &p_queue]() {
		dispatch(record, p_queue);
	});
	if (!notify_status.ok()) {
		p_txn.fail(notify_status);
		return notify_status;
	}

	AttributeValue value;
	value.base = base;
	value.current = effective;
	attributes.emplace(p_id, value);
	return ok_status();
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

Status AttributeSet::set_base(DefinitionId p_id, Fixed p_new_base,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	auto it = attributes.find(p_id);
	if (it == attributes.end()) {
		const Status status = make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
		p_txn.fail(status);
		return status;
	}

	Fixed requested = Fixed::zero();
	Fixed effective = Fixed::zero();
	const Status recompute_status = recompute_value(p_id, p_new_base, requested, effective);
	if (!recompute_status.ok()) {
		p_txn.fail(recompute_status);
		return recompute_status;
	}

	AttributeValue &value = it->second;
	const Fixed old_base = value.base;
	const Fixed old_current = value.current;
	const std::uint64_t old_revision = value.revision.value;
	const std::uint64_t new_revision = old_revision + 1;

	AttributeChangeRecord record;
	record.attribute = p_id;
	record.old_base = old_base;
	record.new_base = p_new_base;
	record.old_current = old_current;
	record.new_current = effective;
	record.requested_current = requested;
	record.revision = new_revision;
	record.transaction = p_txn.id();
	record.provenance = p_provenance;

	const Status undo_status = p_txn.add_undo([this, p_id, old_base, old_current, old_revision]() {
		auto restore_it = attributes.find(p_id);
		if (restore_it != attributes.end()) {
			restore_it->second.base = old_base;
			restore_it->second.current = old_current;
			restore_it->second.revision.value = old_revision;
		}
	});
	if (!undo_status.ok()) {
		p_txn.fail(undo_status);
		return undo_status;
	}

	const Status notify_status = p_txn.add_notification([this, record, &p_queue]() {
		dispatch(record, p_queue);
	});
	if (!notify_status.ok()) {
		p_txn.fail(notify_status);
		return notify_status;
	}

	value.base = p_new_base;
	value.current = effective;
	value.revision.value = new_revision;
	return ok_status();
}

Status AttributeSet::add_modifier(const AttributeModifier &p_modifier, ModifierHandle &r_handle,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	r_handle = INVALID_MODIFIER_HANDLE;

	if (p_modifier.op != ModifierOp::ADD && p_modifier.op != ModifierOp::MULTIPLY && p_modifier.op != ModifierOp::OVERRIDE) {
		const Status status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM);
		p_txn.fail(status);
		return status;
	}

	auto it = attributes.find(p_modifier.target_attribute);
	if (it == attributes.end()) {
		const Status status = make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_modifier.target_attribute);
		p_txn.fail(status);
		return status;
	}

	if (modifiers.size() >= MAX_MODIFIERS) {
		const Status status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, MAX_MODIFIERS);
		p_txn.fail(status);
		return status;
	}

	const ModifierHandle handle = handle_allocator.allocate();
	modifiers.emplace(handle, p_modifier);
	const DefinitionId target = p_modifier.target_attribute;
	index_insert(target, handle);

	const Fixed base = it->second.base;
	Fixed requested = Fixed::zero();
	Fixed effective = Fixed::zero();
	const Status recompute_status = recompute_value(target, base, requested, effective);
	if (!recompute_status.ok()) {
		// Nothing has been registered with the transaction yet, so undoing
		// this modifier's provisional insertion locally is sufficient.
		index_erase(target, handle);
		modifiers.erase(handle);
		p_txn.fail(recompute_status);
		return recompute_status;
	}

	AttributeValue &value = it->second;
	const Fixed old_current = value.current;
	const std::uint64_t old_revision = value.revision.value;
	const std::uint64_t new_revision = old_revision + 1;

	AttributeChangeRecord record;
	record.attribute = target;
	record.old_base = base;
	record.new_base = base;
	record.old_current = old_current;
	record.new_current = effective;
	record.requested_current = requested;
	record.revision = new_revision;
	record.transaction = p_txn.id();
	record.provenance = p_provenance;

	const Status undo_status = p_txn.add_undo([this, handle, target, old_current, old_revision]() {
		index_erase(target, handle);
		modifiers.erase(handle);
		auto restore_it = attributes.find(target);
		if (restore_it != attributes.end()) {
			restore_it->second.current = old_current;
			restore_it->second.revision.value = old_revision;
		}
	});
	if (!undo_status.ok()) {
		index_erase(target, handle);
		modifiers.erase(handle);
		p_txn.fail(undo_status);
		return undo_status;
	}

	const Status notify_status = p_txn.add_notification([this, record, &p_queue]() {
		dispatch(record, p_queue);
	});
	if (!notify_status.ok()) {
		p_txn.fail(notify_status);
		return notify_status;
	}

	value.current = effective;
	value.revision.value = new_revision;
	r_handle = handle;
	return ok_status();
}

Status AttributeSet::remove_modifier(ModifierHandle p_handle,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	auto mod_it = modifiers.find(p_handle);
	if (mod_it == modifiers.end()) {
		const Status status = make_status(StatusCode::UNKNOWN_MODIFIER, DiagnosticId::NONE, p_handle.value);
		p_txn.fail(status);
		return status;
	}

	const AttributeModifier removed_copy = mod_it->second;
	const DefinitionId target = removed_copy.target_attribute;
	auto attr_it = attributes.find(target);
	if (attr_it == attributes.end()) {
		// A modifier can only exist targeting an attribute that was
		// initialized at add_modifier time, and attributes are never
		// un-initialized -- this should be unreachable.
		const Status status = make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, target);
		p_txn.fail(status);
		return status;
	}

	modifiers.erase(mod_it);
	index_erase(target, p_handle);

	const Fixed base = attr_it->second.base;
	Fixed requested = Fixed::zero();
	Fixed effective = Fixed::zero();
	const Status recompute_status = recompute_value(target, base, requested, effective);
	if (!recompute_status.ok()) {
		modifiers.emplace(p_handle, removed_copy);
		index_insert(target, p_handle);
		p_txn.fail(recompute_status);
		return recompute_status;
	}

	AttributeValue &value = attr_it->second;
	const Fixed old_current = value.current;
	const std::uint64_t old_revision = value.revision.value;
	const std::uint64_t new_revision = old_revision + 1;

	AttributeChangeRecord record;
	record.attribute = target;
	record.old_base = base;
	record.new_base = base;
	record.old_current = old_current;
	record.new_current = effective;
	record.requested_current = requested;
	record.revision = new_revision;
	record.transaction = p_txn.id();
	record.provenance = p_provenance;

	const Status undo_status = p_txn.add_undo([this, p_handle, removed_copy, target, old_current, old_revision]() {
		modifiers.emplace(p_handle, removed_copy);
		index_insert(target, p_handle);
		auto restore_it = attributes.find(target);
		if (restore_it != attributes.end()) {
			restore_it->second.current = old_current;
			restore_it->second.revision.value = old_revision;
		}
	});
	if (!undo_status.ok()) {
		modifiers.emplace(p_handle, removed_copy);
		index_insert(target, p_handle);
		p_txn.fail(undo_status);
		return undo_status;
	}

	const Status notify_status = p_txn.add_notification([this, record, &p_queue]() {
		dispatch(record, p_queue);
	});
	if (!notify_status.ok()) {
		p_txn.fail(notify_status);
		return notify_status;
	}

	value.current = effective;
	value.revision.value = new_revision;
	return ok_status();
}

Status AttributeSet::apply_costs(const std::vector<AttributeCost> &p_costs,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	// Sum duplicate entries for the same attribute into one canonically
	// ordered (ascending DefinitionId, via std::map) total before doing
	// anything observable.
	std::map<DefinitionId, Fixed> totals;
	for (const AttributeCost &cost : p_costs) {
		auto it = totals.find(cost.attribute);
		if (it == totals.end()) {
			totals.emplace(cost.attribute, cost.amount);
			continue;
		}
		Fixed sum;
		const Status add_status = fixed_add(it->second, cost.amount, sum);
		if (!add_status.ok()) {
			p_txn.fail(add_status);
			return add_status;
		}
		it->second = sum;
	}

	// Preflight: validate every attribute before mutating any of them.
	for (const auto &entry : totals) {
		auto it = attributes.find(entry.first);
		if (it == attributes.end()) {
			const Status status = make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, entry.first);
			p_txn.fail(status);
			return status;
		}
		if (it->second.current < entry.second) {
			const Status status = make_status(StatusCode::INSUFFICIENT_ATTRIBUTE, DiagnosticId::NONE, entry.first);
			p_txn.fail(status);
			return status;
		}
	}

	// Apply: every attribute is now known-affordable.
	for (const auto &entry : totals) {
		auto it = attributes.find(entry.first);
		Fixed new_base;
		const Status sub_status = fixed_sub(it->second.base, entry.second, new_base);
		if (!sub_status.ok()) {
			p_txn.fail(sub_status);
			return sub_status;
		}
		const Status set_status = set_base(entry.first, new_base, p_txn, p_queue, p_provenance);
		if (!set_status.ok()) {
			return set_status;
		}
	}

	return ok_status();
}

// ---------------------------------------------------------------------------
// Canonical snapshots
// ---------------------------------------------------------------------------

Status AttributeSet::write_snapshot(SnapshotWriter &p_writer) const {
	return write_snapshot_filtered(p_writer, [](DefinitionId) { return true; });
}

Status AttributeSet::write_snapshot_filtered(SnapshotWriter &p_writer, const std::function<bool(DefinitionId)> &p_is_public) const {
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ATTRIBUTE_SET)) {
		return p_writer.status();
	}

	std::vector<DefinitionId> visible_attributes;
	visible_attributes.reserve(attributes.size());
	for (const auto &entry : attributes) {
		if (p_is_public(entry.first)) {
			visible_attributes.push_back(entry.first);
		}
	}
	p_writer.write_count(visible_attributes.size(), MAX_ATTRIBUTES);
	for (DefinitionId id : visible_attributes) {
		const AttributeValue &value = attributes.at(id);
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ATTRIBUTE_ENTRY)) {
			return p_writer.status();
		}
		p_writer.write_u32(id);
		p_writer.write_fixed(value.base);
		p_writer.write_fixed(value.current);
		p_writer.write_u64(value.revision.value);
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	const std::vector<ModifierHandle> order = canonical_modifier_order();
	std::vector<ModifierHandle> visible_modifiers;
	visible_modifiers.reserve(order.size());
	for (ModifierHandle handle : order) {
		if (p_is_public(modifiers.at(handle).target_attribute)) {
			visible_modifiers.push_back(handle);
		}
	}
	p_writer.write_count(visible_modifiers.size(), MAX_MODIFIERS);
	for (ModifierHandle handle : visible_modifiers) {
		const AttributeModifier &modifier = modifiers.at(handle);
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_MODIFIER_ENTRY)) {
			return p_writer.status();
		}
		p_writer.write_u32(modifier.target_attribute);
		p_writer.write_u8(static_cast<std::uint8_t>(modifier.op));
		p_writer.write_fixed(modifier.magnitude);
		p_writer.write_i32(modifier.priority);
		p_writer.write_u64(modifier.source.value);
		p_writer.write_u64(modifier.effect.value);
		p_writer.write_u32(modifier.declaration_index);
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!p_writer.end_section()) {
		return p_writer.status();
	}

	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AttributeSet::write_attribute_delta_record(SnapshotWriter &p_writer, DefinitionId p_id) const {
	auto it = attributes.find(p_id);
	if (it == attributes.end()) {
		return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
	}
	p_writer.write_u32(p_id);
	p_writer.write_fixed(it->second.base);
	p_writer.write_fixed(it->second.current);
	p_writer.write_u64(it->second.revision.value);

	// `canonical_modifier_order()` sorts EVERY active modifier by
	// (target_attribute, op, priority, source, effect, declaration_index) --
	// filtering it down to `p_id` preserves that same relative order (target
	// is the primary key) instead of re-deriving the tie-break order by
	// hand, so there is exactly one place that order is defined.
	const std::vector<ModifierHandle> canonical = canonical_modifier_order();
	std::vector<ModifierHandle> canonical_for_id;
	for (ModifierHandle handle : canonical) {
		if (modifiers.at(handle).target_attribute == p_id) {
			canonical_for_id.push_back(handle);
		}
	}
	p_writer.write_count(canonical_for_id.size(), MAX_MODIFIERS);
	for (ModifierHandle handle : canonical_for_id) {
		const AttributeModifier &modifier = modifiers.at(handle);
		p_writer.write_u8(static_cast<std::uint8_t>(modifier.op));
		p_writer.write_fixed(modifier.magnitude);
		p_writer.write_i32(modifier.priority);
		p_writer.write_u64(modifier.source.value);
		p_writer.write_u64(modifier.effect.value);
		p_writer.write_u32(modifier.declaration_index);
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AttributeSet::decode_attribute_delta_record(SnapshotReader &p_reader, DefinitionId &r_id, AttributeValue &r_value, std::vector<AttributeModifier> &r_modifiers) const {
	std::uint32_t id = 0;
	Fixed base;
	Fixed current;
	std::uint64_t revision = 0;
	if (!p_reader.read_u32(id) || !p_reader.read_fixed(base) || !p_reader.read_fixed(current) || !p_reader.read_u64(revision)) {
		return p_reader.status();
	}
	if (registry->find(id) == nullptr) {
		return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, id);
	}
	std::size_t modifier_count = 0;
	if (!p_reader.read_count(modifier_count, MAX_MODIFIERS)) {
		return p_reader.status();
	}
	std::vector<AttributeModifier> decoded;
	decoded.reserve(modifier_count);
	for (std::size_t i = 0; i < modifier_count; ++i) {
		std::uint8_t op_raw = 0;
		Fixed magnitude;
		std::int32_t priority = 0;
		std::uint64_t source_value = 0;
		std::uint64_t effect_value = 0;
		std::uint32_t declaration_index = 0;
		if (!p_reader.read_u8(op_raw) || !p_reader.read_fixed(magnitude) || !p_reader.read_i32(priority) ||
				!p_reader.read_u64(source_value) || !p_reader.read_u64(effect_value) || !p_reader.read_u32(declaration_index)) {
			return p_reader.status();
		}
		if (op_raw > static_cast<std::uint8_t>(ModifierOp::OVERRIDE)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, op_raw);
		}
		AttributeModifier modifier;
		modifier.target_attribute = id;
		modifier.op = static_cast<ModifierOp>(op_raw);
		modifier.magnitude = magnitude;
		modifier.priority = priority;
		modifier.source = SourceToken{ source_value };
		modifier.effect = EffectHandle{ effect_value };
		modifier.declaration_index = declaration_index;
		decoded.push_back(modifier);
	}
	if (!p_reader.ok()) {
		return p_reader.status();
	}
	AttributeValue value;
	value.base = base;
	value.current = current;
	value.revision.value = revision;
	r_id = id;
	r_value = value;
	r_modifiers = std::move(decoded);
	return ok_status();
}

void AttributeSet::install_records(std::map<DefinitionId, AttributeValue> p_attributes, std::vector<AttributeModifier> p_modifiers) {
	std::map<ModifierHandle, AttributeModifier> new_modifiers;
	HandleAllocator<ModifierHandle> new_allocator;
	// Modifiers are reassigned fresh handles in the SAME canonical order
	// `restore_snapshot` uses -- see that method's own doc comment on why
	// handle values are never trusted from input.
	for (const AttributeModifier &modifier : p_modifiers) {
		const ModifierHandle handle = new_allocator.allocate();
		new_modifiers.emplace(handle, modifier);
	}
	attributes = std::move(p_attributes);
	modifiers = std::move(new_modifiers);
	handle_allocator = new_allocator;
	rebuild_modifier_index();
}

Status AttributeSet::restore_snapshot(SnapshotReader &p_reader) {
	std::map<DefinitionId, AttributeValue> new_attributes;
	std::vector<AttributeModifier> new_modifier_list;
	const Status decode_status = decode_snapshot_section(p_reader, new_attributes, new_modifier_list);
	if (!decode_status.ok()) {
		return decode_status;
	}
	install_records(std::move(new_attributes), std::move(new_modifier_list));
	return ok_status();
}

Status AttributeSet::decode_snapshot_section(SnapshotReader &p_reader, std::map<DefinitionId, AttributeValue> &r_attributes, std::vector<AttributeModifier> &r_modifiers) const {
	std::map<DefinitionId, AttributeValue> new_attributes;
	std::vector<AttributeModifier> new_modifier_list;

	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ATTRIBUTE_SET)) {
		return p_reader.status();
	}

	std::size_t attribute_count = 0;
	if (!p_reader.read_count(attribute_count, MAX_ATTRIBUTES)) {
		return p_reader.status();
	}

	for (std::size_t i = 0; i < attribute_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ATTRIBUTE_ENTRY)) {
			return p_reader.status();
		}
		std::uint32_t id = 0;
		Fixed base;
		Fixed current;
		std::uint64_t revision = 0;
		if (!p_reader.read_u32(id) || !p_reader.read_fixed(base) || !p_reader.read_fixed(current) || !p_reader.read_u64(revision)) {
			return p_reader.status();
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		if (registry->find(id) == nullptr) {
			return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, id);
		}
		if (new_attributes.find(id) != new_attributes.end()) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::NONE, id);
		}
		AttributeValue value;
		value.base = base;
		value.current = current;
		value.revision.value = revision;
		new_attributes.emplace(id, value);
	}

	std::size_t modifier_count = 0;
	if (!p_reader.read_count(modifier_count, MAX_MODIFIERS)) {
		return p_reader.status();
	}

	for (std::size_t i = 0; i < modifier_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_MODIFIER_ENTRY)) {
			return p_reader.status();
		}
		std::uint32_t target = 0;
		std::uint8_t op_raw = 0;
		Fixed magnitude;
		std::int32_t priority = 0;
		std::uint64_t source_value = 0;
		std::uint64_t effect_value = 0;
		std::uint32_t declaration_index = 0;
		const bool fields_ok = p_reader.read_u32(target) && p_reader.read_u8(op_raw) && p_reader.read_fixed(magnitude) &&
				p_reader.read_i32(priority) && p_reader.read_u64(source_value) && p_reader.read_u64(effect_value) &&
				p_reader.read_u32(declaration_index);
		if (!fields_ok) {
			return p_reader.status();
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		if (op_raw > static_cast<std::uint8_t>(ModifierOp::OVERRIDE)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, op_raw);
		}
		if (registry->find(target) == nullptr) {
			return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, target);
		}

		AttributeModifier modifier;
		modifier.target_attribute = target;
		modifier.op = static_cast<ModifierOp>(op_raw);
		modifier.magnitude = magnitude;
		modifier.priority = priority;
		modifier.source = SourceToken{ source_value };
		modifier.effect = EffectHandle{ effect_value };
		modifier.declaration_index = declaration_index;

		new_modifier_list.push_back(modifier);
	}

	if (!p_reader.end_section()) {
		return p_reader.status();
	}
	if (!p_reader.ok()) {
		return p_reader.status();
	}

	r_attributes = std::move(new_attributes);
	r_modifiers = std::move(new_modifier_list);
	return ok_status();
}

} // namespace ga
