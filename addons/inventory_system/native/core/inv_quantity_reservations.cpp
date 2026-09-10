#include "core/inv_quantity_reservations.h"

#include "core/inv_hash.h"

#include <algorithm>
#include <set>
#include <type_traits>
#include <variant>

namespace inv {

namespace {

bool item_definition_has_trait(const ItemDefinition &p_definition, const std::string &p_trait) {
	for (const ItemTraitValue &trait : p_definition.traits) {
		if (trait.trait_identifier == p_trait) {
			return true;
		}
	}
	return false;
}

bool valid_token(const std::string &p_value) {
	return !p_value.empty() && p_value.size() <= MAX_STRING_BYTES;
}

} // namespace

PreparedQuantityReservations::PreparedQuantityReservations(const DefinitionCatalog &p_catalog) :
		catalog_(&p_catalog) {
}

QuantityReservationResult PreparedQuantityReservations::result_for(const Record &p_record, bool p_replayed) const {
	QuantityReservationResult result;
	result.accepted = true;
	result.replayed = p_replayed;
	result.status = ok_status();
	result.reservation_id = p_record.request.reservation_id;
	result.inventory = p_record.request.inventory;
	result.revision = p_record.commit.has_value() ?
			p_record.commit->successor_revision :
			p_record.request.expected_revision;
	result.quantity = p_record.request.quantity;
	result.lines = p_record.lines;
	switch (p_record.state) {
		case State::HELD:
			result.stage = QuantityReservationStage::HELD;
			break;
		case State::COMMITTED:
			result.stage = QuantityReservationStage::COMMITTED;
			break;
		case State::RELEASED:
			result.stage = QuantityReservationStage::RELEASED;
			break;
		case State::PUBLISHED:
			result.stage = QuantityReservationStage::PUBLISHED;
			break;
	}
	return result;
}


std::uint64_t PreparedQuantityReservations::quantity_held(
		InventoryId p_inventory,
		ItemInstanceId p_item) const {
	std::uint64_t held = 0;
	for (const auto &pair : records_) {
		if (pair.second.state != State::HELD || pair.second.request.inventory != p_inventory) {
			continue;
		}
		for (const QuantityReservationLine &line : pair.second.lines) {
			if (line.item == p_item) {
				held += line.quantity;
			}
		}
	}
	return held;
}

bool PreparedQuantityReservations::item_is_held(InventoryId p_inventory, ItemInstanceId p_item) const {
	return quantity_held(p_inventory, p_item) != 0;
}

QuantityReservationResult PreparedQuantityReservations::prepare(
		InventoryRuntime &p_inventory,
		const QuantityReservationRequest &p_request) {
	QuantityReservationResult rejected;
	rejected.reservation_id = p_request.reservation_id;
	rejected.inventory = p_request.inventory;
	rejected.revision = p_inventory.revision();
	rejected.quantity = p_request.quantity;

	if (!valid_token(p_request.reservation_id) || !valid_token(p_request.required_trait)) {
		rejected.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::RESERVATION_ID_INVALID);
		return rejected;
	}
	const auto existing = records_.find(p_request.reservation_id);
	if (existing != records_.end()) {
		if (existing->second.request == p_request) {
			return result_for(existing->second, true);
		}
		rejected.status = make_status(StatusCode::DUPLICATE_COMMAND, DiagnosticId::RESERVATION_CONFLICT);
		return rejected;
	}
	while (records_.size() >= MAX_PREPARED_QUANTITY_RESERVATIONS &&
			!terminal_order_.empty()) {
		const std::string oldest = terminal_order_.front();
		terminal_order_.erase(terminal_order_.begin());
		const auto terminal = records_.find(oldest);
		if (terminal != records_.end() &&
				(terminal->second.state == State::RELEASED ||
						terminal->second.state == State::PUBLISHED)) {
			records_.erase(terminal);
		}
	}
	if (records_.size() >= MAX_PREPARED_QUANTITY_RESERVATIONS) {
		rejected.status = make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, records_.size());
		return rejected;
	}
	if (p_request.inventory != p_inventory.id() ||
			p_request.expected_revision != p_inventory.revision()) {
		rejected.status = make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, p_inventory.revision());
		return rejected;
	}
	if (p_request.quantity == 0 || p_request.quantity > MAX_STACK_QUANTITY) {
		rejected.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_request.quantity);
		return rejected;
	}
	if (p_request.container_definition_priority.empty() ||
			p_request.container_definition_priority.size() > MAX_CONTAINERS_PER_PROFILE) {
		rejected.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::RESERVATION_SOURCE_POLICY_INVALID, p_request.container_definition_priority.size());
		return rejected;
	}
	std::set<std::string> seen_priorities;
	for (const std::string &identifier : p_request.container_definition_priority) {
		if (!valid_token(identifier) || catalog_->find_container(identifier) == nullptr ||
				!seen_priorities.insert(identifier).second) {
			rejected.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::RESERVATION_SOURCE_POLICY_INVALID, hash_string(identifier));
			return rejected;
		}
	}

	std::uint64_t remaining = p_request.quantity;
	std::vector<QuantityReservationLine> lines;
	for (const std::string &container_identifier : p_request.container_definition_priority) {
		for (const auto &item_pair : p_inventory.items()) {
			const ItemInstance &item = item_pair.second;
			const ContainerInstance *container = p_inventory.find_container(location_container(item.location));
			if (container == nullptr) {
				continue;
			}
			const std::string *actual_container_identifier =
					p_inventory.container_definition_identifier(container->container_definition);
			if (actual_container_identifier == nullptr ||
					*actual_container_identifier != container_identifier) {
				continue;
			}
			const std::string *item_identifier =
					p_inventory.item_definition_identifier(item.item_definition);
			const ItemDefinition *definition = item_identifier == nullptr ?
					nullptr :
					catalog_->find_item(*item_identifier);
			if (definition == nullptr ||
					!item_definition_has_trait(*definition, p_request.required_trait) ||
					!item.provided_containers.empty()) {
				continue;
			}
			const std::uint64_t held = quantity_held(p_inventory.id(), item.id);
			const std::uint64_t available = held >= item.quantity ? 0 : item.quantity - held;
			const std::uint64_t selected = std::min(available, remaining);
			if (selected != 0) {
				lines.push_back(QuantityReservationLine{ item.id, selected });
				remaining -= selected;
			}
			if (remaining == 0 || lines.size() >= MAX_PREPARED_QUANTITY_LINES) {
				break;
			}
		}
		if (remaining == 0 || lines.size() >= MAX_PREPARED_QUANTITY_LINES) {
			break;
		}
	}
	if (remaining != 0) {
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_INSUFFICIENT_QUANTITY, p_request.quantity - remaining);
		return rejected;
	}

	// Reservation-line hold generations (inventory-transactions delta,
	// "Prepared Quantity Reservation Participant"): bump this item's own
	// monotonic counter once per newly placed line, independent of every
	// other item's counter and of the inventory's aggregate revision.
	// Concurrent holds on the same item instance (two reservations each
	// taking part of one stack) each get their own strictly increasing
	// stamp; nothing here ever decreases.
	for (QuantityReservationLine &line : lines) {
		std::uint64_t &generation = item_generation_[ItemGenerationKey{ p_inventory.id(), line.item }];
		++generation;
		line.generation = generation;
	}

	Record record;
	record.request = p_request;
	record.lines = std::move(lines);
	auto inserted = records_.emplace(p_request.reservation_id, std::move(record));
	return result_for(inserted.first->second, false);
}

