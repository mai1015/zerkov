#ifndef INVENTORY_SYSTEM_GODOT_AUTHORITY_H
#define INVENTORY_SYSTEM_GODOT_AUTHORITY_H

#include "core/inv_identity_authority.h"
#include "core/inv_discovery.h"
#include "core/inv_transaction.h"

#include "godot/inventory_catalog.h"
#include "godot/inventory_discovery_resources.h"
#include "godot/inventory_snapshot_resource.h"
#include "protocol/inv_observer_protocol.h"
#include "protocol/inv_protocol_types.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <map>
#include <memory>
#include <set>
#include <vector>

// The authoritative façade Node (tasks 7.1, 7.3, 7.4, 7.5; design.md "Godot
// façade and authoring"). Owns one shared `inv::IdentityAuthority`, one
// `inv::InventoryTransactionPipeline`, and every `inv::InventoryRuntime` this
// instance created or restored, keyed by inventory id. Every mutation goes
// through the pipeline's documented ordered phases (decode/resolve/revision/
// policy/structural/feature/simulate/invariant/commit/delta/notify) -- this
// class never mutates an `InventoryRuntime` directly.
//
// Role safety (7.3): `role` is an explicit, labeling-only property in V1.
// OFFLINE_AUTHORITY and SERVER_AUTHORITY differ in nothing this façade slice
// implements functionally -- both are full canonical authority over their
// owned runtimes, exactly like the core's own `PermissionProvider`/
// transaction pipeline make no OFFLINE-vs-SERVER distinction internally. The
// STRUCTURAL half of role safety -- "a remote replica cannot invoke
// authority-only mutation" -- is enforced by `InventoryReplicaNode`
// (native/godot/inventory_replica_node.h) simply never declaring a mutation
// method at all, not by a runtime role check on this class.
namespace godot {

class InventoryNetworkGateway;

class InventoryAuthority : public Node {
	GDCLASS(InventoryAuthority, Node)

public:
	enum Role {
		ROLE_OFFLINE_AUTHORITY = 0,
		ROLE_SERVER_AUTHORITY = 1,
	};

	InventoryAuthority();
	~InventoryAuthority() override;

	void set_role(Role p_role) { role = p_role; }
	Role get_role() const { return role; }

	// Immutable once this instance has built its transaction pipeline (i.e.
	// once any inventory has been created or restored) -- matches this
	// addon's "definitions become immutable for the session" convention.
	// Must reference an already-sealed `InventoryCatalog`.
	void set_catalog(const Ref<InventoryCatalog> &p_catalog);
	Ref<InventoryCatalog> get_catalog() const { return catalog_resource; }

	// The Status of the most recent operation that fails closed by returning
	// a bare int64/PackedByteArray (create_inventory, snapshot(),
	// session_hello_bytes(), ...) rather than a full result Dictionary --
	// lets a caller diagnose a 0/empty return without a second call.
	Dictionary get_last_status() const;

	// Instantiates `p_profile_identifier`'s root containers as a brand-new,
	// empty (revision 0) inventory. Returns the invalid id (0) and records a
	// diagnostic (get_last_status()) plus a push_error() on any failure:
	// catalog missing/unsealed, unknown profile identifier, or an aggregate
	// bound exceeded.
	int64_t create_inventory(const String &p_profile_identifier);
	bool has_inventory(int64_t p_inventory_id) const;
	// -1 if p_inventory_id is unknown.
	int64_t inventory_revision(int64_t p_inventory_id) const;
	// Synchronously tears down one live canonical inventory and all
	// inventory-scoped ephemeral/protocol state owned by this authority. The
	// corresponding remote replica nodes are independently owned; callers are
	// responsible for dropping those replicas after observing the signal.
	// Returns {ok:bool, status:Dictionary, inventory_id:int64}.
	Dictionary unload_inventory(int64_t p_inventory_id);

