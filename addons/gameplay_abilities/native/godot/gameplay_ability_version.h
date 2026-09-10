#ifndef GAMEPLAY_ABILITIES_GAMEPLAY_ABILITY_VERSION_H
#define GAMEPLAY_ABILITIES_GAMEPLAY_ABILITY_VERSION_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// The addon's version facade: what a client or server checks before it trusts
// the extension it just loaded. Every value is read straight from the
// engine-independent core (native/core/ga_version.h) so the number reported
// to GDScript can never drift from what the handshake and manifest tooling
// compute, satisfying "the addon reports its API, protocol, and
// content-manifest versions".
//
// Every method is static: the class exists so GDScript has a stable,
// discoverable place to call these from (GameplayAbilityVersion.get_api_version()),
// not because a version report carries instance state. It is still a
// RefCounted (rather than a bare utility namespace) so ClassDB can register
// and script code can reference it the same way as any other addon class.
class GameplayAbilityVersion : public RefCounted {
	GDCLASS(GameplayAbilityVersion, RefCounted)

public:
	// Mirrors ga::FeatureSet. Kept as a separate Godot-facing enum, rather than
	// exposing the core enum class directly, so no godot-cpp include ever
	// creeps into native/core.
	enum FeatureFlag {
		FEATURE_PREDICTION = 1 << 0,
		FEATURE_DEDICATED_SERVER = 1 << 1,
		FEATURE_SNAPSHOT_RESYNC = 1 << 2,
		FEATURE_PERIODIC_EFFECTS = 1 << 3,
		FEATURE_GAMEPLAY_EVENTS = 1 << 4,
		FEATURE_ABILITY_TASKS = 1 << 5,
		FEATURE_TYPED_TARGETING = 1 << 6,
		FEATURE_OBSERVER_TASK_STATE = 1 << 7,
		FEATURE_DELTA_REPLICATION = 1 << 8,
	};

	// "major.minor.patch", e.g. "0.2.0".
	static String get_api_version();
	static int get_api_version_major();
	static int get_api_version_minor();
	static int get_api_version_patch();

	// Wire protocol version exchanged during the handshake.
	static int get_protocol_version();

	// Identifier of the content-manifest fingerprint algorithm.
	static String get_manifest_algorithm();

	// Bitmask of FeatureFlag values this build implements.
	static int get_supported_features();
	static bool has_feature(int p_feature);

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayAbilityVersion::FeatureFlag);

#endif // GAMEPLAY_ABILITIES_GAMEPLAY_ABILITY_VERSION_H
