#include "core/inv_discovery.h"

#include "core/inv_builtin_features.h"
#include "core/inv_bytes.h"
#include "core/inv_hash.h"
#include "core/inv_limits.h"

#include <algorithm>
#include <limits>
#include <tuple>
#include <utility>

namespace inv {

bool DiscoveryStateStore::TokenSubject::operator<(const TokenSubject &p_other) const {
	return std::tie(kind, inventory.value, container.value, item.value) <
			std::tie(p_other.kind, p_other.inventory.value, p_other.container.value, p_other.item.value);
}

DiscoveryStateStore::RecipientState *DiscoveryStateStore::find_recipient(DiscoveryRecipientKey p_recipient) {
	const auto found = recipients_.find(p_recipient);
	return found != recipients_.end() ? &found->second : nullptr;
}

const DiscoveryStateStore::RecipientState *DiscoveryStateStore::find_recipient(DiscoveryRecipientKey p_recipient) const {
	const auto found = recipients_.find(p_recipient);
	return found != recipients_.end() ? &found->second : nullptr;
}

const DiscoveryStateStore::InventoryDiscoveryState *DiscoveryStateStore::find_inventory_state(
		const RecipientState &p_state,
		InventoryId p_inventory) const {
	const auto found = p_state.inventories.find(p_inventory);
	return found != p_state.inventories.end() ? &found->second : nullptr;
}

DiscoveryStateStore::InventoryDiscoveryState &DiscoveryStateStore::ensure_inventory_state(
		RecipientState &r_state,
		const InventoryRuntime &p_runtime) {
	auto inserted = r_state.inventories.emplace(p_runtime.id(), InventoryDiscoveryState{});
	if (inserted.second) {
		inserted.first->second.observed_inventory_revision = p_runtime.revision();
	}
	return inserted.first->second;
}

Status DiscoveryStateStore::register_recipient(DiscoveryRecipientKey p_recipient, std::uint64_t p_token_seed) {
	if (p_recipient.session_id == 0 || p_recipient.actor_id == 0 ||
			p_token_seed == 0 || p_token_seed == std::numeric_limits<std::uint64_t>::max()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	const auto found = recipients_.find(p_recipient);
	if (found != recipients_.end()) {
		return found->second.token_seed == p_token_seed
				? ok_status()
				: make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::IDEMPOTENCY_PAYLOAD_MISMATCH);
	}
	if (recipients_.size() >= MAX_DISCOVERY_RECIPIENTS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::DISCOVERY_RECIPIENT_LIMIT, recipients_.size());
	}
	RecipientState state;
	state.token_seed = p_token_seed;
	state.next_token = p_token_seed;
	recipients_.emplace(p_recipient, std::move(state));
	return ok_status();
}

void DiscoveryStateStore::teardown_recipient(DiscoveryRecipientKey p_recipient) {
	recipients_.erase(p_recipient);
}

void DiscoveryStateStore::teardown_session(std::uint64_t p_session_id) {
	for (auto it = recipients_.begin(); it != recipients_.end();) {
		if (it->first.session_id == p_session_id) {
			it = recipients_.erase(it);
		} else {
			++it;
		}
	}
}

bool DiscoveryStateStore::clear_inventory_state(RecipientState &r_state, InventoryId p_inventory) {
	bool changed = r_state.inventories.erase(p_inventory) != 0;
	for (auto it = r_state.indexed_containers.begin(); it != r_state.indexed_containers.end();) {
		if (it->inventory == p_inventory) {
			it = r_state.indexed_containers.erase(it);
			changed = true;
		} else {
			++it;
		}
	}
	for (auto it = r_state.revealed_items.begin(); it != r_state.revealed_items.end();) {
		if (it->inventory == p_inventory) {
			it = r_state.revealed_items.erase(it);
			changed = true;
		} else {
			++it;
		}
	}
	if (r_state.task.inventory == p_inventory) {
		r_state.task = DiscoveryTask{};
		changed = true;
	}
	for (auto it = r_state.idempotency.begin(); it != r_state.idempotency.end();) {
		if (it->second.inventory == p_inventory) {
			it = r_state.idempotency.erase(it);
			changed = true;
		} else {
			++it;
		}
	}
	const std::size_t before_tokens = r_state.token_bindings.size();
	clear_tokens_for_inventory(r_state, p_inventory);
	changed = changed || before_tokens != r_state.token_bindings.size();
	return changed;
}