QuantityReservationResult PreparedQuantityReservations::release(
		InventoryRuntime &p_inventory,
		const std::string &p_reservation_id) {
	QuantityReservationResult rejected;
	rejected.reservation_id = p_reservation_id;
	rejected.inventory = p_inventory.id();
	rejected.revision = p_inventory.revision();
	const auto found = records_.find(p_reservation_id);
	if (found == records_.end()) {
		rejected.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RESERVATION_STATE_INVALID);
		return rejected;
	}
	Record &record = found->second;
	if (record.request.inventory != p_inventory.id()) {
		rejected.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::RESERVATION_CONFLICT);
		return rejected;
	}
	if (record.state == State::RELEASED) {
		return result_for(record, true);
	}
	if (record.state != State::HELD) {
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected;
	}
	record.state = State::RELEASED;
	terminal_order_.push_back(p_reservation_id);
	QuantityReservationResult result = result_for(record, false);
	trim_terminal_records();
	return result;
}

QuantityReservationResult PreparedQuantityReservations::commit_silent(
		InventoryRuntime &p_inventory,
		const std::string &p_reservation_id) {
	QuantityReservationResult rejected;
	rejected.reservation_id = p_reservation_id;
	rejected.inventory = p_inventory.id();
	rejected.revision = p_inventory.revision();
	const auto found = records_.find(p_reservation_id);
	if (found == records_.end()) {
		rejected.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RESERVATION_STATE_INVALID);
		return rejected;
	}
	Record &record = found->second;
	if (record.state == State::COMMITTED || record.state == State::PUBLISHED) {
		return result_for(record, true);
	}
	if (record.state != State::HELD || record.request.inventory != p_inventory.id()) {
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected;
	}

	InventoryRuntime clone = p_inventory;
	PreparedQuantityCommit commit;
	commit.reservation_id = p_reservation_id;
	commit.inventory = p_inventory.id();
	commit.predecessor_revision = p_inventory.revision();
	commit.quantity = record.request.quantity;
	for (const QuantityReservationLine &line : record.lines) {
		// Commit-time validation checks each held line against its recorded
		// hold generation and the item's CURRENT quantity -- never the
		// inventory's aggregate revision (Selective Hold Isolation): an
		// unrelated accepted mutation that advanced the aggregate revision
		// since this reservation was created must not, by itself, fail this
		// commit. item_generation_ only ever increases (prepare()), so a
		// recorded generation newer than what the ledger currently knows
		// means this line's own bookkeeping was corrupted/rewound -- fail
		// closed rather than trust a quantity check alone.
		const auto generation_it = item_generation_.find(ItemGenerationKey{ p_inventory.id(), line.item });
		if (generation_it == item_generation_.end() || generation_it->second < line.generation) {
			rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_CONFLICT, line.item.value);
			return rejected;
		}
		const ItemInstance *item = clone.find_item(line.item);
		if (item == nullptr || item->quantity < line.quantity) {
			rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_CONFLICT, line.item.value);
			return rejected;
		}
		const std::uint64_t before = item->quantity;
		const std::uint64_t after = before - line.quantity;
		Status status = after == 0 ?
				clone.destroy_item(line.item) :
				clone.set_quantity(line.item, after);
		if (!status.ok()) {
			rejected.status = status;
			return rejected;
		}
		commit.lines.push_back(QuantityConsumptionLine{
				line.item, before, line.quantity, after, after == 0 });
	}
	Status status = clone.validate_invariants();
	if (!status.ok()) {
		rejected.status = status;
		return rejected;
	}
	record.predecessor = p_inventory;
	p_inventory = std::move(clone);
	commit.successor_revision = p_inventory.commit_revision();
	record.commit = commit;
	record.state = State::COMMITTED;
	return result_for(record, false);
}

