#ifndef INVENTORY_SYSTEM_CORE_DISCOVERY_H
#define INVENTORY_SYSTEM_CORE_DISCOVERY_H

#include "core/inv_ids.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"

#include <cstdint>
#include <map>
#include <set>

namespace inv {

// Authenticated authority scope. Neither value is a presentation identifier;
// the game/server binds them to its own session and actor authentication.
struct DiscoveryRecipientKey {
	std::uint64_t session_id = 0;
	std::uint64_t actor_id = 0;

	bool operator<(const DiscoveryRecipientKey &p_other) const {
		return session_id < p_other.session_id ||
				(session_id == p_other.session_id && actor_id < p_other.actor_id);
	}
	bool operator==(const DiscoveryRecipientKey &p_other) const {
		return session_id == p_other.session_id && actor_id == p_other.actor_id;
	}
};

enum class DiscoveryContainerStage : std::uint8_t {
	UNSEARCHED = 1,
	SEARCHING = 2,
	INDEXED = 3,
};

enum class DiscoveryEntryStage : std::uint8_t {
	UNKNOWN = 1,
	SCANNING = 2,
};

enum class DiscoveryTaskKind : std::uint8_t {
	NONE = 0,
	CONTAINER_SEARCH = 1,
	ITEM_SCAN = 2,
};

enum class DiscoveryTokenKind : std::uint8_t {
	CONTAINER_SHELL = 1,
	UNKNOWN_ITEM = 2,
};

struct DiscoveryTask {
	DiscoveryTaskKind kind = DiscoveryTaskKind::NONE;
	InventoryId inventory;
	ContainerInstanceId container;
	ItemInstanceId item;
	std::uint32_t elapsed_ms = 0;
	std::uint32_t duration_ms = 0;

	bool active() const { return kind != DiscoveryTaskKind::NONE; }
};

struct DiscoveryIntentHeader {
	DiscoveryRecipientKey recipient;
	std::uint64_t request_id = 0;
	InventoryId inventory;
	std::uint64_t expected_inventory_revision = 0;
	std::uint64_t expected_discovery_revision = 0;
};

struct DiscoveryIntentResult {
	Status status;
	bool accepted = false;
	bool replayed = false;
	bool completed = false;
	std::uint64_t inventory_revision = 0;
	std::uint64_t discovery_revision = 0;
	DiscoveryTask task;
};

// Engine-independent authority state for staged disclosure. It intentionally
// owns no clock: trusted server/offline coordinators advance checked elapsed
// milliseconds explicitly. Canonical inventory state is read-only here, so
// search/scan progress cannot change inventory revisions or hashes.
class DiscoveryStateStore {
public:
	// p_token_seed is authority-provided entropy/sequence state. Tokens are
	// allocated monotonically from it and stored in recipient-local bindings;
	// they are never hashes or encodings of canonical item/container ids.
	Status register_recipient(DiscoveryRecipientKey p_recipient, std::uint64_t p_token_seed);
	void teardown_recipient(DiscoveryRecipientKey p_recipient);
	void teardown_session(std::uint64_t p_session_id);

	// Reconciles one inventory after canonical mutation. Removed/stale targets
	// cancel their task; surviving knowledge remains; newly-created items are
	// unknown. A canonical revision change advances the separate discovery
	// revision and rotates that inventory's opaque token bindings.
	Status reconcile(const InventoryRuntime &p_runtime);

	// Explicit transfer hook preserves already-revealed identity knowledge
	// when an authority transfers the same stable item id between inventories.
	Status transfer_revealed_item(
			const InventoryRuntime &p_source,
			const InventoryRuntime &p_destination,
			ItemInstanceId p_item);

	// Access/relevance loss is game-owned policy. Revocation drops all
	// recipient knowledge and active work for the named inventory.
	Status revoke_inventory_access(DiscoveryRecipientKey p_recipient, InventoryId p_inventory);
	// Drops all recipient-local knowledge, tokens, active work, and cached
	// intents for one inventory while preserving every unrelated inventory and
	// recipient registration. Used by authority unload/replacement teardown.
	std::size_t clear_inventory(InventoryId p_inventory);

	DiscoveryIntentResult begin_container_search(
			const InventoryRuntime &p_runtime,
			const DiscoveryIntentHeader &p_header,
			std::uint64_t p_container_token);
	DiscoveryIntentResult begin_item_scan(
			const InventoryRuntime &p_runtime,
			const DiscoveryIntentHeader &p_header,
			std::uint64_t p_entry_token);
	DiscoveryIntentResult cancel(
			const InventoryRuntime &p_runtime,
			const DiscoveryIntentHeader &p_header);

	// Authority-only progression. There is deliberately no client completion
	// method. p_elapsed_ms must be within the compiled hard bound.
	DiscoveryIntentResult advance(
			const InventoryRuntime &p_runtime,
			DiscoveryRecipientKey p_recipient,
			std::uint32_t p_elapsed_ms);