void DiscoveryStateStore::clear_tokens_for_inventory(RecipientState &r_state, InventoryId p_inventory) {
	for (auto it = r_state.token_bindings.begin(); it != r_state.token_bindings.end();) {
		if (it->second.subject.inventory == p_inventory) {
			r_state.tokens_by_subject.erase(it->second.subject);
			it = r_state.token_bindings.erase(it);
		} else {
			++it;
		}
	}
}

Status DiscoveryStateStore::bump_revision(RecipientState &r_state, InventoryId p_inventory) {
	auto found = r_state.inventories.find(p_inventory);
	if (found == r_state.inventories.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	if (found->second.revision == std::numeric_limits<std::uint64_t>::max()) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED);
	}
	++found->second.revision;
	clear_tokens_for_inventory(r_state, p_inventory);
	return ok_status();
}

bool DiscoveryStateStore::task_target_valid(const RecipientState &p_state, const InventoryRuntime &p_runtime) {
	if (!p_state.task.active() || p_state.task.inventory != p_runtime.id()) {
		return true;
	}
	const ContainerInstance *container = p_runtime.find_container(p_state.task.container);
	const DiscoveryPolicyDefinition *policy = p_runtime.discovery_policy(p_state.task.container);
	if (container == nullptr || policy == nullptr || !p_runtime.has_feature(FEATURE_DISCOVERY)) {
		return false;
	}
	if (p_state.task.kind == DiscoveryTaskKind::ITEM_SCAN) {
		const ItemInstance *item = p_runtime.find_item(p_state.task.item);
		return item != nullptr && location_container(item->location) == p_state.task.container;
	}
	return true;
}

Status DiscoveryStateStore::reconcile(const InventoryRuntime &p_runtime) {
	for (auto &recipient_pair : recipients_) {
		RecipientState &state = recipient_pair.second;
		InventoryDiscoveryState &inventory_state = ensure_inventory_state(state, p_runtime);
		if (inventory_state.observed_inventory_revision == p_runtime.revision()) {
			continue;
		}
		if (inventory_state.revision == std::numeric_limits<std::uint64_t>::max()) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED);
		}

		for (auto it = state.indexed_containers.begin(); it != state.indexed_containers.end();) {
			if (it->inventory == p_runtime.id() && p_runtime.find_container(it->container) == nullptr) {
				it = state.indexed_containers.erase(it);
			} else {
				++it;
			}
		}
		for (auto it = state.revealed_items.begin(); it != state.revealed_items.end();) {
			if (it->inventory == p_runtime.id() && p_runtime.find_item(it->item) == nullptr) {
				it = state.revealed_items.erase(it);
			} else {
				++it;
			}
		}
		if (!task_target_valid(state, p_runtime)) {
			state.task = DiscoveryTask{};
		}
		inventory_state.observed_inventory_revision = p_runtime.revision();
		++inventory_state.revision;
		clear_tokens_for_inventory(state, p_runtime.id());
	}
	return ok_status();
}

Status DiscoveryStateStore::transfer_revealed_item(
		const InventoryRuntime &p_source,
		const InventoryRuntime &p_destination,
		ItemInstanceId p_item) {
	if (!p_item || p_source.id() == p_destination.id() ||
			p_destination.find_item(p_item) == nullptr) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DISCOVERY_TARGET_STALE);
	}
	// Preflight every affected recipient before changing any of them.
	for (const auto &recipient_pair : recipients_) {
		const RecipientState &state = recipient_pair.second;
		if (state.revealed_items.count(ItemKey{ p_source.id(), p_item }) == 0) {
			continue;
		}
		const InventoryDiscoveryState *source_state = find_inventory_state(state, p_source.id());
		const InventoryDiscoveryState *destination_state = find_inventory_state(state, p_destination.id());
		if ((source_state != nullptr && source_state->revision == std::numeric_limits<std::uint64_t>::max()) ||
				(destination_state != nullptr && destination_state->revision == std::numeric_limits<std::uint64_t>::max())) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED);
		}
		// Erasing the source and inserting the destination keeps the total
		// cardinality unchanged, so a state already at the bound is valid.
	}
	for (auto &recipient_pair : recipients_) {
		RecipientState &state = recipient_pair.second;
		const ItemKey source_key{ p_source.id(), p_item };
		if (state.revealed_items.erase(source_key) == 0) {
			continue;
		}
		ensure_inventory_state(state, p_source);
		ensure_inventory_state(state, p_destination);
		state.revealed_items.insert(ItemKey{ p_destination.id(), p_item });
		Status source_status = bump_revision(state, p_source.id());
		if (!source_status.ok()) {
			return source_status;
		}
		Status destination_status = bump_revision(state, p_destination.id());
		if (!destination_status.ok()) {
			return destination_status;
		}
	}
	return ok_status();
}