QuantityReservationResult PreparedQuantityReservations::rollback(
		InventoryRuntime &p_inventory,
		const std::string &p_reservation_id) {
	QuantityReservationResult rejected;
	rejected.reservation_id = p_reservation_id;
	rejected.inventory = p_inventory.id();
	rejected.revision = p_inventory.revision();
	const auto found = records_.find(p_reservation_id);
	if (found == records_.end()) {
		rejected.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RESERVATION_STATE_INVALID);
		return rejected;
	}
	Record &record = found->second;
	if (record.state != State::COMMITTED || !record.predecessor.has_value() ||
			!record.commit.has_value() ||
			p_inventory.id() != record.request.inventory ||
			p_inventory.revision() != record.commit->successor_revision) {
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected;
	}
	p_inventory = *record.predecessor;
	record.predecessor.reset();
	record.commit.reset();
	record.state = State::RELEASED;
	terminal_order_.push_back(p_reservation_id);
	QuantityReservationResult result = result_for(record, false);
	result.revision = p_inventory.revision();
	trim_terminal_records();
	return result;
}

QuantityReservationResult PreparedQuantityReservations::publish(const std::string &p_reservation_id) {
	QuantityReservationResult rejected;
	rejected.reservation_id = p_reservation_id;
	const auto found = records_.find(p_reservation_id);
	if (found == records_.end()) {
		rejected.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RESERVATION_STATE_INVALID);
		return rejected;
	}
	Record &record = found->second;
	if (record.state == State::PUBLISHED) {
		return result_for(record, true);
	}
	if (record.state != State::COMMITTED || !record.commit.has_value()) {
		rejected.inventory = record.request.inventory;
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected;
	}
	const PreparedQuantityCommit commit = *record.commit;
	record.state = State::PUBLISHED;
	record.predecessor.reset();
	terminal_order_.push_back(p_reservation_id);
	QuantityReservationResult result = result_for(record, false);
	trim_terminal_records();
	// `notify()` is reentrant: an observer may clear this inventory, release
	// this record, or otherwise mutate the ledger. Do not retain a Record
	// reference across the callback; the copied result and commit are complete
	// before observers run.
	notify(commit);
	return result;
}

