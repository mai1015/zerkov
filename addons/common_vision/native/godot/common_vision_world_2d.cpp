#include "godot/common_vision_world_2d.h"

#include "core/cv_limits.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <limits>

namespace godot {
namespace {

cv::Vec2 dictionary_point(const Dictionary &p_value) {
	return { static_cast<int64_t>(p_value.get("x", 0)),
		static_cast<int64_t>(p_value.get("y", 0)) };
}

Dictionary point_dictionary(cv::Vec2 p_value) {
	Dictionary result;
	result["x"] = p_value.x;
	result["y"] = p_value.y;
	return result;
}

bool fits_godot_int(std::uint64_t p_value) {
	return p_value <= static_cast<std::uint64_t>(
			std::numeric_limits<int64_t>::max());
}

cv::Status validate_snapshot_sequence(
		const cv::protocol::Snapshot &p_snapshot) {
	if (p_snapshot.sequence != p_snapshot.projection.result_revision) {
		return cv::make_status(cv::StatusCode::REVISION_MISMATCH,
				cv::DiagnosticId::PROJECTION_STALE,
				p_snapshot.projection.result_revision);
	}
	return cv::ok_status();
}

cv::Status validate_delta_sequence(const cv::protocol::Delta &p_delta) {
	if (p_delta.successor != p_delta.projection.result_revision) {
		return cv::make_status(cv::StatusCode::REVISION_MISMATCH,
				cv::DiagnosticId::PROJECTION_STALE,
				p_delta.projection.result_revision);
	}
	return cv::ok_status();
}

} // namespace

CommonVisionWorld2D::CommonVisionWorld2D() {
	world = std::make_unique<cv::VisionWorld2D>(
			cv::WorldId{ 1 }, cv::WorldRole::SERVER_AUTHORITY);
}

Dictionary CommonVisionWorld2D::status_dictionary(
		const cv::Status &p_status) {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["code"] = static_cast<int>(p_status.code);
	result["diagnostic"] = static_cast<int>(p_status.diagnostic);
	result["detail"] = static_cast<int64_t>(p_status.detail);
	return result;
}

Dictionary CommonVisionWorld2D::projection_dictionary(
		const cv::ObserverProjection &p_projection) {
	Dictionary result;
	result["ok"] = true;
	result["observer_id"] = static_cast<int64_t>(p_projection.observer.value);
	result["world_revision"] =
			static_cast<int64_t>(p_projection.world_revision);
	result["geometry_revision"] =
			static_cast<int64_t>(p_projection.geometry_revision);
	result["observer_revision"] =
			static_cast<int64_t>(p_projection.observer_revision);
	result["result_revision"] =
			static_cast<int64_t>(p_projection.result_revision);
	result["completed_tick"] =
			static_cast<int64_t>(p_projection.completed_tick);
	result["work_units"] = static_cast<int64_t>(p_projection.work_units);
	Array records;
	for (const cv::VisibilityRecord &record : p_projection.records) {
		Dictionary value;
		value["target_id"] = static_cast<int64_t>(record.target.value);
		value["state"] = static_cast<int>(record.state);
		value["transition"] = static_cast<int>(record.transition);
		value["first_seen_tick"] =
				static_cast<int64_t>(record.first_seen_tick);
		value["last_seen_tick"] =
				static_cast<int64_t>(record.last_seen_tick);
		value["has_last_known_position"] =
				record.has_last_known_position;
		value["last_known_position"] =
				point_dictionary(record.last_known_position);
		value["geometry_revision"] =
				static_cast<int64_t>(record.geometry_revision);
		value["target_revision"] =
				static_cast<int64_t>(record.target_revision);
		records.push_back(value);
	}
	result["records"] = records;
	return result;
}

Dictionary CommonVisionWorld2D::snapshot_dictionary(
		const cv::protocol::Snapshot &p_snapshot) {
	Dictionary result = status_dictionary(cv::ok_status());
	result["world_id"] = static_cast<int64_t>(p_snapshot.world.value);
	result["sequence"] = static_cast<int64_t>(p_snapshot.sequence);
	result["projection"] = projection_dictionary(p_snapshot.projection);
	return result;
}

Dictionary CommonVisionWorld2D::delta_dictionary(
		const cv::protocol::Delta &p_delta) {
	Dictionary result = status_dictionary(cv::ok_status());
	result["world_id"] = static_cast<int64_t>(p_delta.world.value);
	result["predecessor_sequence"] =
			static_cast<int64_t>(p_delta.predecessor);
	result["successor_sequence"] =
			static_cast<int64_t>(p_delta.successor);
	result["projection"] = projection_dictionary(p_delta.projection);
	return result;
}

PackedByteArray CommonVisionWorld2D::packed_bytes(
		const std::vector<std::uint8_t> &p_bytes) {
	PackedByteArray result;
	result.resize(static_cast<int64_t>(p_bytes.size()));
	if (!p_bytes.empty()) {
		std::copy(p_bytes.begin(), p_bytes.end(), result.ptrw());
	}
	return result;
}

cv::Status CommonVisionWorld2D::validate_godot_projection(
		const cv::ObserverProjection &p_projection) {
	if (!fits_godot_int(p_projection.observer.value) ||
			!fits_godot_int(p_projection.world_revision) ||
			!fits_godot_int(p_projection.geometry_revision) ||
			!fits_godot_int(p_projection.observer_revision) ||
			!fits_godot_int(p_projection.result_revision) ||
			!fits_godot_int(p_projection.completed_tick) ||
			!fits_godot_int(p_projection.work_units)) {
		return cv::make_status(cv::StatusCode::ARITHMETIC_ERROR,
				cv::DiagnosticId::COORDINATE_OVERFLOW);
	}
	for (const cv::VisibilityRecord &record : p_projection.records) {
		if (!fits_godot_int(record.target.value) ||
				!fits_godot_int(record.first_seen_tick) ||
				!fits_godot_int(record.last_seen_tick) ||
				!fits_godot_int(record.geometry_revision) ||
				!fits_godot_int(record.target_revision)) {
			return cv::make_status(cv::StatusCode::ARITHMETIC_ERROR,
					cv::DiagnosticId::COORDINATE_OVERFLOW);
		}
	}
	return cv::ok_status();
}

Dictionary CommonVisionWorld2D::replica_status_dictionary(
		const cv::Status &p_status, bool p_applied) const {
	Dictionary result = status_dictionary(p_status);
	result["applied"] = p_applied;
	result["resync_required"] = replica_needs_resync;
	result["last_sequence"] = replica_snapshot.has_value()
			? static_cast<int64_t>(replica_snapshot->sequence)
			: INT64_C(0);
	return result;
}

cv::Status CommonVisionWorld2D::require_authority_api() const {
	if (world->role() == cv::WorldRole::REPLICA) {
		return cv::make_status(cv::StatusCode::ROLE_VIOLATION,
				cv::DiagnosticId::ROLE_IS_REPLICA);
	}
	return cv::ok_status();
}

cv::Status CommonVisionWorld2D::require_replica_api() const {
	if (world->role() != cv::WorldRole::REPLICA) {
		return cv::make_status(cv::StatusCode::ROLE_VIOLATION);
	}
	return cv::ok_status();
}

void CommonVisionWorld2D::latch_resync() {
	replica_needs_resync = true;
}

Dictionary CommonVisionWorld2D::configure(int64_t p_world_id,
		AuthorityRole p_role, int64_t p_spatial_cell_size,
		int64_t p_max_visited_cells) {
	if (p_world_id <= 0 || p_role < OFFLINE_AUTHORITY || p_role > REPLICA) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	if (p_spatial_cell_size <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::COORDINATE_OUT_OF_RANGE));
	}
	if (p_max_visited_cells <= 0 ||
			static_cast<uint64_t>(p_max_visited_cells) >
					cv::MAX_VISITED_CELLS_PER_QUERY) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::LIMIT_EXCEEDED,
				cv::DiagnosticId::COUNT_LIMIT_EXCEEDED,
				p_max_visited_cells > 0
						? static_cast<uint64_t>(p_max_visited_cells)
						: 0));
	}
	world = std::make_unique<cv::VisionWorld2D>(
			cv::WorldId{ static_cast<uint64_t>(p_world_id) },
			static_cast<cv::WorldRole>(p_role), p_spatial_cell_size,
			static_cast<uint64_t>(p_max_visited_cells));
	replica_snapshot.reset();
	replica_needs_resync = false;
	return status_dictionary(cv::ok_status());
}

