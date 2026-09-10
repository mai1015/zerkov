#ifndef COMMON_VISION_GODOT_WORLD_2D_H
#define COMMON_VISION_GODOT_WORLD_2D_H

#include "core/cv_world.h"
#include "protocol/cv_protocol.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <memory>
#include <optional>

namespace godot {

// Thin, explicitly-owned facade over the deterministic native world. All
// mutable inputs are copied into core values; no Resource or ObjectID becomes
// canonical state.
class CommonVisionWorld2D : public Node {
	GDCLASS(CommonVisionWorld2D, Node)

public:
	enum AuthorityRole {
		OFFLINE_AUTHORITY = 0,
		SERVER_AUTHORITY = 1,
		REPLICA = 2,
	};

	CommonVisionWorld2D();

	Dictionary configure(int64_t p_world_id, AuthorityRole p_role,
			int64_t p_spatial_cell_size = 8000000,
			int64_t p_max_visited_cells =
					static_cast<int64_t>(cv::MAX_VISITED_CELLS_PER_QUERY));
	Dictionary set_occluder_segments(const Array &p_segments,
			int64_t p_geometry_revision);
	Dictionary register_observer(const Dictionary &p_definition);
	Dictionary update_observer(
			const Dictionary &p_definition, int64_t p_expected_revision);
	Dictionary remove_observer(int64_t p_observer_id);
	Dictionary register_target(const Dictionary &p_definition);
	Dictionary update_target(
			const Dictionary &p_definition, int64_t p_expected_revision);
	Dictionary remove_target(int64_t p_target_id);
	Dictionary query_observer(int64_t p_observer_id, int64_t p_tick);
	Dictionary advance(int64_t p_tick, int64_t p_work_budget);
	Dictionary get_projection(int64_t p_observer_id) const;

	// Authority-side, recipient-specific wire generation. The projection has
	// already been privacy-filtered by the native world; callers cannot submit
	// an arbitrary Dictionary as canonical packet state. The wire sequence is
	// the observer projection's result revision, so a skipped revision requires
	// a full snapshot instead of an ambiguous delta.
	Dictionary encode_snapshot(int64_t p_observer_id) const;
	Dictionary encode_delta(
			int64_t p_observer_id, int64_t p_predecessor_sequence) const;

	// Transport-independent bounded packet inspection. These methods do not
	// mutate authority or replica state.
	Dictionary decode_snapshot(const PackedByteArray &p_bytes) const;
	Dictionary decode_delta(const PackedByteArray &p_bytes) const;

	// Replica-only atomic application. A non-successor delta latches a resync
	// requirement and leaves the last successfully applied projection intact.
	Dictionary apply_snapshot(const PackedByteArray &p_bytes);
	Dictionary apply_delta(const PackedByteArray &p_bytes);
	Dictionary request_resync();
	Dictionary get_replica_projection() const;

protected:
	static void _bind_methods();

private:
	std::unique_ptr<cv::VisionWorld2D> world;
	std::optional<cv::protocol::Snapshot> replica_snapshot;
	bool replica_needs_resync = false;

	static Dictionary status_dictionary(const cv::Status &p_status);
	static Dictionary projection_dictionary(
			const cv::ObserverProjection &p_projection);
	static Dictionary snapshot_dictionary(
			const cv::protocol::Snapshot &p_snapshot);
	static Dictionary delta_dictionary(const cv::protocol::Delta &p_delta);
	static PackedByteArray packed_bytes(
			const std::vector<std::uint8_t> &p_bytes);
	static cv::Status validate_godot_projection(
			const cv::ObserverProjection &p_projection);
	Dictionary replica_status_dictionary(
			const cv::Status &p_status, bool p_applied) const;
	cv::Status require_authority_api() const;
	cv::Status require_replica_api() const;
	void latch_resync();
	static bool dictionary_to_observer(
			const Dictionary &p_input, cv::Observer &r_observer);
	static bool dictionary_to_target(
			const Dictionary &p_input, cv::Target &r_target);
};

} // namespace godot

VARIANT_ENUM_CAST(CommonVisionWorld2D::AuthorityRole);

#endif // COMMON_VISION_GODOT_WORLD_2D_H