QuantityReservationResult PreparedQuantityReservations::expire(
		InventoryRuntime &p_inventory,
		const std::string &p_reservation_id,
		std::uint64_t p_current_tick) {
	QuantityReservationResult rejected;
	rejected.reservation_id = p_reservation_id;
	rejected.inventory = p_inventory.id();
	rejected.revision = p_inventory.revision();
	const auto found = records_.find(p_reservation_id);
	if (found == records_.end()) {
		rejected.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RESERVATION_STATE_INVALID);
		return rejected;
	}
	Record &record = found->second;
	if (record.state == State::RELEASED || record.state == State::PUBLISHED) {
		// Idempotent: an already-terminal record returns its recorded
		// terminal outcome rather than erroring (matches release()).
		return result_for(record, true);
	}
	if (record.request.inventory != p_inventory.id()) {
		rejected.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::RESERVATION_CONFLICT);
		return rejected;
	}
	if (record.request.deadline_tick == 0 || p_current_tick < record.request.deadline_tick) {
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_NOT_DUE, record.request.deadline_tick);
		return rejected;
	}
	if (record.state == State::COMMITTED) {
		// Discard the unpublished silent successor exactly like rollback():
		// restore the immediate predecessor first, still serialized, before
		// this hold ever reaches a terminal state -- never publish, never
		// leave canonical revision advanced.
		if (!record.predecessor.has_value() || !record.commit.has_value() ||
				p_inventory.revision() != record.commit->successor_revision) {
			rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_STATE_INVALID, static_cast<std::uint64_t>(record.state));
			return rejected;
		}
		p_inventory = *record.predecessor;
		record.predecessor.reset();
		record.commit.reset();
	}
	record.state = State::RELEASED;
	terminal_order_.push_back(p_reservation_id);
	QuantityReservationResult result = result_for(record, false);
	result.revision = p_inventory.revision();
	trim_terminal_records();
	return result;
}

QuantityReservationResult PreparedQuantityReservations::health(const std::string &p_reservation_id) const {
	const auto found = records_.find(p_reservation_id);
	if (found == records_.end()) {
		QuantityReservationResult rejected;
		rejected.reservation_id = p_reservation_id;
		rejected.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RESERVATION_STATE_INVALID);
		return rejected;
	}
	return result_for(found->second, true);
}

bool PreparedQuantityReservations::conflicts(const Command &p_command, const InventoryRuntime *p_inventory) const {
	const InventoryId single_inventory = p_inventory == nullptr ? InventoryId{} : p_inventory->id();
	return std::visit(
			[&](const auto &p_body) {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, MoveItemCommand> ||
						std::is_same_v<T, RotateItemCommand> ||
						std::is_same_v<T, EquipItemCommand> ||
						std::is_same_v<T, UnequipItemCommand> ||
						std::is_same_v<T, AutoPlaceItemCommand> ||
						std::is_same_v<T, RemoveItemCommand> ||
							std::is_same_v<T, DropItemCommand> ||
							std::is_same_v<T, LootItemCommand> ||
							std::is_same_v<T, QuickTransferItemCommand> ||
							std::is_same_v<T, TargetedProviderTransferCommand> ||
							std::is_same_v<T, SetItemComponentCommand> ||
							std::is_same_v<T, RemoveItemComponentCommand>) {
					if constexpr (std::is_same_v<T, QuickTransferItemCommand> ||
							std::is_same_v<T, TargetedProviderTransferCommand> ||
							std::is_same_v<T, LootItemCommand>) {
						return item_is_held(p_body.source, p_body.item);
					} else {
						return single_inventory && item_is_held(single_inventory, p_body.item);
					}
				} else if constexpr (std::is_same_v<T, SplitStackCommand>) {
					if (!single_inventory) {
						return false;
					}
					const std::uint64_t held = quantity_held(single_inventory, p_body.source);
					if (held == 0) {
						return false;
					}
					// Selective Hold Isolation, "Stack contains held and
					// unheld quantity": a split that extracts only the
					// provably unheld remainder -- leaving at least the held
					// quantity behind under the SAME source id, so the held
					// line is neither moved nor re-identified -- does not
					// conflict and may proceed under ordinary validation.
					if (p_inventory != nullptr) {
						const ItemInstance *item = p_inventory->find_item(p_body.source);
						if (item != nullptr && item->quantity >= held + p_body.quantity) {
							return false;
						}
					}
					return true;
				} else if constexpr (std::is_same_v<T, MergeStacksCommand>) {
					return single_inventory &&
							(item_is_held(single_inventory, p_body.source) ||
									item_is_held(single_inventory, p_body.destination));
				} else if constexpr (std::is_same_v<T, SwapItemsCommand>) {
					return single_inventory &&
							(item_is_held(single_inventory, p_body.item_a) ||
									item_is_held(single_inventory, p_body.item_b));
				} else if constexpr (std::is_same_v<T, SettleInventoryCommand>) {
					for (const SettlementEntry &entry : p_body.plan) {
						if (item_is_held(p_body.inventory, entry.item)) {
							return true;
						}
					}
					return false;
				} else {
					return false;
				}
			},
			p_command);
}