Dictionary CommonVisionWorld2D::set_occluder_segments(
		const Array &p_segments, int64_t p_geometry_revision) {
	if (p_geometry_revision <= 0 ||
			p_segments.size() > static_cast<int64_t>(
					cv::MAX_OCCLUDER_SEGMENTS)) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::COUNT_LIMIT_EXCEEDED));
	}
	std::vector<cv::Segment> segments;
	segments.reserve(p_segments.size());
	for (int64_t index = 0; index < p_segments.size(); ++index) {
		Dictionary input = p_segments[index];
		Dictionary a = input.get("a", Dictionary());
		Dictionary b = input.get("b", Dictionary());
		const int64_t id = input.get("id", 0);
		const int64_t mask = input.get("mask", 1);
		if (id <= 0 || mask < 0 ||
				mask > static_cast<int64_t>(UINT32_MAX)) {
			return status_dictionary(cv::make_status(
					cv::StatusCode::INVALID_ARGUMENT,
					id <= 0 ? cv::DiagnosticId::INVALID_IDENTITY :
							  cv::DiagnosticId::INVALID_MASK));
		}
		cv::Segment segment;
		segment.id = cv::SegmentId{ static_cast<uint64_t>(id) };
		segment.a = dictionary_point(a);
		segment.b = dictionary_point(b);
		segment.mask = static_cast<uint32_t>(mask);
		segment.two_sided = input.get("two_sided", true);
		segments.push_back(segment);
	}
	return status_dictionary(world->replace_geometry(std::move(segments),
			static_cast<cv::Revision>(p_geometry_revision)));
}

