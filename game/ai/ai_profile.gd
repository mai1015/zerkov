class_name ZAIProfile
extends Resource
## Provisional encounter tuning, not weapon/health authority or a general AI DSL.

@export_enum("scav", "mutant") var archetype: String = "scav"
@export var reaction_ticks: int = 18
@export var attack_request_interval_ticks: int = 12
@export var search_ticks: int = 180
@export var investigate_ticks: int = 120
@export var retreat_ticks: int = 120
@export var retry_ticks: int = 30
@export var path_timeout_ticks: int = 60
@export var action_timeout_ticks: int = 60
@export var retreat_health_milli: int = 200
@export var retreat_recover_health_milli: int = 400
@export var attack_range_raw: int = 12_000_000
@export var arrival_radius_raw: int = 350_000
@export var search_radius_raw: int = 2_000_000
## One perception record feeds native observers, memory filtering and debug FOV.
@export var sight_range_raw: int = 18_000_000
@export var cone_cos_million: int = 500_000
@export var memory_ticks: int = 180
@export var hearing_threshold_milli: int = 80
@export var max_projection_age_ticks: int = 2


func is_valid() -> bool:
	if archetype not in ["scav", "mutant"]:
		return false
	for duration: int in [reaction_ticks, attack_request_interval_ticks,
		search_ticks, investigate_ticks, retreat_ticks, retry_ticks, path_timeout_ticks, action_timeout_ticks]:
		if duration < 1 or duration > 36_000:
			return false
	return retreat_health_milli >= 0 and retreat_health_milli <= 1000 \
		and retreat_recover_health_milli >= 0 and retreat_recover_health_milli <= 1000 \
		and (retreat_health_milli == 0 or retreat_recover_health_milli > retreat_health_milli) \
		and sight_range_raw > 0 and sight_range_raw <= 18_000_000 \
		and cone_cos_million >= 0 and cone_cos_million <= 1_000_000 \
		and attack_range_raw > 0 and attack_range_raw <= 18_000_000 \
		and arrival_radius_raw > 0 and arrival_radius_raw <= ZAIValues.UNIT \
		and search_radius_raw >= 0 and search_radius_raw <= 8_000_000 \
		and memory_ticks >= 0 and memory_ticks <= 180 \
		and hearing_threshold_milli >= 1 and hearing_threshold_milli <= 1000 \
		and max_projection_age_ticks >= 0 and max_projection_age_ticks <= 2


func perception_record() -> Dictionary:
	return ZAIValues.frozen({"sight_range_raw": sight_range_raw,
		"cone_cos_million": cone_cos_million, "memory_ticks": memory_ticks})


static func valid_perception(value: Dictionary) -> bool:
	return ZAIValues.keys(value, ["sight_range_raw", "cone_cos_million", "memory_ticks"]) \
		and ZAIValues.integer(value.sight_range_raw, 1, 18_000_000) \
		and ZAIValues.integer(value.cone_cos_million, 0, 1_000_000) \
		and ZAIValues.integer(value.memory_ticks, 0, 180)


static func scav() -> ZAIProfile:
	return ZAIProfile.new()


static func mutant() -> ZAIProfile:
	var profile := ZAIProfile.new()
	profile.archetype = "mutant"
	profile.reaction_ticks = 12
	profile.attack_request_interval_ticks = 60
	profile.attack_range_raw = 1_250_000
	profile.retreat_health_milli = 0
	profile.sight_range_raw = 12_000_000
	profile.cone_cos_million = 173_648
	profile.memory_ticks = 120
	profile.search_ticks = 120
	return profile
