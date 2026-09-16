class_name HealthView
extends ZReadOnlyView
## Read-only body-part health, survival resource, injury and effect projection.

enum LifeState {
	ALIVE,
	INCAPACITATED,
	DEAD,
}

enum BodyPartState {
	HEALTHY,
	INJURED,
	DESTROYED,
}

enum Severity {
	INFO,
	MINOR,
	MAJOR,
	CRITICAL,
}

class BodyPart extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _part_id: StringName = &"":
		set(value):
			if not _sealed:
				_part_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _current_health: int = 0:
		set(value):
			if not _sealed:
				_current_health = value
	var _maximum_health: int = 0:
		set(value):
			if not _sealed:
				_maximum_health = value
	var _state: BodyPartState = BodyPartState.HEALTHY:
		set(value):
			if not _sealed:
				_state = value
	var _heavy_bleed: bool = false:
		set(value):
			if not _sealed:
				_heavy_bleed = value
	var _fractured: bool = false:
		set(value):
			if not _sealed:
				_fractured = value

	static func create(
		p_part_id: StringName,
		p_display_name: String,
		p_current_health: int,
		p_maximum_health: int,
		p_state: BodyPartState,
		p_heavy_bleed: bool = false,
		p_fractured: bool = false
	) -> BodyPart:
		if p_part_id.is_empty() or p_display_name.is_empty() or p_maximum_health <= 0 \
				or p_current_health < 0 or p_current_health > p_maximum_health:
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_state), BodyPartState.size()):
			return null
		if p_state == BodyPartState.DESTROYED and p_current_health != 0:
			return null
		if p_current_health == 0 and p_state != BodyPartState.DESTROYED:
			return null
		if p_state == BodyPartState.HEALTHY and (p_current_health != p_maximum_health \
				or p_heavy_bleed or p_fractured):
			return null
		if p_state == BodyPartState.INJURED and p_current_health == p_maximum_health \
				and not p_heavy_bleed and not p_fractured:
			return null
		var result := BodyPart.new()
		result._part_id = p_part_id
		result._display_name = p_display_name
		result._current_health = p_current_health
		result._maximum_health = p_maximum_health
		result._state = p_state
		result._heavy_bleed = p_heavy_bleed
		result._fractured = p_fractured
		result._seal_record()
		return result

	func part_id() -> StringName:
		return _part_id

	func display_name() -> String:
		return _display_name

	func current_health() -> int:
		return _current_health

	func maximum_health() -> int:
		return _maximum_health

	func state() -> BodyPartState:
		return _state

	func has_heavy_bleed() -> bool:
		return _heavy_bleed

	func is_fractured() -> bool:
		return _fractured

	func snapshot() -> BodyPart:
		return create(_part_id, _display_name, _current_health, _maximum_health,
			_state, _heavy_bleed, _fractured)

class StatusEffect extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _effect_id: StringName = &"":
		set(value):
			if not _sealed:
				_effect_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _severity: Severity = Severity.INFO:
		set(value):
			if not _sealed:
				_severity = value
	var _remaining_ticks: int = 0:
		set(value):
			if not _sealed:
				_remaining_ticks = value
	var _beneficial: bool = false:
		set(value):
			if not _sealed:
				_beneficial = value

	static func create(
		p_effect_id: StringName,
		p_display_name: String,
		p_severity: Severity,
		p_remaining_ticks: int,
		p_beneficial: bool = false
	) -> StatusEffect:
		if not ZReadOnlyView.content_id_is_valid(p_effect_id) \
				or p_display_name.is_empty() or p_remaining_ticks < 0:
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_severity), Severity.size()):
			return null
		var result := StatusEffect.new()
		result._effect_id = p_effect_id
		result._display_name = p_display_name
		result._severity = p_severity
		result._remaining_ticks = p_remaining_ticks
		result._beneficial = p_beneficial
		result._seal_record()
		return result

	func effect_id() -> StringName:
		return _effect_id

	func display_name() -> String:
		return _display_name

	func severity() -> Severity:
		return _severity

	func remaining_ticks() -> int:
		return _remaining_ticks

	func is_beneficial() -> bool:
		return _beneficial

	func snapshot() -> StatusEffect:
		return create(_effect_id, _display_name, _severity, _remaining_ticks, _beneficial)

var _actor_key: String = "":
	set(value):
		if not _sealed_view:
			_actor_key = value