void PreparedQuantityReservations::add_observer(std::uint64_t p_owner_key, Observer p_observer) {
	for (auto &entry : observers_) {
		if (entry.first == p_owner_key) {
			entry.second = std::move(p_observer);
			return;
		}
	}
	observers_.emplace_back(p_owner_key, std::move(p_observer));
}

void PreparedQuantityReservations::remove_observer(std::uint64_t p_owner_key) {
	observers_.erase(
			std::remove_if(observers_.begin(), observers_.end(),
					[&](const auto &p_entry) { return p_entry.first == p_owner_key; }),
			observers_.end());
}

void PreparedQuantityReservations::notify(const PreparedQuantityCommit &p_commit) const {
	for (const auto &entry : observers_) {
		if (entry.second) {
			entry.second(p_commit);
		}
	}
}

std::size_t PreparedQuantityReservations::active_count() const {
	std::size_t count = 0;
	for (const auto &pair : records_) {
		if (pair.second.state == State::HELD || pair.second.state == State::COMMITTED) {
			++count;
		}
	}
	return count;
}

void PreparedQuantityReservations::clear() {
	records_.clear();
	terminal_order_.clear();
	item_generation_.clear();
}

std::size_t PreparedQuantityReservations::clear_inventory(InventoryId p_inventory) {
	if (!p_inventory) {
		return 0;
	}

	// Remove terminal journal entries while their records are still available,
	// avoiding an allocation during destructive inventory teardown.  The journal
	// is bounded and only refers to records in this map.
	terminal_order_.erase(
			std::remove_if(
					terminal_order_.begin(),
					terminal_order_.end(),
					[&](const std::string &p_reservation_id) {
						auto record = records_.find(p_reservation_id);
						return record != records_.end() &&
								record->second.request.inventory == p_inventory;
					}),
			terminal_order_.end());

	std::size_t removed = 0;
	for (auto it = records_.begin(); it != records_.end();) {
		if (it->second.request.inventory != p_inventory) {
			++it;
			continue;
		}
		it = records_.erase(it);
		++removed;
	}

	// Generation counters are inventory-qualified. Clear them even when all
	// records for this inventory were previously evicted from the bounded
	// terminal journal; otherwise a reused raw item id could inherit stale
	// hold generations from the unloaded runtime.
	for (auto it = item_generation_.begin(); it != item_generation_.end();) {
		if (it->first.inventory == p_inventory) {
			it = item_generation_.erase(it);
		} else {
			++it;
		}
	}
	return removed;
}

void PreparedQuantityReservations::trim_terminal_records() {
	while (records_.size() > MAX_PREPARED_QUANTITY_RESERVATIONS &&
			!terminal_order_.empty()) {
		const std::string oldest = terminal_order_.front();
		terminal_order_.erase(terminal_order_.begin());
		const auto found = records_.find(oldest);
		if (found != records_.end() &&
				(found->second.state == State::RELEASED ||
						found->second.state == State::PUBLISHED)) {
			records_.erase(found);
		}
	}
}

} // namespace inv