bool CommonVisionWorld2D::dictionary_to_observer(
		const Dictionary &p_input, cv::Observer &r_observer) {
	const int64_t id = p_input.get("id", 0);
	const int64_t cone_cos_million =
			p_input.get("cone_cos_million", 0);
	const int64_t target_mask = p_input.get(
			"target_mask", static_cast<int64_t>(UINT32_MAX));
	const int64_t occluder_mask = p_input.get(
			"occluder_mask", static_cast<int64_t>(UINT32_MAX));
	const int64_t memory_ticks = p_input.get("memory_ticks", 0);
	const int64_t priority = p_input.get("priority", 0);
	const int64_t revision = p_input.get("revision", 1);
	if (id <= 0 || memory_ticks < 0 || revision <= 0 ||
			target_mask < 0 ||
			target_mask > static_cast<int64_t>(UINT32_MAX) ||
			occluder_mask < 0 ||
			occluder_mask > static_cast<int64_t>(UINT32_MAX) ||
			cone_cos_million < std::numeric_limits<int32_t>::min() ||
			cone_cos_million > std::numeric_limits<int32_t>::max() ||
			priority < std::numeric_limits<int32_t>::min() ||
			priority > std::numeric_limits<int32_t>::max()) {
		return false;
	}
	r_observer.id = cv::ObserverId{ static_cast<uint64_t>(id) };
	r_observer.position = dictionary_point(
			p_input.get("position", Dictionary()));
	r_observer.facing = dictionary_point(
			p_input.get("facing", Dictionary()));
	if (r_observer.facing == cv::Vec2{}) {
		r_observer.facing = { cv::COORDINATE_SCALE, 0 };
	}
	r_observer.range = p_input.get("range", INT64_C(10000000));
	r_observer.cone_cos_million =
			static_cast<int32_t>(cone_cos_million);
	r_observer.full_circle = p_input.get("full_circle", false);
	r_observer.target_mask = static_cast<uint32_t>(target_mask);
	r_observer.occluder_mask = static_cast<uint32_t>(occluder_mask);
	r_observer.memory_ticks = static_cast<uint64_t>(memory_ticks);
	r_observer.priority = static_cast<int32_t>(priority);
	r_observer.urgent = p_input.get("urgent", false);
	r_observer.revision = static_cast<uint64_t>(revision);
	return true;
}