Status DiscoveryStateStore::revoke_inventory_access(DiscoveryRecipientKey p_recipient, InventoryId p_inventory) {
	RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	clear_inventory_state(*state, p_inventory);
	return ok_status();
}

std::size_t DiscoveryStateStore::clear_inventory(InventoryId p_inventory) {
	if (!p_inventory) {
		return 0;
	}
	std::size_t changed = 0;
	for (auto &recipient_pair : recipients_) {
		if (clear_inventory_state(recipient_pair.second, p_inventory)) {
			++changed;
		}
	}
	return changed;
}

std::uint64_t DiscoveryStateStore::intent_fingerprint(
		DiscoveryTaskKind p_kind,
		const DiscoveryIntentHeader &p_header,
		std::uint64_t p_token) {
	ByteWriter writer(80);
	writer.write_u8(static_cast<std::uint8_t>(p_kind));
	writer.write_u64(p_header.recipient.session_id);
	writer.write_u64(p_header.recipient.actor_id);
	writer.write_u64(p_header.request_id);
	writer.write_u64(p_header.inventory.value);
	writer.write_u64(p_header.expected_inventory_revision);
	writer.write_u64(p_header.expected_discovery_revision);
	writer.write_u64(p_token);
	return hash_bytes(writer.bytes());
}

DiscoveryIntentResult DiscoveryStateStore::reject(
		Status p_status,
		const InventoryRuntime *p_runtime,
		std::uint64_t p_discovery_revision) {
	DiscoveryIntentResult result;
	result.status = p_status;
	if (p_runtime != nullptr) {
		result.inventory_revision = p_runtime->revision();
	}
	result.discovery_revision = p_discovery_revision;
	return result;
}

bool DiscoveryStateStore::can_record_intent(const RecipientState &p_state, std::uint64_t p_request_id) {
	return p_state.idempotency.find(p_request_id) != p_state.idempotency.end() ||
			p_state.idempotency.size() < MAX_DISCOVERY_IDEMPOTENCY_RECORDS;
}

DiscoveryIntentResult DiscoveryStateStore::replay_or_mismatch(
		const RecipientState &p_state,
		std::uint64_t p_request_id,
		std::uint64_t p_fingerprint,
		bool &r_found) const {
	r_found = false;
	const auto found = p_state.idempotency.find(p_request_id);
	if (found == p_state.idempotency.end()) {
		return DiscoveryIntentResult{};
	}
	r_found = true;
	if (found->second.fingerprint != p_fingerprint) {
		return reject(make_status(StatusCode::DUPLICATE_COMMAND, DiagnosticId::IDEMPOTENCY_PAYLOAD_MISMATCH));
	}
	DiscoveryIntentResult result = found->second.result;
	result.replayed = true;
	result.status = make_status(StatusCode::OK, DiagnosticId::DUPLICATE_RESULT_REPLAY);
	return result;
}

void DiscoveryStateStore::record_intent(
		RecipientState &r_state,
		std::uint64_t p_request_id,
		std::uint64_t p_fingerprint,
		InventoryId p_inventory,
		const DiscoveryIntentResult &p_result) {
	r_state.idempotency.emplace(p_request_id, CachedIntent{ p_fingerprint, p_inventory, p_result });
}

