#ifndef INVENTORY_SYSTEM_CORE_IDS_H
#define INVENTORY_SYSTEM_CORE_IDS_H

#include "core/inv_status.h"

#include <cstdint>

namespace inv {

// Runtime handles are phantom-tagged so unrelated identity domains cannot be
// mixed accidentally. Zero is always invalid. Authority-issued allocation is
// monotonic within the documented scope and the counter is snapshot state.
template <typename Tag>
struct Handle {
	std::uint64_t value = 0;

	constexpr explicit operator bool() const { return value != 0; }
	bool operator==(const Handle &p_other) const { return value == p_other.value; }
	bool operator!=(const Handle &p_other) const { return value != p_other.value; }
	bool operator<(const Handle &p_other) const { return value < p_other.value; }
};

struct InventoryIdTag {};
struct ContainerInstanceIdTag {};
struct ItemInstanceIdTag {};
struct StackIdTag {};
struct SlotIdTag {};
struct CommandIdTag {};
struct TransactionIdTag {};
struct ReferenceIdTag {};
struct ExternalOwnerIdTag {};

using InventoryId = Handle<InventoryIdTag>;
using ContainerInstanceId = Handle<ContainerInstanceIdTag>;
using ItemInstanceId = Handle<ItemInstanceIdTag>;
using StackId = Handle<StackIdTag>;
using SlotId = Handle<SlotIdTag>;
using CommandId = Handle<CommandIdTag>;
using TransactionId = Handle<TransactionIdTag>;
using ReferenceId = Handle<ReferenceIdTag>;
using ExternalOwnerId = Handle<ExternalOwnerIdTag>;

template <typename T>
class HandleAllocator {
public:
	// On exhaustion of the 64-bit space, returns the invalid (zero) handle; callers must check validity.
	T allocate() {
		if (next == UINT64_MAX) {
			return T{};
		}
		++next;
		return T{ next };
	}

	std::uint64_t next_raw() const { return next; }

	Status restore_from(std::uint64_t p_value) {
		if (p_value < next) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::CANONICAL_ORDER_VIOLATION, p_value);
		}
		next = p_value;
		return ok_status();
	}

private:
	std::uint64_t next = 0;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_IDS_H