bool CommonVisionWorld2D::dictionary_to_target(
		const Dictionary &p_input, cv::Target &r_target) {
	const int64_t id = p_input.get("id", 0);
	const int64_t mask = p_input.get("mask", 1);
	const int64_t sample_policy = p_input.get("sample_policy", 0);
	const int64_t revision = p_input.get("revision", 1);
	if (id <= 0 || mask < 0 ||
			mask > static_cast<int64_t>(UINT32_MAX) ||
			sample_policy < static_cast<int64_t>(cv::SamplePolicy::ANY_SAMPLE) ||
			sample_policy > static_cast<int64_t>(cv::SamplePolicy::ALL_SAMPLES) ||
			revision <= 0) {
		return false;
	}
	r_target.id = cv::TargetId{ static_cast<uint64_t>(id) };
	r_target.position = dictionary_point(
			p_input.get("position", Dictionary()));
	r_target.mask = static_cast<uint32_t>(mask);
	r_target.sample_policy = static_cast<cv::SamplePolicy>(
			static_cast<int>(sample_policy));
	r_target.revision = static_cast<uint64_t>(revision);
	r_target.sample_offsets.clear();
	Array samples = p_input.get("sample_offsets", Array());
	if (samples.is_empty()) {
		r_target.sample_offsets.push_back({});
	} else {
		for (int64_t index = 0; index < samples.size(); ++index) {
			r_target.sample_offsets.push_back(
					dictionary_point(samples[index]));
		}
	}
	return true;
}

Dictionary CommonVisionWorld2D::register_observer(
		const Dictionary &p_definition) {
	cv::Observer observer;
	if (!dictionary_to_observer(p_definition, observer)) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	return status_dictionary(world->register_observer(observer));
}

Dictionary CommonVisionWorld2D::update_observer(
		const Dictionary &p_definition, int64_t p_expected_revision) {
	cv::Observer observer;
	if (!dictionary_to_observer(p_definition, observer) ||
			p_expected_revision <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT));
	}
	return status_dictionary(world->update_observer(observer,
			static_cast<cv::Revision>(p_expected_revision)));
}

Dictionary CommonVisionWorld2D::remove_observer(int64_t p_observer_id) {
	if (p_observer_id <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	return status_dictionary(world->remove_observer(cv::ObserverId{
			static_cast<uint64_t>(p_observer_id) }));
}

Dictionary CommonVisionWorld2D::register_target(
		const Dictionary &p_definition) {
	cv::Target target;
	if (!dictionary_to_target(p_definition, target)) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	return status_dictionary(world->register_target(target));
}

Dictionary CommonVisionWorld2D::update_target(
		const Dictionary &p_definition, int64_t p_expected_revision) {
	cv::Target target;
	if (!dictionary_to_target(p_definition, target) ||
			p_expected_revision <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT));
	}
	return status_dictionary(world->update_target(target,
			static_cast<cv::Revision>(p_expected_revision)));
}

Dictionary CommonVisionWorld2D::remove_target(int64_t p_target_id) {
	if (p_target_id <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	return status_dictionary(world->remove_target(
			cv::TargetId{ static_cast<uint64_t>(p_target_id) }));
}

Dictionary CommonVisionWorld2D::query_observer(
		int64_t p_observer_id, int64_t p_tick) {
	if (p_observer_id <= 0 || p_tick < 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				p_observer_id <= 0 ?
						cv::DiagnosticId::INVALID_IDENTITY :
						cv::DiagnosticId::WORLD_REVISION_STALE));
	}
	cv::ObserverProjection projection;
	cv::Status status = world->query_observer(
			cv::ObserverId{ static_cast<uint64_t>(p_observer_id) },
			static_cast<cv::Tick>(p_tick), projection);
	if (!status.ok()) return status_dictionary(status);
	return projection_dictionary(projection);
}

Dictionary CommonVisionWorld2D::advance(
		int64_t p_tick, int64_t p_work_budget) {
	cv::WorkMetrics metrics;
	if (p_tick < 0 || p_work_budget < 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::WORK_BUDGET_EXCEEDED));
	}
	cv::Status status = world->advance(static_cast<cv::Tick>(p_tick),
			static_cast<uint64_t>(p_work_budget), metrics);
	Dictionary result = status_dictionary(status);
	result["requested"] = static_cast<int64_t>(metrics.requested);
	result["consumed"] = static_cast<int64_t>(metrics.consumed);
	result["completed"] = static_cast<int64_t>(metrics.completed);
	result["invalidated"] = static_cast<int64_t>(metrics.invalidated);
	result["deferred"] = static_cast<int64_t>(metrics.deferred);
	return result;
}

Dictionary CommonVisionWorld2D::get_projection(
		int64_t p_observer_id) const {
	if (p_observer_id <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	const cv::ObserverProjection *result = world->projection(
			cv::ObserverId{ static_cast<uint64_t>(p_observer_id) });
	if (result == nullptr) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::NOT_FOUND));
	}
	return projection_dictionary(*result);
}