const DiscoveryStateStore::TokenBinding *DiscoveryStateStore::resolve_token(
		const RecipientState &p_state,
		std::uint64_t p_token,
		DiscoveryTokenKind p_kind,
		const InventoryRuntime &p_runtime) const {
	const auto found = p_state.token_bindings.find(p_token);
	if (found == p_state.token_bindings.end() ||
			found->second.subject.kind != p_kind ||
			found->second.subject.inventory != p_runtime.id() ||
			found->second.inventory_revision != p_runtime.revision()) {
		return nullptr;
	}
	const InventoryDiscoveryState *inventory_state = find_inventory_state(p_state, p_runtime.id());
	if (inventory_state == nullptr || found->second.discovery_revision != inventory_state->revision) {
		return nullptr;
	}
	return &found->second;
}

Status DiscoveryStateStore::issue_token(
		RecipientState &r_state,
		const TokenSubject &p_subject,
		std::uint64_t p_inventory_revision,
		std::uint64_t &r_token) {
	const InventoryDiscoveryState *inventory_state = find_inventory_state(r_state, p_subject.inventory);
	if (inventory_state == nullptr || inventory_state->observed_inventory_revision != p_inventory_revision) {
		return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::DISCOVERY_REVISION_STALE);
	}
	const auto existing = r_state.tokens_by_subject.find(p_subject);
	if (existing != r_state.tokens_by_subject.end()) {
		r_token = existing->second;
		return ok_status();
	}
	if (r_state.token_bindings.size() >= MAX_DISCOVERY_TOKEN_BINDINGS ||
			r_state.next_token == std::numeric_limits<std::uint64_t>::max()) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	const std::uint64_t token = ++r_state.next_token;
	TokenBinding binding;
	binding.subject = p_subject;
	binding.inventory_revision = p_inventory_revision;
	binding.discovery_revision = inventory_state->revision;
	r_state.token_bindings.emplace(token, binding);
	r_state.tokens_by_subject.emplace(p_subject, token);
	r_token = token;
	return ok_status();
}

Status DiscoveryStateStore::issue_container_token(
		DiscoveryRecipientKey p_recipient,
		InventoryId p_inventory,
		std::uint64_t p_inventory_revision,
		ContainerInstanceId p_container,
		std::uint64_t &r_token) {
	RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr || !p_inventory || !p_container) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	return issue_token(*state, TokenSubject{ DiscoveryTokenKind::CONTAINER_SHELL, p_inventory, p_container, ItemInstanceId{} }, p_inventory_revision, r_token);
}

Status DiscoveryStateStore::issue_item_token(
		DiscoveryRecipientKey p_recipient,
		InventoryId p_inventory,
		std::uint64_t p_inventory_revision,
		ContainerInstanceId p_container,
		ItemInstanceId p_item,
		std::uint64_t &r_token) {
	RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr || !p_inventory || !p_container || !p_item) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	return issue_token(*state, TokenSubject{ DiscoveryTokenKind::UNKNOWN_ITEM, p_inventory, p_container, p_item }, p_inventory_revision, r_token);
}