	Status discovery_revision(
			DiscoveryRecipientKey p_recipient,
			InventoryId p_inventory,
			std::uint64_t &r_revision) const;
	Status container_stage(
			DiscoveryRecipientKey p_recipient,
			InventoryId p_inventory,
			ContainerInstanceId p_container,
			DiscoveryContainerStage &r_stage) const;
	bool item_revealed(
			DiscoveryRecipientKey p_recipient,
			InventoryId p_inventory,
			ItemInstanceId p_item) const;
	Status active_task(DiscoveryRecipientKey p_recipient, DiscoveryTask &r_task) const;

	// Projection-only token issuance. Repeated issuance for the same subject
	// at the same inventory/discovery revision returns the same token.
	Status issue_container_token(
			DiscoveryRecipientKey p_recipient,
			InventoryId p_inventory,
			std::uint64_t p_inventory_revision,
			ContainerInstanceId p_container,
			std::uint64_t &r_token);
	Status issue_item_token(
			DiscoveryRecipientKey p_recipient,
			InventoryId p_inventory,
			std::uint64_t p_inventory_revision,
			ContainerInstanceId p_container,
			ItemInstanceId p_item,
			std::uint64_t &r_token);

private:
	struct InventoryKey {
		InventoryId inventory;
		ContainerInstanceId container;

		bool operator<(const InventoryKey &p_other) const {
			return inventory < p_other.inventory ||
					(inventory == p_other.inventory && container < p_other.container);
		}
	};

	struct ItemKey {
		InventoryId inventory;
		ItemInstanceId item;

		bool operator<(const ItemKey &p_other) const {
			return inventory < p_other.inventory ||
					(inventory == p_other.inventory && item < p_other.item);
		}
	};

	struct TokenSubject {
		DiscoveryTokenKind kind = DiscoveryTokenKind::CONTAINER_SHELL;
		InventoryId inventory;
		ContainerInstanceId container;
		ItemInstanceId item;

		bool operator<(const TokenSubject &p_other) const;
	};

	struct TokenBinding {
		TokenSubject subject;
		std::uint64_t inventory_revision = 0;
		std::uint64_t discovery_revision = 0;
	};

	struct InventoryDiscoveryState {
		std::uint64_t observed_inventory_revision = 0;
		std::uint64_t revision = 0;
	};

	struct CachedIntent {
		std::uint64_t fingerprint = 0;
		InventoryId inventory;
		DiscoveryIntentResult result;
	};

	struct RecipientState {
		std::uint64_t token_seed = 0;
		std::uint64_t next_token = 0;
		std::map<InventoryId, InventoryDiscoveryState> inventories;
		std::set<InventoryKey> indexed_containers;
		std::set<ItemKey> revealed_items;
		DiscoveryTask task;
		std::map<std::uint64_t, CachedIntent> idempotency;
		std::map<std::uint64_t, TokenBinding> token_bindings;
		std::map<TokenSubject, std::uint64_t> tokens_by_subject;
	};

	std::map<DiscoveryRecipientKey, RecipientState> recipients_;

	RecipientState *find_recipient(DiscoveryRecipientKey p_recipient);
	const RecipientState *find_recipient(DiscoveryRecipientKey p_recipient) const;
	InventoryDiscoveryState &ensure_inventory_state(RecipientState &r_state, const InventoryRuntime &p_runtime);
	const InventoryDiscoveryState *find_inventory_state(const RecipientState &p_state, InventoryId p_inventory) const;

	static std::uint64_t intent_fingerprint(
			DiscoveryTaskKind p_kind,
			const DiscoveryIntentHeader &p_header,
			std::uint64_t p_token);
	static DiscoveryIntentResult reject(Status p_status, const InventoryRuntime *p_runtime = nullptr, std::uint64_t p_discovery_revision = 0);
	static bool task_target_valid(const RecipientState &p_state, const InventoryRuntime &p_runtime);
	static bool can_record_intent(const RecipientState &p_state, std::uint64_t p_request_id);

	Status bump_revision(RecipientState &r_state, InventoryId p_inventory);
	bool clear_inventory_state(RecipientState &r_state, InventoryId p_inventory);
	void clear_tokens_for_inventory(RecipientState &r_state, InventoryId p_inventory);
	Status issue_token(
			RecipientState &r_state,
			const TokenSubject &p_subject,
			std::uint64_t p_inventory_revision,
			std::uint64_t &r_token);
	const TokenBinding *resolve_token(
			const RecipientState &p_state,
			std::uint64_t p_token,
			DiscoveryTokenKind p_kind,
			const InventoryRuntime &p_runtime) const;
	DiscoveryIntentResult replay_or_mismatch(
			const RecipientState &p_state,
			std::uint64_t p_request_id,
			std::uint64_t p_fingerprint,
			bool &r_found) const;
	void record_intent(
			RecipientState &r_state,
			std::uint64_t p_request_id,
			std::uint64_t p_fingerprint,
			InventoryId p_inventory,
			const DiscoveryIntentResult &p_result);
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_DISCOVERY_H