Dictionary CommonVisionWorld2D::encode_snapshot(int64_t p_observer_id) const {
	const cv::Status role_status = require_authority_api();
	if (!role_status.ok()) return status_dictionary(role_status);
	if (p_observer_id <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	const cv::ObserverProjection *projection = world->projection(
			cv::ObserverId{ static_cast<uint64_t>(p_observer_id) });
	if (projection == nullptr) {
		return status_dictionary(cv::make_status(cv::StatusCode::NOT_FOUND));
	}
	cv::protocol::Snapshot snapshot;
	snapshot.world = world->id();
	snapshot.sequence = projection->result_revision;
	snapshot.projection = *projection;
	std::vector<std::uint8_t> bytes;
	const cv::Status status = cv::protocol::encode_snapshot(snapshot, bytes);
	Dictionary result = status_dictionary(status);
	if (status.ok()) {
		result["bytes"] = packed_bytes(bytes);
		result["sequence"] = static_cast<int64_t>(snapshot.sequence);
	}
	return result;
}

Dictionary CommonVisionWorld2D::encode_delta(int64_t p_observer_id,
		int64_t p_predecessor_sequence) const {
	const cv::Status role_status = require_authority_api();
	if (!role_status.ok()) return status_dictionary(role_status);
	if (p_observer_id <= 0 || p_predecessor_sequence <= 0) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::INVALID_ARGUMENT,
				cv::DiagnosticId::INVALID_IDENTITY));
	}
	const cv::ObserverProjection *projection = world->projection(
			cv::ObserverId{ static_cast<uint64_t>(p_observer_id) });
	if (projection == nullptr) {
		return status_dictionary(cv::make_status(cv::StatusCode::NOT_FOUND));
	}
	if (p_predecessor_sequence == std::numeric_limits<int64_t>::max() ||
			projection->result_revision !=
					static_cast<cv::Revision>(p_predecessor_sequence) + 1) {
		return status_dictionary(cv::make_status(
				cv::StatusCode::SNAPSHOT_REQUIRED,
				cv::DiagnosticId::WORLD_REVISION_STALE,
				projection->result_revision));
	}
	cv::protocol::Delta delta;
	delta.world = world->id();
	delta.predecessor = static_cast<cv::Revision>(p_predecessor_sequence);
	delta.successor = projection->result_revision;
	delta.projection = *projection;
	std::vector<std::uint8_t> bytes;
	const cv::Status status = cv::protocol::encode_delta(delta, bytes);
	Dictionary result = status_dictionary(status);
	if (status.ok()) {
		result["bytes"] = packed_bytes(bytes);
		result["predecessor_sequence"] = p_predecessor_sequence;
		result["successor_sequence"] =
				static_cast<int64_t>(delta.successor);
	}
	return result;
}

Dictionary CommonVisionWorld2D::decode_snapshot(
		const PackedByteArray &p_bytes) const {
	cv::protocol::Snapshot snapshot;
	cv::Status status = cv::protocol::decode_snapshot(
			p_bytes.ptr(), static_cast<std::size_t>(p_bytes.size()), snapshot);
	if (status.ok() &&
			(!fits_godot_int(snapshot.world.value) ||
					!fits_godot_int(snapshot.sequence))) {
		status = cv::make_status(cv::StatusCode::ARITHMETIC_ERROR,
				cv::DiagnosticId::COORDINATE_OVERFLOW);
	}
	if (status.ok()) status = validate_godot_projection(snapshot.projection);
	if (status.ok()) status = validate_snapshot_sequence(snapshot);
	return status.ok() ? snapshot_dictionary(snapshot) : status_dictionary(status);
}

Dictionary CommonVisionWorld2D::decode_delta(
		const PackedByteArray &p_bytes) const {
	cv::protocol::Delta delta;
	cv::Status status = cv::protocol::decode_delta(
			p_bytes.ptr(), static_cast<std::size_t>(p_bytes.size()), delta);
	if (status.ok() &&
			(!fits_godot_int(delta.world.value) ||
					!fits_godot_int(delta.predecessor) ||
					!fits_godot_int(delta.successor))) {
		status = cv::make_status(cv::StatusCode::ARITHMETIC_ERROR,
				cv::DiagnosticId::COORDINATE_OVERFLOW);
	}
	if (status.ok()) status = validate_godot_projection(delta.projection);
	if (status.ok()) status = validate_delta_sequence(delta);
	return status.ok() ? delta_dictionary(delta) : status_dictionary(status);
}