Status DiscoveryStateStore::discovery_revision(
		DiscoveryRecipientKey p_recipient,
		InventoryId p_inventory,
		std::uint64_t &r_revision) const {
	const RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	const InventoryDiscoveryState *inventory_state = find_inventory_state(*state, p_inventory);
	if (inventory_state == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	r_revision = inventory_state->revision;
	return ok_status();
}

Status DiscoveryStateStore::container_stage(
		DiscoveryRecipientKey p_recipient,
		InventoryId p_inventory,
		ContainerInstanceId p_container,
		DiscoveryContainerStage &r_stage) const {
	const RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	if (state->indexed_containers.count(InventoryKey{ p_inventory, p_container }) != 0) {
		r_stage = DiscoveryContainerStage::INDEXED;
	} else if (state->task.kind == DiscoveryTaskKind::CONTAINER_SEARCH &&
			state->task.inventory == p_inventory && state->task.container == p_container) {
		r_stage = DiscoveryContainerStage::SEARCHING;
	} else {
		r_stage = DiscoveryContainerStage::UNSEARCHED;
	}
	return ok_status();
}

bool DiscoveryStateStore::item_revealed(
		DiscoveryRecipientKey p_recipient,
		InventoryId p_inventory,
		ItemInstanceId p_item) const {
	const RecipientState *state = find_recipient(p_recipient);
	return state != nullptr && state->revealed_items.count(ItemKey{ p_inventory, p_item }) != 0;
}

Status DiscoveryStateStore::active_task(DiscoveryRecipientKey p_recipient, DiscoveryTask &r_task) const {
	const RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	r_task = state->task;
	return ok_status();
}

DiscoveryIntentResult DiscoveryStateStore::begin_container_search(
		const InventoryRuntime &p_runtime,
		const DiscoveryIntentHeader &p_header,
		std::uint64_t p_container_token) {
	RecipientState *state = find_recipient(p_header.recipient);
	if (state == nullptr) {
		return reject(make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN), &p_runtime);
	}
	const std::uint64_t fingerprint = intent_fingerprint(DiscoveryTaskKind::CONTAINER_SEARCH, p_header, p_container_token);
	bool duplicate = false;
	DiscoveryIntentResult replay = replay_or_mismatch(*state, p_header.request_id, fingerprint, duplicate);
	if (duplicate) {
		return replay;
	}
	if (p_header.request_id == 0 || !p_header.inventory || p_header.inventory != p_runtime.id()) {
		return reject(make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE), &p_runtime);
	}
	if (!can_record_intent(*state, p_header.request_id)) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime);
	}
	Status reconcile_status = reconcile(p_runtime);
	if (!reconcile_status.ok()) {
		return reject(reconcile_status, &p_runtime);
	}
	InventoryDiscoveryState &inventory_state = ensure_inventory_state(*state, p_runtime);
	if (p_header.expected_inventory_revision != p_runtime.revision()) {
		return reject(make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE), &p_runtime, inventory_state.revision);
	}
	if (p_header.expected_discovery_revision != inventory_state.revision) {
		return reject(make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::DISCOVERY_REVISION_STALE), &p_runtime, inventory_state.revision);
	}
	if (state->task.active()) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_BUSY), &p_runtime, inventory_state.revision);
	}
	const TokenBinding *binding = resolve_token(*state, p_container_token, DiscoveryTokenKind::CONTAINER_SHELL, p_runtime);
	if (binding == nullptr) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_TOKEN_INVALID), &p_runtime, inventory_state.revision);
	}
	const ContainerInstanceId container = binding->subject.container;
	const DiscoveryPolicyDefinition *policy = p_runtime.discovery_policy(container);
	if (policy == nullptr || !p_runtime.has_feature(FEATURE_DISCOVERY)) {
		return reject(make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::DISCOVERY_FEATURE_REQUIRED), &p_runtime, inventory_state.revision);
	}
	if (state->indexed_containers.count(InventoryKey{ p_runtime.id(), container }) != 0) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_NOT_INDEXED), &p_runtime, inventory_state.revision);
	}
	if (inventory_state.revision == std::numeric_limits<std::uint64_t>::max()) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED), &p_runtime, inventory_state.revision);
	}

	DiscoveryTask task;
	task.kind = DiscoveryTaskKind::CONTAINER_SEARCH;
	task.inventory = p_runtime.id();
	task.container = container;
	task.duration_ms = policy->container_search_duration_ms;

	DiscoveryIntentResult result;
	result.status = ok_status();
	result.accepted = true;
	result.inventory_revision = p_runtime.revision();
	result.task = task;
	if (policy->container_search_instant) {
		if (state->indexed_containers.size() >= MAX_DISCOVERY_INDEXED_CONTAINERS) {
			return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime, inventory_state.revision);
		}
		state->indexed_containers.insert(InventoryKey{ p_runtime.id(), container });
		result.completed = true;
	} else {
		state->task = task;
	}
	Status bump_status = bump_revision(*state, p_runtime.id());
	if (!bump_status.ok()) {
		return reject(bump_status, &p_runtime, inventory_state.revision);
	}
	result.discovery_revision = state->inventories.at(p_runtime.id()).revision;
	record_intent(*state, p_header.request_id, fingerprint, p_header.inventory, result);
	return result;
}