var _life_state: LifeState = LifeState.ALIVE:
	set(value):
		if not _sealed_view:
			_life_state = value
var _current_health: int = 0:
	set(value):
		if not _sealed_view:
			_current_health = value
var _maximum_health: int = 0:
	set(value):
		if not _sealed_view:
			_maximum_health = value
var _stamina: int = 0:
	set(value):
		if not _sealed_view:
			_stamina = value
var _maximum_stamina: int = 0:
	set(value):
		if not _sealed_view:
			_maximum_stamina = value
var _hydration: int = 0:
	set(value):
		if not _sealed_view:
			_hydration = value
var _maximum_hydration: int = 0:
	set(value):
		if not _sealed_view:
			_maximum_hydration = value
var _energy: int = 0:
	set(value):
		if not _sealed_view:
			_energy = value
var _maximum_energy: int = 0:
	set(value):
		if not _sealed_view:
			_maximum_energy = value
var _energy_available: bool = true:
	set(value):
		if not _sealed_view:
			_energy_available = value
var _body_parts: Array[BodyPart] = []:
	set(value):
		if not _sealed_view:
			_body_parts = value
var _effects: Array[StatusEffect] = []:
	set(value):
		if not _sealed_view:
			_effects = value
var _content_digest: String = "":
	set(value):
		if not _sealed_view:
			_content_digest = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_actor_id: ZEntityId,
	p_life_state: LifeState,
	p_stamina: int,
	p_maximum_stamina: int,
	p_hydration: int,
	p_maximum_hydration: int,
	p_energy: int,
	p_maximum_energy: int,
	p_body_parts: Array[BodyPart],
	p_effects: Array[StatusEffect],
	p_energy_available: bool = true
) -> HealthView:
	if p_actor_id == null or not p_actor_id.is_initialized() or p_body_parts.is_empty():
		return null
	if not enum_value_is_valid(int(p_life_state), LifeState.size()):
		return null
	if not _resource_pair_is_valid(p_stamina, p_maximum_stamina) \
			or not _resource_pair_is_valid(p_hydration, p_maximum_hydration) \
			or not _resource_pair_is_valid(p_energy, p_maximum_energy):
		return null
	var staged_parts: Array[BodyPart] = []
	var seen_parts: Dictionary = {}
	var current_health := 0
	var maximum_health := 0
	for part in p_body_parts:
		if part == null or not part._sealed:
			return null
		var staged_part := part.snapshot()
		if staged_part == null or seen_parts.has(staged_part.part_id()):
			return null
		seen_parts[staged_part.part_id()] = true
		current_health += staged_part.current_health()
		maximum_health += staged_part.maximum_health()
		staged_parts.append(staged_part)
	var staged_effects: Array[StatusEffect] = []
	var seen_effects: Dictionary = {}
	for effect in p_effects:
		if effect == null or not effect._sealed:
			return null
		var staged_effect := effect.snapshot()
		if staged_effect == null or seen_effects.has(staged_effect.effect_id()):
			return null
		seen_effects[staged_effect.effect_id()] = true
		staged_effects.append(staged_effect)
	if not _life_state_is_valid(p_life_state, current_health):
		return null
	var result := HealthView.new()
	result._actor_key = p_actor_id.canonical_key()
	result._life_state = p_life_state
	result._current_health = current_health
	result._maximum_health = maximum_health
	result._stamina = p_stamina
	result._maximum_stamina = p_maximum_stamina
	result._hydration = p_hydration
	result._maximum_hydration = p_maximum_hydration
	result._energy_available = p_energy_available
	result._energy = p_energy
	result._maximum_energy = p_maximum_energy
	result._body_parts.assign(staged_parts)
	result._effects.assign(staged_effects)
	result._body_parts.make_read_only()
	result._effects.make_read_only()
	result._content_digest = result._build_content_digest(SyncState.READY, &"")
	if result._content_digest.is_empty():
		return null
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_actor_id: ZEntityId = null
) -> HealthView:
	if p_sync_state == SyncState.READY:
		return null
	if sync_state_requires_subject(p_sync_state) \
			and (p_actor_id == null or not p_actor_id.is_initialized()):
		return null
	var result := HealthView.new()
	result._actor_key = p_actor_id.canonical_key() if p_actor_id != null else ""
	result._content_digest = result._build_content_digest(
		p_sync_state, p_diagnostic)
	if result._content_digest.is_empty():
		return null
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