Dictionary CommonVisionWorld2D::apply_snapshot(
		const PackedByteArray &p_bytes) {
	const cv::Status role_status = require_replica_api();
	if (!role_status.ok()) {
		return replica_status_dictionary(role_status, false);
	}
	cv::protocol::Snapshot snapshot;
	cv::Status status = cv::protocol::decode_snapshot(
			p_bytes.ptr(), static_cast<std::size_t>(p_bytes.size()), snapshot);
	if (status.ok() &&
			(!fits_godot_int(snapshot.world.value) ||
					!fits_godot_int(snapshot.sequence))) {
		status = cv::make_status(cv::StatusCode::ARITHMETIC_ERROR,
				cv::DiagnosticId::COORDINATE_OVERFLOW);
	}
	if (status.ok()) status = validate_godot_projection(snapshot.projection);
	if (status.ok()) status = validate_snapshot_sequence(snapshot);
	if (status.ok() && snapshot.world != world->id()) {
		status = cv::make_status(cv::StatusCode::INCOMPATIBLE,
				cv::DiagnosticId::INVALID_IDENTITY);
	}
	if (status.ok() && replica_snapshot.has_value() &&
			snapshot.projection.observer !=
					replica_snapshot->projection.observer) {
		status = cv::make_status(cv::StatusCode::INCOMPATIBLE,
				cv::DiagnosticId::INVALID_IDENTITY);
	}
	if (status.ok() && replica_snapshot.has_value() &&
			snapshot.sequence <= replica_snapshot->sequence) {
		status = cv::make_status(cv::StatusCode::REVISION_MISMATCH,
				cv::DiagnosticId::WORLD_REVISION_STALE,
				replica_snapshot->sequence);
	}
	if (!status.ok()) return replica_status_dictionary(status, false);
	replica_snapshot = std::move(snapshot);
	replica_needs_resync = false;
	return replica_status_dictionary(cv::ok_status(), true);
}

Dictionary CommonVisionWorld2D::apply_delta(
		const PackedByteArray &p_bytes) {
	const cv::Status role_status = require_replica_api();
	if (!role_status.ok()) {
		return replica_status_dictionary(role_status, false);
	}
	cv::protocol::Delta delta;
	cv::Status status = cv::protocol::decode_delta(
			p_bytes.ptr(), static_cast<std::size_t>(p_bytes.size()), delta);
	if (status.ok() &&
			(!fits_godot_int(delta.world.value) ||
					!fits_godot_int(delta.predecessor) ||
					!fits_godot_int(delta.successor))) {
		status = cv::make_status(cv::StatusCode::ARITHMETIC_ERROR,
				cv::DiagnosticId::COORDINATE_OVERFLOW);
	}
	if (status.ok()) status = validate_godot_projection(delta.projection);
	if (status.ok()) status = validate_delta_sequence(delta);
	if (!status.ok()) return replica_status_dictionary(status, false);
	if (delta.world != world->id()) {
		return replica_status_dictionary(cv::make_status(
				cv::StatusCode::INCOMPATIBLE,
				cv::DiagnosticId::INVALID_IDENTITY), false);
	}
	if (!replica_snapshot.has_value()) {
		latch_resync();
		return replica_status_dictionary(cv::make_status(
				cv::StatusCode::SNAPSHOT_REQUIRED,
				cv::DiagnosticId::WORLD_REVISION_STALE), false);
	}
	if (delta.projection.observer !=
					replica_snapshot->projection.observer) {
		return replica_status_dictionary(cv::make_status(
				cv::StatusCode::INCOMPATIBLE,
				cv::DiagnosticId::INVALID_IDENTITY), false);
	}
	if (replica_needs_resync) {
		return replica_status_dictionary(cv::make_status(
				cv::StatusCode::SNAPSHOT_REQUIRED,
				cv::DiagnosticId::WORLD_REVISION_STALE,
				replica_snapshot->sequence), false);
	}
	cv::protocol::Snapshot candidate = *replica_snapshot;
	status = cv::protocol::apply_delta(candidate, delta);
	if (status.code == cv::StatusCode::SNAPSHOT_REQUIRED) {
		latch_resync();
	}
	if (!status.ok()) return replica_status_dictionary(status, false);
	replica_snapshot = std::move(candidate);
	return replica_status_dictionary(cv::ok_status(), true);
}