DiscoveryIntentResult DiscoveryStateStore::begin_item_scan(
		const InventoryRuntime &p_runtime,
		const DiscoveryIntentHeader &p_header,
		std::uint64_t p_entry_token) {
	RecipientState *state = find_recipient(p_header.recipient);
	if (state == nullptr) {
		return reject(make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN), &p_runtime);
	}
	const std::uint64_t fingerprint = intent_fingerprint(DiscoveryTaskKind::ITEM_SCAN, p_header, p_entry_token);
	bool duplicate = false;
	DiscoveryIntentResult replay = replay_or_mismatch(*state, p_header.request_id, fingerprint, duplicate);
	if (duplicate) {
		return replay;
	}
	if (p_header.request_id == 0 || !p_header.inventory || p_header.inventory != p_runtime.id()) {
		return reject(make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE), &p_runtime);
	}
	if (!can_record_intent(*state, p_header.request_id)) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime);
	}
	Status reconcile_status = reconcile(p_runtime);
	if (!reconcile_status.ok()) {
		return reject(reconcile_status, &p_runtime);
	}
	InventoryDiscoveryState &inventory_state = ensure_inventory_state(*state, p_runtime);
	if (p_header.expected_inventory_revision != p_runtime.revision()) {
		return reject(make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE), &p_runtime, inventory_state.revision);
	}
	if (p_header.expected_discovery_revision != inventory_state.revision) {
		return reject(make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::DISCOVERY_REVISION_STALE), &p_runtime, inventory_state.revision);
	}
	if (state->task.active()) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_BUSY), &p_runtime, inventory_state.revision);
	}
	const TokenBinding *binding = resolve_token(*state, p_entry_token, DiscoveryTokenKind::UNKNOWN_ITEM, p_runtime);
	if (binding == nullptr) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_TOKEN_INVALID), &p_runtime, inventory_state.revision);
	}
	const ContainerInstanceId container = binding->subject.container;
	const ItemInstanceId item = binding->subject.item;
	const ItemInstance *item_instance = p_runtime.find_item(item);
	if (item_instance == nullptr || location_container(item_instance->location) != container) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_TARGET_STALE), &p_runtime, inventory_state.revision);
	}
	if (state->indexed_containers.count(InventoryKey{ p_runtime.id(), container }) == 0) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_NOT_INDEXED), &p_runtime, inventory_state.revision);
	}
	const DiscoveryPolicyDefinition *policy = p_runtime.discovery_policy(container);
	if (policy == nullptr || !p_runtime.has_feature(FEATURE_DISCOVERY)) {
		return reject(make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::DISCOVERY_FEATURE_REQUIRED), &p_runtime, inventory_state.revision);
	}
	if (state->revealed_items.count(ItemKey{ p_runtime.id(), item }) != 0) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::DISCOVERY_TARGET_STALE), &p_runtime, inventory_state.revision);
	}
	if (inventory_state.revision == std::numeric_limits<std::uint64_t>::max()) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED), &p_runtime, inventory_state.revision);
	}

	DiscoveryTask task;
	task.kind = DiscoveryTaskKind::ITEM_SCAN;
	task.inventory = p_runtime.id();
	task.container = container;
	task.item = item;
	task.duration_ms = policy->item_scan_duration_ms;

	DiscoveryIntentResult result;
	result.status = ok_status();
	result.accepted = true;
	result.inventory_revision = p_runtime.revision();
	result.task = task;
	if (policy->item_scan_instant) {
		if (state->revealed_items.size() >= MAX_DISCOVERY_REVEALED_ITEMS) {
			return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime, inventory_state.revision);
		}
		state->revealed_items.insert(ItemKey{ p_runtime.id(), item });
		result.completed = true;
	} else {
		state->task = task;
	}
	Status bump_status = bump_revision(*state, p_runtime.id());
	if (!bump_status.ok()) {
		return reject(bump_status, &p_runtime, inventory_state.revision);
	}
	result.discovery_revision = state->inventories.at(p_runtime.id()).revision;
	record_intent(*state, p_header.request_id, fingerprint, p_header.inventory, result);
	return result;
}