	// -- Typed command submission (one method per inv::Command alternative) --
	//
	// Every method below returns a result Dictionary: {accepted:bool,
	// replayed:bool, queued:bool, status:Dictionary{code,diagnostic,detail,ok},
	// command_id:int64, revisions:Array[Dictionary{inventory,predecessor,
	// successor}], events:Array[Dictionary{kind,item,secondary_item,
	// source_container,destination_container,reference}], new_item_id:int64,
	// new_reference_id:int64, dropped_external_owner:int64,
	// dropped_items:Array[Dictionary], transferred_quantity:int64,
	// remaining_quantity:int64, conflicting_inventory:int64,
	// authoritative_revision:int64} -- unused fields keep their zero/empty
	// default rather than being omitted, so every command's result Dictionary
	// shares one stable shape.
	//
	// p_actor identifies the submitting actor (game-scoped opaque identity,
	// never interpreted by the core itself). p_command_id <= 0 auto-allocates
	// the next command id from this instance's own monotonic counter; a
	// caller that needs idempotent retry supplies an explicit positive id.
	// Every expected revision is filled automatically from this façade's own
	// current runtime state (an ergonomic "submit against latest" default);
	// there is no explicit-stale-revision override in this slice -- a caller
	// that needs to test authoritative rejection drives the underlying
	// `inv::InventoryTransactionPipeline` directly in native tests instead.
	//
	// `destination`/`location` Dictionary parameters are shaped like
	// inventory_godot_util.h's `location_dict()`: {kind: "spatial"|"slot"|
	// "list", container:int64, x:int, y:int, rotated:bool,
	// slot_identifier:String, ordinal:int}.
	Dictionary move_item(int64_t p_inventory_id, int64_t p_item, const Dictionary &p_destination, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary rotate_item(int64_t p_inventory_id, int64_t p_item, bool p_rotated, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary split_stack(int64_t p_inventory_id, int64_t p_source, int64_t p_quantity, const Dictionary &p_destination, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary merge_stacks(int64_t p_inventory_id, int64_t p_source, int64_t p_destination_item, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary insert_item(int64_t p_inventory_id, const String &p_item_definition_identifier, int64_t p_quantity, const Dictionary &p_destination, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary remove_item(int64_t p_inventory_id, int64_t p_item, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary equip_item(int64_t p_inventory_id, int64_t p_item, int64_t p_destination_container, const String &p_slot_identifier, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary unequip_item(int64_t p_inventory_id, int64_t p_item, const Dictionary &p_destination, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary swap_items(int64_t p_inventory_id, int64_t p_item_a, int64_t p_item_b, int64_t p_actor = 0, int64_t p_command_id = 0);
	// destination_container == 0 (invalid) searches every eligible container
	// in the documented candidate order; a nonzero value restricts the
	// search to that one container (see inv::AutoPlaceItemCommand).
	Dictionary auto_place_item(int64_t p_inventory_id, int64_t p_item, int64_t p_destination_container = 0, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary quick_transfer_item(int64_t p_source_inventory_id, int64_t p_destination_inventory_id, int64_t p_item, bool p_allow_partial = false, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary transfer_item_to_provider(int64_t p_source_inventory_id, int64_t p_destination_inventory_id, int64_t p_item, int64_t p_destination_provider, int64_t p_actor = 0, int64_t p_command_id = 0);
	// Side-effect-free counterpart used for container-card hover feedback.
	// Returns {valid, status, destination_container, transferred_quantity,
	// conflicting_inventory, authoritative_revision}.
	Dictionary preview_transfer_item_to_provider(int64_t p_source_inventory_id, int64_t p_destination_inventory_id, int64_t p_item, int64_t p_destination_provider, int64_t p_actor = 0);
	Dictionary loot_item(int64_t p_source_inventory_id, int64_t p_destination_inventory_id, int64_t p_item, const Dictionary &p_destination_location, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary drop_item(int64_t p_inventory_id, int64_t p_item, int64_t p_external_owner, int64_t p_actor = 0, int64_t p_command_id = 0);
	// p_plan: Array[Dictionary{item:int64, disposition:String
	// ("retain"|"transfer_to"|"release_to"), destination:int64
	// (transfer_to), location:Dictionary (transfer_to), external_owner:int64
	// (release_to)}].
	Dictionary settle_inventory(int64_t p_inventory_id, const Array &p_plan, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary assign_reference(int64_t p_inventory_id, int64_t p_item, int64_t p_actor = 0, int64_t p_command_id = 0);
	Dictionary clear_reference(int64_t p_inventory_id, int64_t p_reference, int64_t p_actor = 0, int64_t p_command_id = 0);
	// Authority-approved mutable component mutations. These are ordinary
	// transactional commands: the pipeline applies permission, revision,
	// idempotency, invariant, delta, and notification handling exactly as it
	// does for movement and quantity commands.
	Dictionary set_item_component(
			int64_t p_inventory_id,
			int64_t p_item,
			const String &p_component_identifier,
			const PackedByteArray &p_payload,
			int64_t p_actor = 0,
			int64_t p_command_id = 0);
	Dictionary remove_item_component(
			int64_t p_inventory_id,
			int64_t p_item,
			const String &p_component_identifier,
			int64_t p_actor = 0,
			int64_t p_command_id = 0);

	// Authority-only prepared quantity participant. `container_priorities`
	// contains container-definition identifiers in source order (for the
	// extraction profile: pockets, rig, backpack). expected_revision < 0
	// means "the current authority revision". p_deadline_tick == 0 (the
	// default) means "never expires"; a nonzero value is an opaque caller
	// clock (see expire_quantity_reservation()) this façade never interprets.
	Dictionary prepare_quantity_reservation(
			int64_t p_inventory_id,
			const String &p_reservation_id,
			const String &p_required_trait,
			const Array &p_container_priorities,
			int64_t p_quantity,
			int64_t p_expected_revision = -1,
			int64_t p_deadline_tick = 0);
	Dictionary release_quantity_reservation(int64_t p_inventory_id, const String &p_reservation_id);
	Dictionary commit_quantity_reservation_silent(int64_t p_inventory_id, const String &p_reservation_id);
	Dictionary rollback_quantity_reservation(int64_t p_inventory_id, const String &p_reservation_id);
	Dictionary publish_quantity_reservation(const String &p_reservation_id);
	// Bounded, deadline-compatible expiry/teardown (inventory-transactions
	// delta, "Ephemeral Reservation Lifecycle"): a no-op
	// (RESERVATION_NOT_DUE) unless the reservation's own deadline_tick is
	// nonzero and p_current_tick has reached it. Idempotent past that point.
	Dictionary expire_quantity_reservation(int64_t p_inventory_id, const String &p_reservation_id, int64_t p_current_tick);
	// Explicit, non-mutating health diagnostics -- safe to poll without an
	// InventoryRuntime id (unlike every mutating method above).
	Dictionary health_quantity_reservation(const String &p_reservation_id) const;
	int64_t active_quantity_reservation_count() const;

	// -- Remote intent submission (7.6 carried-over fix a) --
	//
	// Decodes p_bytes as a `protocol::CommandEnvelope` (protocol/
	// inv_protocol_codec.h) and submits it through `pipeline` using the
	// ENVELOPE'S OWN CommandHeader verbatim -- command id, actor, and every
	// client-declared expected revision -- unlike every typed command method
	// above, which always recomputes its header's expected revision from this
	// façade's own current runtime state (see those methods' class-comment
	// caveat). This is therefore the one entry point on this façade that
	// exercises the real revision protocol end to end: a caller can encode a
	// deliberately stale expected revision and observe an authoritative
	// REVISION_MISMATCH rejection come back through the normal result-
	// Dictionary shape. Every inventory named by the envelope's expected
	// revisions must already exist on this authority (multi-inventory
	// envelopes route through the same `pipeline->submit(vector<...>, ...)`
	// overload `submit_multi()` uses). Malformed bytes (decode failure) or an
	// unknown inventory id fail closed with a clean error result Dictionary
	// (get_last_status() reports the same Status) -- never a crash.
	//
	// Result shape: the normal command-result Dictionary (see the typed
	// command methods' doc comment above) PLUS one extra key, "result_bytes"
	// (PackedByteArray) -- the reply `protocol::ResultEnvelope`, canonically
	// encoded, ready for a caller to hand back across whatever transport
	// carried the original command bytes. "result_bytes" is empty when the
	// envelope failed to decode or named an unknown inventory (there is no
	// TransactionResult to encode) and, in the unlikely event the encode step
	// itself fails, is empty even though the Dictionary's other fields still
	// describe a real (accepted/rejected/queued) outcome.
	Dictionary submit_command_bytes(const PackedByteArray &p_bytes);

	// TEST-ONLY (7.6): encodes a single-inventory MoveItemCommand
	// `protocol::CommandEnvelope` with a CALLER-SUPPLIED (possibly stale)
	// expected revision, so a headless test can exercise
	// submit_command_bytes()'s real revision-protocol path -- including
	// REVISION_MISMATCH -- without a second live peer to source genuine wire
	// bytes from. This is NOT part of the addon's production public surface:
	// a real remote client builds and encodes its own CommandEnvelope off-box
	// using its own copy of the protocol codec; this method exists solely
	// because no other GDScript-reachable CommandEnvelope encoder exists in
	// this slice. p_command_id <= 0 auto-allocates from this instance's own
	// monotonic counter, exactly like every typed command method above.
	// Empty on encode failure.
	PackedByteArray encode_move_command_bytes_for_test(int64_t p_inventory_id, int64_t p_item, const Dictionary &p_destination, int64_t p_expected_revision, int64_t p_actor = 0, int64_t p_command_id = 0);

	// TEST-ONLY: encodes a bounded cross-inventory QuickTransferItemCommand
	// with caller-supplied source/destination revisions for the authenticated
	// gateway contract suite. This is not part of the production command API;
	// real remote clients encode their own protocol envelope off-box.
	PackedByteArray encode_quick_transfer_command_bytes_for_test(
			int64_t p_source_inventory_id,
			int64_t p_destination_inventory_id,
			int64_t p_item,
			bool p_allow_partial,
			int64_t p_source_expected_revision,
			int64_t p_destination_expected_revision,
			int64_t p_actor = 0,
			int64_t p_command_id = 0);

	// -- Snapshot / delta / protocol access (7.4) --

	// Null on failure (unknown inventory id, encode failure) with a
	// push_error() and get_last_status() set.
	//
	// Visibility projection (7.6 carried-over fix b; protocol/inv_visibility.h):
	// p_visibility == VISIBILITY_OWNER returns the runtime's full canonical
	// content verbatim, exactly as before. Every other scope now runs
	// `inv::protocol::project_snapshot()` over the OWNER-scope snapshot before
	// this method ever builds the returned Resource, so REDACTED/OBSERVER
	// snapshots actually strip content at this façade rather than merely
	// tagging `visibility` (see inventory_authority.cpp for the exact
	// per-scope ProjectionPolicy this method builds and why). A projected
	// (non-OWNER) InventorySnapshotResource can still be inspected freely but
	// is refused by core::restore() as canonical state (core/inv_snapshot.cpp),
	// matching every other non-OWNER snapshot in this addon.
	Ref<InventorySnapshotResource> snapshot(int64_t p_inventory_id, int64_t p_visibility = InventorySnapshotResource::VISIBILITY_OWNER) const;
	// Encodes a complete owner-only `protocol::SnapshotEnvelope` for
	// p_inventory_id -- the wire form `InventoryReplicaNode.apply_snapshot_bytes()`
	// decodes. Non-owner visibility is rejected because this canonical envelope
	// carries raw IDs/allocator metadata; use observer_snapshot_envelope_bytes()
	// for recipient-safe observer transport. Empty on failure (unknown
	// inventory id, non-owner role, or encode failure) with a push_error().
	PackedByteArray snapshot_envelope_bytes(int64_t p_inventory_id, int64_t p_visibility = InventorySnapshotResource::VISIBILITY_OWNER) const;
	// Recipient-bound observer transport.  These methods are the only
	// authority path for a redacted observer replica: policy is applied to the
	// complete current runtime before encoding, and every stream is bound to
	// {session, actor, inventory, visibility, generation}.  The delta is a
	// complete projected replacement view, never a filtered canonical DeltaBatch.
	PackedByteArray observer_snapshot_envelope_bytes(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_visibility = InventorySnapshotResource::VISIBILITY_OBSERVER) const;
	PackedByteArray observer_delta_bytes(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_predecessor_sequence) const;
	// The canonical delta batch produced by the most recent ACCEPTED
	// transaction with a non-empty delta set (also carried by the
	// `delta_ready` signal); empty before any such transaction has run.
	PackedByteArray last_delta_batch_bytes() const { return last_delta_batch_bytes_value; }
	PackedByteArray session_hello_bytes() const;
	PackedByteArray make_persistence_record(int64_t p_inventory_id) const;
	// Decodes and installs p_bytes, keyed by the record's own encoded
	// inventory id. A live-id collision fails atomically by default;
	// p_replace_existing=true is the explicit live-replacement operation.
	// {ok:bool, status:Dictionary, inventory_id:int64}.
	Dictionary apply_persistence_record(const PackedByteArray &p_bytes, bool p_replace_existing = false);

	// -- Recipient-bound staged discovery --
	//
	// The game authenticates session_id/actor_id before entering this façade.
	// Registration allocates an authority-owned opaque-token sequence; callers
	// never submit token seeds or hidden identities. Session/recipient teardown
	// destroys tasks, idempotency entries, tokens, and learned contents.
	Dictionary register_discovery_recipient(int64_t p_session_id, int64_t p_actor_id);
	Dictionary teardown_discovery_recipient(int64_t p_session_id, int64_t p_actor_id);
	Dictionary teardown_discovery_session(int64_t p_session_id);
	Dictionary revoke_discovery_inventory(int64_t p_session_id, int64_t p_actor_id, int64_t p_inventory_id);
	int64_t discovery_revision(int64_t p_session_id, int64_t p_actor_id, int64_t p_inventory_id) const;

	// Untrusted begin/cancel intents. Negative expected revisions mean "use
	// the authority's current value"; explicit non-negative values exercise
	// the real stale-revision path. request_id <= 0 allocates a monotonic
	// authority-local request identity.
	Ref<InventoryDiscoveryResultResource> begin_container_search(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_container_token,
			int64_t p_request_id = 0,
			int64_t p_expected_inventory_revision = -1,
			int64_t p_expected_discovery_revision = -1);
	Ref<InventoryDiscoveryResultResource> begin_item_scan(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_entry_token,
			int64_t p_request_id = 0,
			int64_t p_expected_inventory_revision = -1,
			int64_t p_expected_discovery_revision = -1);
	Ref<InventoryDiscoveryResultResource> cancel_discovery(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_request_id = 0,
			int64_t p_expected_inventory_revision = -1,
			int64_t p_expected_discovery_revision = -1);

	// Trusted server/offline progression. This is the sole script-facing
	// completion path: there is deliberately no complete/reveal method.
	Ref<InventoryDiscoveryResultResource> advance_discovery(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_elapsed_ms);

	// Full recipient-safe replacement view and explicit predecessor/successor
	// delta. These own copies and cannot mutate authority state.
	Ref<InventoryDiscoverySnapshotResource> discovery_view(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id);
	PackedByteArray discovery_view_bytes(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id);
	Ref<InventoryDiscoveryDeltaResource> discovery_delta(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_predecessor_inventory_revision,
			int64_t p_predecessor_discovery_revision);
	PackedByteArray discovery_delta_bytes(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_predecessor_inventory_revision,
			int64_t p_predecessor_discovery_revision);
	PackedByteArray discovery_hello_bytes() const;

	// Privacy-safe derived queries. They fail with
	// DISCOVERY_QUERY_REDACTED until the named container is indexed.
	Dictionary discovery_count_in_container(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_container_id) const;
	Dictionary discovery_layout_kind(
			int64_t p_session_id,
			int64_t p_actor_id,
			int64_t p_inventory_id,
			int64_t p_container_id) const;

	// -- Derived queries (7.4) --
	//
	// Every query below returns {ok:bool, status:Dictionary, ...value...},
	// explicit about unavailability (unknown inventory/container, or a
	// capacity feature the profile does not enable) rather than inventing 0
	// or infinite (inventory-runtime spec, "Deterministic Derived Queries").
	Dictionary total_mass(int64_t p_inventory_id) const;
	Dictionary container_mass(int64_t p_inventory_id, int64_t p_container_id) const;
	Dictionary container_mass_capacity(int64_t p_inventory_id, int64_t p_container_id) const;
	Dictionary count_in_container(int64_t p_inventory_id, int64_t p_container_id) const;
	Dictionary remaining_count_capacity(int64_t p_inventory_id, int64_t p_container_id) const;
	Dictionary fits(int64_t p_inventory_id, const String &p_item_definition_identifier, const Dictionary &p_destination, int64_t p_quantity = 1, int64_t p_excluding_item = 0) const;
	bool has_feature(int64_t p_inventory_id, const String &p_feature_identifier) const;

protected:
	static void _bind_methods();

private:
	friend class InventoryNetworkGateway;

	// Builds `pipeline` (once, lazily) and registers the post-commit observer
	// that emits `transaction_committed`/`delta_ready`. False (leaving
	// `pipeline` untouched) if `catalog_resource` is not yet a sealed
	// InventoryCatalog.
	bool ensure_pipeline();
	inv::InventoryRuntime *runtime_for(int64_t p_inventory_id);
	const inv::InventoryRuntime *runtime_for(int64_t p_inventory_id) const;
	// Deduplicated, ascending-order copy of p_ids (InventoryTransactionPipeline
	// itself tolerates an unsorted/duplicate touched list for a multi-command,
	// but header.expected_revisions must be an exact bijection with the
	// touched set -- deduping once here keeps every call site correct).
	static std::vector<inv::InventoryId> unique_sorted(std::vector<inv::InventoryId> p_ids);
	inv::CommandHeader make_header(const std::vector<inv::InventoryId> &p_touched, int64_t p_actor, int64_t p_command_id);
	// The gateway and all trusted local helpers share this one monotonic command
	// identity domain.  Zero means the script-safe positive int64 space is
	// exhausted; a caller must fail closed instead of wrapping or reusing an id.
	inv::CommandId allocate_canonical_command_id();
	void observe_explicit_command_id(inv::CommandId p_command_id);
	inv::TransactionResult execute_gateway_command(const inv::protocol::CommandEnvelope &p_envelope);
	Dictionary submit_decoded_command_envelope(const inv::protocol::CommandEnvelope &p_envelope);
	inv::CommandHeader make_preview_header(const std::vector<inv::InventoryId> &p_touched, int64_t p_actor) const;
	Dictionary submit_single(int64_t p_inventory_id, const inv::Command &p_command, int64_t p_actor, int64_t p_command_id);
	Dictionary submit_multi(const std::vector<inv::InventoryId> &p_touched, const inv::Command &p_command, int64_t p_actor, int64_t p_command_id);
	Dictionary result_dict(const inv::TransactionResult &p_result) const;
	Dictionary targeted_provider_preview_dict(const inv::TargetedProviderTransferPreview &p_preview) const;
	Dictionary quantity_result_dict(const inv::QuantityReservationResult &p_result) const;
	Dictionary error_result_dict(const inv::Status &p_status);
	Dictionary query_error(const inv::Status &p_status) const;
	Dictionary lifecycle_result_dict(int64_t p_inventory_id, const inv::Status &p_status, bool p_ok);
	void clear_inventory_scoped_state(inv::InventoryId p_inventory);

	struct SignalEmissionScope {
		InventoryAuthority &authority;
		explicit SignalEmissionScope(InventoryAuthority &p_authority) : authority(p_authority) {
			++authority.signal_emission_depth;
		}
		~SignalEmissionScope() {
			if (authority.signal_emission_depth != 0) {
				--authority.signal_emission_depth;
			}
		}
	};
	static bool discovery_recipient_from_args(int64_t p_session_id, int64_t p_actor_id, inv::DiscoveryRecipientKey &r_recipient);
	inv::DiscoveryIntentHeader make_discovery_header(
			inv::DiscoveryRecipientKey p_recipient,
			const inv::InventoryRuntime &p_runtime,
			int64_t p_request_id,
			int64_t p_expected_inventory_revision,
			int64_t p_expected_discovery_revision);
	Ref<InventoryDiscoveryResultResource> discovery_result_resource(
			std::uint64_t p_request_id,
			const inv::DiscoveryIntentResult &p_result);
	Ref<InventoryDiscoveryResultResource> discovery_error_resource(
			std::uint64_t p_request_id,
			const inv::Status &p_status,
			const inv::InventoryRuntime *p_runtime = nullptr,
			std::uint64_t p_discovery_revision = 0);
	inv::Status build_discovery_view_envelope(
			inv::DiscoveryRecipientKey p_recipient,
			const inv::InventoryRuntime &p_runtime,
			inv::protocol::DiscoveryViewEnvelope &r_envelope);
	inv::Status build_discovery_delta_envelope(
			inv::DiscoveryRecipientKey p_recipient,
			const inv::InventoryRuntime &p_runtime,
			std::uint64_t p_predecessor_inventory_revision,
			std::uint64_t p_predecessor_discovery_revision,
			inv::protocol::DiscoveryDeltaEnvelope &r_envelope);
	void reconcile_discovery_after_transaction(const inv::TransactionResult &p_result);

	// Post-commit observer body (invoked only after the ObjectID guard in
	// ensure_pipeline()'s lambda confirms this instance is still alive).
	void on_transaction_result(const inv::TransactionResult &p_result);
	void on_quantity_reservation_published(const inv::PreparedQuantityCommit &p_commit);

	// Shared by snapshot()/snapshot_envelope_bytes() (7.6 carried-over fix b):
	// builds the OWNER-scope snapshot via inv::snapshot(), then, for
	// p_scope != OWNER, runs inv::protocol::project_snapshot() over it before
	// returning. Per-scope ProjectionPolicy (documented in full at the .cpp
	// definition): OBSERVER uses derive_default_policy()'s INSPECT-access-bit
	// rule (a container a game marked inspectable stays PUBLIC; every other
	// container is REDACTED); REDACTED uses a default-constructed
	// ProjectionPolicy{} -- default_visibility == REDACTED, no per-container
	// overrides -- so REDACTED unconditionally strips every container's
	// direct item content regardless of that container's own access mask,
	// matching DESIGN.md's `inventory.design.color.redacted` ("hidden/unknown
	// content") semantic rather than the finer-grained, policy-driven OBSERVER
	// scope.
	inv::Status build_visible_snapshot(const inv::InventoryRuntime &p_runtime, inv::VisibilityScope p_scope, inv::InventorySnapshot &r_out) const;
	struct ObserverViewState;
	inv::Status build_observer_snapshot(
			const inv::InventoryRuntime &p_runtime,
			inv::DiscoveryRecipientKey p_recipient,
			inv::VisibilityScope p_scope,
			std::uint64_t p_generation,
			std::uint64_t p_sequence,
			ObserverViewState &r_stream,
			inv::protocol::ObserverSnapshot &r_out) const;

	struct ObserverViewKey {
		inv::DiscoveryRecipientKey recipient;
		inv::InventoryId inventory;

		bool operator<(const ObserverViewKey &p_other) const {
			if (recipient < p_other.recipient) {
				return true;
			}
			if (p_other.recipient < recipient) {
				return false;
			}
			return inventory.value < p_other.inventory.value;
		}
	};

	struct ObserverViewState {
		inv::protocol::ObserverSnapshot view;
		std::map<std::uint64_t, std::uint64_t> opaque_container_ids;
		std::uint64_t next_opaque_container_id = inv::protocol::OBSERVER_OPAQUE_CONTAINER_START;
		std::map<std::uint64_t, std::uint64_t> opaque_item_ids;
		std::uint64_t next_opaque_item_id = inv::protocol::OBSERVER_OPAQUE_ITEM_START;
	};

	Role role = ROLE_OFFLINE_AUTHORITY;
	Ref<InventoryCatalog> catalog_resource;

	inv::IdentityAuthority identity_authority;
	// AllowAllPermissionProvider (default-allow): this façade slice exposes
	// no game-owned permission-policy seam yet -- a later slice may add one
	// without changing this class's public method surface.
	inv::AllowAllPermissionProvider permissions;
	std::unique_ptr<inv::PreparedQuantityReservations> quantity_reservations;
	std::unique_ptr<inv::InventoryTransactionPipeline> pipeline;

	std::map<int64_t, inv::InventoryRuntime> runtimes;
	inv::HandleAllocator<inv::InventoryId> inventory_id_allocator;
	std::uint64_t next_command_id = 1;
	inv::DiscoveryStateStore discovery_store;
	std::set<inv::DiscoveryRecipientKey> discovery_recipients;
	std::uint64_t next_discovery_token_seed = 0x100000000ULL;
	std::uint64_t next_discovery_request_id = 1;

	mutable inv::Status last_status;
	PackedByteArray last_delta_batch_bytes_value;
	std::set<inv::InventoryId> last_delta_batch_inventories;
	mutable std::map<ObserverViewKey, ObserverViewState> observer_views;
	// Per-recipient epochs survive inventory unload/revoke and recipient
	// teardown. A reconnect with the same key therefore cannot reuse a delayed
	// packet's generation, while one recipient's stream churn is invisible to
	// every other recipient.
	mutable std::map<inv::DiscoveryRecipientKey, std::uint64_t> observer_generation_epochs;
	std::uint32_t signal_emission_depth = 0;
};

} // namespace godot

VARIANT_ENUM_CAST(InventoryAuthority::Role);

#endif // INVENTORY_SYSTEM_GODOT_AUTHORITY_H