Dictionary CommonVisionWorld2D::request_resync() {
	const cv::Status role_status = require_replica_api();
	if (!role_status.ok()) {
		Dictionary result = status_dictionary(role_status);
		result["requested"] = false;
		return result;
	}
	latch_resync();
	Dictionary result = status_dictionary(cv::ok_status());
	result["requested"] = true;
	result["world_id"] = static_cast<int64_t>(world->id().value);
	result["observer_id"] = replica_snapshot.has_value()
			? static_cast<int64_t>(replica_snapshot->projection.observer.value)
			: INT64_C(0);
	result["last_sequence"] = replica_snapshot.has_value()
			? static_cast<int64_t>(replica_snapshot->sequence)
			: INT64_C(0);
	return result;
}

Dictionary CommonVisionWorld2D::get_replica_projection() const {
	const cv::Status role_status = require_replica_api();
	if (!role_status.ok()) return status_dictionary(role_status);
	if (!replica_snapshot.has_value()) {
		Dictionary result = status_dictionary(
				cv::make_status(cv::StatusCode::NOT_FOUND));
		result["resync_required"] = replica_needs_resync;
		return result;
	}
	Dictionary result = projection_dictionary(replica_snapshot->projection);
	result["sequence"] = static_cast<int64_t>(replica_snapshot->sequence);
	result["resync_required"] = replica_needs_resync;
	return result;
}

void CommonVisionWorld2D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "world_id", "role",
			"spatial_cell_size", "max_visited_cells"),
			&CommonVisionWorld2D::configure, DEFVAL(INT64_C(8000000)),
			DEFVAL(static_cast<int64_t>(cv::MAX_VISITED_CELLS_PER_QUERY)));
	ClassDB::bind_method(D_METHOD("set_occluder_segments", "segments",
			"geometry_revision"),
			&CommonVisionWorld2D::set_occluder_segments);
	ClassDB::bind_method(D_METHOD("register_observer", "definition"),
			&CommonVisionWorld2D::register_observer);
	ClassDB::bind_method(D_METHOD("update_observer", "definition",
			"expected_revision"), &CommonVisionWorld2D::update_observer);
	ClassDB::bind_method(D_METHOD("remove_observer", "observer_id"),
			&CommonVisionWorld2D::remove_observer);
	ClassDB::bind_method(D_METHOD("register_target", "definition"),
			&CommonVisionWorld2D::register_target);
	ClassDB::bind_method(D_METHOD("update_target", "definition",
			"expected_revision"), &CommonVisionWorld2D::update_target);
	ClassDB::bind_method(D_METHOD("remove_target", "target_id"),
			&CommonVisionWorld2D::remove_target);
	ClassDB::bind_method(D_METHOD("query_observer", "observer_id", "tick"),
			&CommonVisionWorld2D::query_observer);
	ClassDB::bind_method(D_METHOD("advance", "tick", "work_budget"),
			&CommonVisionWorld2D::advance);
	ClassDB::bind_method(D_METHOD("get_projection", "observer_id"),
			&CommonVisionWorld2D::get_projection);
	ClassDB::bind_method(D_METHOD("encode_snapshot", "observer_id"),
			&CommonVisionWorld2D::encode_snapshot);
	ClassDB::bind_method(D_METHOD("decode_snapshot", "bytes"),
			&CommonVisionWorld2D::decode_snapshot);
	ClassDB::bind_method(D_METHOD("apply_snapshot", "bytes"),
			&CommonVisionWorld2D::apply_snapshot);
	ClassDB::bind_method(D_METHOD("encode_delta", "observer_id",
			"predecessor_sequence"), &CommonVisionWorld2D::encode_delta);
	ClassDB::bind_method(D_METHOD("decode_delta", "bytes"),
			&CommonVisionWorld2D::decode_delta);
	ClassDB::bind_method(D_METHOD("apply_delta", "bytes"),
			&CommonVisionWorld2D::apply_delta);
	ClassDB::bind_method(D_METHOD("request_resync"),
			&CommonVisionWorld2D::request_resync);
	ClassDB::bind_method(D_METHOD("get_replica_projection"),
			&CommonVisionWorld2D::get_replica_projection);

	BIND_ENUM_CONSTANT(OFFLINE_AUTHORITY);
	BIND_ENUM_CONSTANT(SERVER_AUTHORITY);
	BIND_ENUM_CONSTANT(REPLICA);
}

} // namespace godot