DiscoveryIntentResult DiscoveryStateStore::cancel(
		const InventoryRuntime &p_runtime,
		const DiscoveryIntentHeader &p_header) {
	RecipientState *state = find_recipient(p_header.recipient);
	if (state == nullptr) {
		return reject(make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN), &p_runtime);
	}
	const std::uint64_t fingerprint = intent_fingerprint(DiscoveryTaskKind::NONE, p_header, 0);
	bool duplicate = false;
	DiscoveryIntentResult replay = replay_or_mismatch(*state, p_header.request_id, fingerprint, duplicate);
	if (duplicate) {
		return replay;
	}
	if (p_header.request_id == 0 || !p_header.inventory || p_header.inventory != p_runtime.id()) {
		return reject(make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE), &p_runtime);
	}
	if (!can_record_intent(*state, p_header.request_id)) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime);
	}
	Status reconcile_status = reconcile(p_runtime);
	if (!reconcile_status.ok()) {
		return reject(reconcile_status, &p_runtime);
	}
	InventoryDiscoveryState &inventory_state = ensure_inventory_state(*state, p_runtime);
	if (p_header.expected_inventory_revision != p_runtime.revision()) {
		return reject(make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE), &p_runtime, inventory_state.revision);
	}
	if (p_header.expected_discovery_revision != inventory_state.revision) {
		return reject(make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::DISCOVERY_REVISION_STALE), &p_runtime, inventory_state.revision);
	}
	if (!state->task.active() || state->task.inventory != p_runtime.id()) {
		return reject(make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_TASK_NOT_FOUND), &p_runtime, inventory_state.revision);
	}
	if (inventory_state.revision == std::numeric_limits<std::uint64_t>::max()) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED), &p_runtime, inventory_state.revision);
	}

	DiscoveryIntentResult result;
	result.status = ok_status();
	result.accepted = true;
	result.inventory_revision = p_runtime.revision();
	result.task = state->task;
	state->task = DiscoveryTask{};
	Status bump_status = bump_revision(*state, p_runtime.id());
	if (!bump_status.ok()) {
		return reject(bump_status, &p_runtime, inventory_state.revision);
	}
	result.discovery_revision = state->inventories.at(p_runtime.id()).revision;
	record_intent(*state, p_header.request_id, fingerprint, p_header.inventory, result);
	return result;
}

DiscoveryIntentResult DiscoveryStateStore::advance(
		const InventoryRuntime &p_runtime,
		DiscoveryRecipientKey p_recipient,
		std::uint32_t p_elapsed_ms) {
	RecipientState *state = find_recipient(p_recipient);
	if (state == nullptr) {
		return reject(make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN), &p_runtime);
	}
	Status reconcile_status = reconcile(p_runtime);
	if (!reconcile_status.ok()) {
		return reject(reconcile_status, &p_runtime);
	}
	InventoryDiscoveryState &inventory_state = ensure_inventory_state(*state, p_runtime);
	if (p_elapsed_ms == 0 || p_elapsed_ms > MAX_DISCOVERY_ADVANCE_MS) {
		return reject(make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DISCOVERY_ELAPSED_INVALID, p_elapsed_ms), &p_runtime, inventory_state.revision);
	}
	if (!state->task.active() || state->task.inventory != p_runtime.id()) {
		return reject(make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_TASK_NOT_FOUND), &p_runtime, inventory_state.revision);
	}
	if (inventory_state.revision == std::numeric_limits<std::uint64_t>::max()) {
		return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED), &p_runtime, inventory_state.revision);
	}

	DiscoveryTask completed_task = state->task;
	const std::uint32_t remaining = state->task.duration_ms - state->task.elapsed_ms;
	state->task.elapsed_ms += std::min(p_elapsed_ms, remaining);

	DiscoveryIntentResult result;
	result.status = ok_status();
	result.accepted = true;
	result.inventory_revision = p_runtime.revision();
	result.task = state->task;
	if (state->task.elapsed_ms == state->task.duration_ms) {
		result.completed = true;
		if (state->task.kind == DiscoveryTaskKind::CONTAINER_SEARCH) {
			if (state->indexed_containers.size() >= MAX_DISCOVERY_INDEXED_CONTAINERS) {
				state->task = completed_task;
				return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime, inventory_state.revision);
			}
			state->indexed_containers.insert(InventoryKey{ p_runtime.id(), state->task.container });
		} else {
			if (state->revealed_items.size() >= MAX_DISCOVERY_REVEALED_ITEMS) {
				state->task = completed_task;
				return reject(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED), &p_runtime, inventory_state.revision);
			}
			state->revealed_items.insert(ItemKey{ p_runtime.id(), state->task.item });
		}
		state->task = DiscoveryTask{};
	}
	Status bump_status = bump_revision(*state, p_runtime.id());
	if (!bump_status.ok()) {
		return reject(bump_status, &p_runtime, inventory_state.revision);
	}
	result.discovery_revision = state->inventories.at(p_runtime.id()).revision;
	return result;
}

} // namespace inv