static func _resource_pair_is_valid(current: int, maximum: int) -> bool:
	return maximum > 0 and current >= 0 and current <= maximum


static func _life_state_is_valid(value: LifeState, aggregate_health: int) -> bool:
	# Aggregate health does not define lethal-zone policy. Task 5.6 owns the
	# configured lethal zones; an authoritative DEAD state may therefore retain
	# positive health elsewhere, while zero aggregate health cannot be non-dead.
	if value == LifeState.DEAD:
		return true
	return aggregate_health > 0


func actor_id() -> ZEntityId:
	return ZEntityId.parse(_actor_key) if not _actor_key.is_empty() else null


## Stable identity of the complete immutable ready payload. Version metadata is
## deliberately excluded so equal content at a newer authoritative version is
## still a new observation, while equal-version divergence is detectable.
func content_digest() -> String:
	return _content_digest


func _ready_payload_is_valid() -> bool:
	if actor_id() == null or _body_parts.is_empty() \
			or not enum_value_is_valid(int(_life_state), LifeState.size()) \
			or not _resource_pair_is_valid(_stamina, _maximum_stamina) \
			or not _resource_pair_is_valid(_hydration, _maximum_hydration) \
			or not _resource_pair_is_valid(_energy, _maximum_energy):
		return false
	var current := 0
	var maximum := 0
	var part_ids: Dictionary = {}
	for part in _body_parts:
		if part == null or not part._sealed or part.snapshot() == null \
				or part_ids.has(part.part_id()):
			return false
		part_ids[part.part_id()] = true
		current += part.current_health()
		maximum += part.maximum_health()
	if current != _current_health or maximum != _maximum_health \
			or not _life_state_is_valid(_life_state, current):
		return false
	var effect_ids: Dictionary = {}
	for effect in _effects:
		if effect == null or not effect._sealed or effect.snapshot() == null \
				or effect_ids.has(effect.effect_id()):
			return false
		effect_ids[effect.effect_id()] = true
	return true


func life_state() -> LifeState:
	return _life_state


func current_health() -> int:
	return _current_health


func maximum_health() -> int:
	return _maximum_health


func stamina() -> int:
	return _stamina


func maximum_stamina() -> int:
	return _maximum_stamina


func hydration() -> int:
	return _hydration


func maximum_hydration() -> int:
	return _maximum_hydration


func energy_available() -> bool:
	return _energy_available


func energy() -> int:
	return _energy


func maximum_energy() -> int:
	return _maximum_energy


func body_parts() -> Array[BodyPart]:
	var result: Array[BodyPart] = []
	for part in _body_parts:
		result.append(part.snapshot())
	result.make_read_only()
	return result


func effects() -> Array[StatusEffect]:
	var result: Array[StatusEffect] = []
	for effect in _effects:
		result.append(effect.snapshot())
	result.make_read_only()
	return result


func _build_content_digest(
	p_sync_state: SyncState,
	p_diagnostic: StringName
) -> String:
	var chunks := PackedStringArray([
		"actor=" + _digest_frame(_actor_key),
		"sync=" + str(int(p_sync_state)),
		"diagnostic=" + _digest_frame(String(p_diagnostic)),
		"life=" + str(int(_life_state)),
		"stamina=" + str(_stamina),
		"maximum_stamina=" + str(_maximum_stamina),
		"hydration=" + str(_hydration),
		"maximum_hydration=" + str(_maximum_hydration),
		"energy=" + str(_energy),
		"maximum_energy=" + str(_maximum_energy),
		"parts=" + str(_body_parts.size()),
	])
	if not _energy_available:
		chunks.append("energy_available=false")
	for part in _body_parts:
		chunks.append("part=" + _digest_frame(String(part.part_id()))
			+ _digest_frame(part.display_name())
			+ ":%d:%d:%d:%d:%d" % [
				part.current_health(), part.maximum_health(), int(part.state()),
				int(part.has_heavy_bleed()), int(part.is_fractured()),
			])
	chunks.append("effects=" + str(_effects.size()))
	for effect in _effects:
		chunks.append("effect=" + _digest_frame(String(effect.effect_id()))
			+ _digest_frame(effect.display_name())
			+ ":%d:%d:%d" % [
				int(effect.severity()), effect.remaining_ticks(),
				int(effect.is_beneficial()),
			])
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update("\n".join(chunks).to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _digest_frame(value: String) -> String:
	return "%d:%s" % [value.to_utf8_buffer().size(), value]
