#include "core/ga_transaction.h"

namespace ga {

Status NotificationQueue::enqueue(std::function<void()> p_record) {
	if (pending_records.size() >= MAX_QUEUED_NOTIFICATIONS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, pending_records.size());
	}
	pending_records.push_back(std::move(p_record));
	return ok_status();
}

void NotificationQueue::dispatch() {
	if (dispatching || is_holding()) {
		// Reentrant dispatch is never allowed; a defensive no-op keeps this
		// class safe even if a caller mistakenly calls dispatch() from
		// within a record it is currently running.
		return;
	}
	dispatching = true;

	// Move to a local buffer first so any request_mutation()/enqueue() call
	// made by a record lands in a fresh buffer for the *next* dispatch, not
	// this one -- dispatch() only ever runs the records that existed when it
	// began.
	std::vector<std::function<void()>> to_run;
	to_run.swap(pending_records);
	for (auto &record : to_run) {
		if (record) {
			record();
		}
	}

	dispatching = false;
}

Status NotificationQueue::request_mutation(std::function<void()> p_request) {
	if (pending_requests.size() >= MAX_PENDING_MUTATION_REQUESTS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, pending_requests.size());
	}
	pending_requests.push_back(std::move(p_request));
	return ok_status();
}

std::vector<std::function<void()>> NotificationQueue::take_pending_requests() {
	std::vector<std::function<void()>> taken;
	taken.swap(pending_requests);
	return taken;
}

Status NotificationQueue::begin_hold() {
	if (hold_markers.size() >= MAX_NOTIFICATION_HOLD_DEPTH) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::STACK_LIMIT_REACHED, hold_markers.size());
	}
	hold_markers.push_back(
			HoldMarker{ pending_records.size(), pending_requests.size() });
	return ok_status();
}

Status NotificationQueue::commit_hold() {
	if (hold_markers.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER);
	}
	hold_markers.pop_back();
	return ok_status();
}

Status NotificationQueue::rollback_hold() {
	if (hold_markers.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER);
	}
	const HoldMarker marker = hold_markers.back();
	hold_markers.pop_back();
	pending_records.resize(marker.record_count);
	pending_requests.resize(marker.request_count);
	return ok_status();
}

Status Transaction::add_undo(std::function<void()> p_undo) {
	if (undo_ops.size() >= MAX_TRANSACTION_UNDO_OPS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, undo_ops.size());
	}
	undo_ops.push_back(std::move(p_undo));
	return ok_status();
}

Status Transaction::add_notification(std::function<void()> p_notify) {
	if (notify_ops.size() >= MAX_TRANSACTION_NOTIFICATIONS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, notify_ops.size());
	}
	notify_ops.push_back(std::move(p_notify));
	return ok_status();
}

void Transaction::fail(Status p_status) {
	if (failure.ok() && !p_status.ok()) {
		failure = p_status;
	}
}

Status Transaction::commit(NotificationQueue &p_queue) {
	if (failed()) {
		rollback();
		return failure;
	}
	if (!p_queue.can_enqueue(notify_ops.size())) {
		const Status status = make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, notify_ops.size());
		rollback();
		return status;
	}

	for (auto &notify : notify_ops) {
		const Status status = p_queue.enqueue(std::move(notify));
		if (!status.ok()) {
			// The queue itself is bounded and full; the transaction's state
			// changes already committed logically (undo_ops is about to be
			// discarded below), but we surface the drop so callers know a
			// notification did not make it to dispatch.
			notify_ops.clear();
			undo_ops.clear();
			return status;
		}
	}

	notify_ops.clear();
	undo_ops.clear();
	return ok_status();
}

void Transaction::rollback() {
	for (auto it = undo_ops.rbegin(); it != undo_ops.rend(); ++it) {
		if (*it) {
			(*it)();
		}
	}
	undo_ops.clear();
	notify_ops.clear();
}

} // namespace ga
